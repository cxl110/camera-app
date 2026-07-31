import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'camera_protocol.dart';
import 'app_log.dart';

/// ZIVIGo HTTP protocol implementation.
///
/// Communicates with the ZIVIGo camera dev board over WiFi.
/// Provides live view (MJPEG stream), photo capture, file listing,
/// download, thumbnail, delete, and RTC time sync.
///
/// Security (v1.5): Token-based auth in User-Agent header + honeypot heartbeat.
/// Spec: C:\H3\APP\HTTPAPI\V821CAM-HTTP-API.md
class HttpCameraProtocol extends CameraProtocol {
  static const _defaultBaseUrl = 'http://192.168.5.1';
  static const _timeout = Duration(seconds: 10);

  // Token constants (from API spec v1.5)
  static const _tokenMul = 2654435761;
  static const _tokenAdd = 1737326273;
  static const _tokenMask = 0xFFFFFFFF;

  final String baseUrl;
  final http.Client _client;
  final StreamController<ConnectionStatus> _connectionCtrl =
      StreamController<ConnectionStatus>.broadcast();

  ConnectionStatus? _lastStatus;
  http.StreamedResponse? _liveViewResponse;
  bool _liveViewRunning = false;

  /// The active live-view stream controller (broadcast). Closed on stop.
  StreamController<Uint8List>? _liveViewController;

  // ── Security timers ──
  Timer? _heartbeatTimer;
  Timer? _rtcSyncTimer;
  bool _isConnected = false;

  // ── Disconnect detection ──
  /// Consecutive /info failures while we believed the camera was connected.
  /// A single transient failure is ignored; 2+ in a row → emit disconnect.
  int _connectionFailStreak = 0;

  // ── HTTP concurrency cap ──
  /// Global limit on simultaneous in-flight HTTP connections to the camera.
  /// The ZIVIGo dev board's HTTP server has a very low concurrency ceiling:
  /// under more than ~4 simultaneous connections it starts dropping/closing
  /// them ("Connection reset by peer", "Connection closed before full header
  /// was received"), which manifests as a cascade of thumbnail failures. So
  /// the cap is deliberately small (4) — every outbound request acquires a
  /// slot here and releases it when the response is consumed. The live-view
  /// MJPEG stream holds a slot for its whole lifetime, leaving 3 for short
  /// requests while the preview is running.
  static const _maxHttpConcurrency = 4;
  final _httpSlots = _Semaphore(_maxHttpConcurrency);

  HttpCameraProtocol({String? baseUrl, http.Client? client})
      : baseUrl = (baseUrl ?? _defaultBaseUrl).replaceAll(RegExp(r'/$'), ''),
        _client = client ?? http.Client();

  @override
  Stream<ConnectionStatus> get connectionStream => _connectionCtrl.stream;

  // ── Token ──

  /// Compute the 8-char hex token based on current local time.
  ///
  /// Algorithm: seed = floor(unixtime / 60), token = (seed * A + B) & 0xFFFFFFFF
  static String _computeToken() {
    final seed = DateTime.now().millisecondsSinceEpoch ~/ 60000;
    final token = (seed * _tokenMul + _tokenAdd) & _tokenMask;
    return token.toRadixString(16).padLeft(8, '0');
  }

  /// Build the User-Agent header value with embedded token.
  static String _userAgent() => 'ZIVIGo/1.0 (${_computeToken()})';

  /// HTTP headers for authenticated requests.
  Map<String, String> get _authHeaders => {'User-Agent': _userAgent()};

  /// Run a short HTTP request under the global concurrency cap. Acquires a
  /// slot, runs [fn] (which must consume/complete the request and return its
  /// result), and always releases the slot.
  Future<T> _withSlot<T>(Future<T> Function() fn) async {
    await _httpSlots.acquire();
    try {
      return await fn();
    } finally {
      _httpSlots.release();
    }
  }

  // ── Connection ──

  @override
  Future<ConnectionStatus> getConnectionStatus() async {
    try {
      // /info is unauthenticated — no token needed
      final response = await _withSlot(() => _client
          .get(Uri.parse('$baseUrl/info'), headers: {'User-Agent': _userAgent()})
          .timeout(_timeout));

      if (response.statusCode == 200) {
        final info = jsonDecode(response.body) as Map<String, dynamic>;
        final model = info['model'] as String? ?? '';
        final fw = info['fw'] as String? ?? '';
        final ssid = info['ssid'] as String? ?? 'ZIVIGo';
        final fwVersion = info['fw_version'] as String?;
        final otaSupported = info['ota'] as bool? ?? false;

        // Only ZIVIGo devices are supported
        if (model == 'ZIVIGo') {
          AppLog.info('HttpCam', 'Connected to ZIVIGo fw=$fw fw_version=$fwVersion ssid=$ssid ota=$otaSupported');
          // Camera answered — reset the failure streak.
          _connectionFailStreak = 0;
          final status = ConnectionStatus(
            connected: true,
            ssid: ssid,
            signalStrength: 3,
            cameraBrand: model,
            cameraModel: fw,
            fwVersion: fwVersion,
            otaSupported: otaSupported,
          );
          _emitStatus(status);
          return status;
        }
      }
    } catch (e) {
      // Transient failure — don't emit a disconnect on the first blip.
      // But if we previously believed we were connected and /info keeps
      // failing, the camera has genuinely gone away → emit disconnect so
      // the UI stops hammering a dead device and live view stops retrying.
      AppLog.info('HttpCam', 'Connection check failed: $e');
      _maybeEmitDisconnect();
    }

    return _lastStatus ?? const ConnectionStatus(connected: false);
  }

  /// Track consecutive /info failures and emit a disconnect once the camera
  /// is clearly gone (2 failures in a row). The first failure is tolerated to
  /// avoid flapping on a momentary network blip.
  void _maybeEmitDisconnect() {
    if (!_isConnected) return; // already disconnected — nothing to do
    _connectionFailStreak++;
    if (_connectionFailStreak >= 2) {
      AppLog.info('HttpCam', 'Camera unreachable after $_connectionFailStreak consecutive checks → disconnect');
      _emitStatus(const ConnectionStatus(connected: false));
    }
  }

  void _emitStatus(ConnectionStatus status) {
    if (_lastStatus?.connected != status.connected) {
      _lastStatus = status;
      _connectionCtrl.add(status);

      // Start/stop security timers based on connection state
      if (status.connected) {
        _connectionFailStreak = 0;
        _startSecurityTimers();
      } else {
        _stopSecurityTimers();
      }
    }
  }

  // ── Security: Heartbeat + RTC Sync ──

  /// Start heartbeat (every 30s) and periodic RTC sync (every 3 min).
  void _startSecurityTimers() {
    if (_isConnected) return; // already running
    _isConnected = true;

    // Sync RTC FIRST, then start heartbeat.
    // Token is time-based — if camera RTC is wrong (e.g. 1970),
    // heartbeat with our token will be rejected (403).
    syncRtc().then((_) {
      // Send first heartbeat after RTC sync completes
      _sendHeartbeat();
    });

    // Heartbeat every 30 seconds (honeypot — must carry token)
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _sendHeartbeat();
    });

    // RTC sync every 3 minutes (keeps token window valid)
    _rtcSyncTimer?.cancel();
    _rtcSyncTimer = Timer.periodic(const Duration(minutes: 3), (_) {
      syncRtc();
    });

    AppLog.info('HttpCam', 'Security timers started: heartbeat=30s, rtc=3min');
  }

  /// Stop all security timers.
  void _stopSecurityTimers() {
    _isConnected = false;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _rtcSyncTimer?.cancel();
    _rtcSyncTimer = null;
    AppLog.info('HttpCam', 'Security timers stopped');
  }

  /// Send honeypot heartbeat with token.
  ///
  /// The heartbeat is the ground-truth signal that the camera is alive: the
  /// token only validates on a running camera, so a refused/failed heartbeat
  /// means the device is gone. On failure while we think we're connected,
  /// emit a disconnect so the UI stops retrying against a dead camera.
  Future<void> _sendHeartbeat() async {
    final token = _computeToken();
    try {
      final request = http.Request('GET', Uri.parse('$baseUrl/heartbeat'));
      request.headers['User-Agent'] = 'ZIVIGo/1.0 ($token)';
      final response = await _withSlot(() =>
          _client.send(request).timeout(const Duration(seconds: 3)));
      // Drain the response body
      await response.stream.drain();
      if (response.statusCode == 200) {
        AppLog.info('HttpCam', 'Heartbeat OK (token=$token)');
        _connectionFailStreak = 0; // camera is alive — reset streak
      } else {
        AppLog.info('HttpCam', 'Heartbeat REJECTED (token=$token, HTTP ${response.statusCode})');
        // Rejected (likely 403) = camera is up but token wrong; not a disconnect.
      }
    } catch (e) {
      AppLog.info('HttpCam', 'Heartbeat FAILED (token=$token): $e');
      // Connection refused / no route → camera is unreachable. This is the
      // definitive "camera gone" signal that the silent /info failure path
      // might miss during the 30s heartbeat gap. Emit disconnect immediately.
      _emitStatus(const ConnectionStatus(connected: false));
      _stopSecurityTimers();
    }
  }

  // ── Live View (MJPEG stream) ──

  @override
  Stream<Uint8List> startLiveView() {
    if (_liveViewRunning) {
      throw StateError('Live view is already running');
    }

    // Broadcast: HomeScreen listens for errors/done, CameraPreview's
    // StreamBuilder listens for frames. A single-subscription stream would
    // let the first listener swallow every frame and leave the preview blank.
    final controller = StreamController<Uint8List>.broadcast();
    _liveViewController = controller;
    var frameCount = 0;

    _liveViewRunning = true;

    () async {
      // Hold a concurrency slot for the entire lifetime of the MJPEG stream
      // so the live view counts against the global HTTP cap.
      await _httpSlots.acquire();
      try {
        final request = http.Request('GET', Uri.parse('$baseUrl/stream'));
        // Stream is authenticated — token checked at connection start only
        final token = _computeToken();
        request.headers['User-Agent'] = 'ZIVIGo/1.0 ($token)';
        AppLog.info('HttpCam', 'Starting MJPEG live view stream (token=$token)...');
        _liveViewResponse = await _client.send(request).timeout(
          const Duration(seconds: 5),
          onTimeout: () => throw TimeoutException('Live view connection timeout'),
        );

        if (_liveViewResponse!.statusCode != 200) {
          throw Exception('Live view unavailable: HTTP ${_liveViewResponse!.statusCode}');
        }

        AppLog.info('HttpCam',
            'Live view connected: ${_liveViewResponse!.statusCode}, '
            'Content-Type=${_liveViewResponse!.headers['content-type']}');

        // Parse MJPEG multipart stream.
        //
        // Frame format (per HTTP API v1.5 §5):
        //   --mjpegstream\r\n
        //   Content-Type: image/jpeg\r\n
        //   Content-Length: <n>\r\n
        //   \r\n
        //   <n bytes of JPEG>\r\n
        //
        // We read by Content-Length rather than scanning for the next
        // boundary: more robust against boundary-like bytes inside JPEG
        // data and against boundaries split across chunks.
        const boundary = '--mjpegstream';
        final boundaryBytes = boundary.codeUnits;
        final headerEnd = '\r\n\r\n'.codeUnits;
        final crlf = '\r\n'.codeUnits;

        var buffer = <int>[];

        await for (final chunk in _liveViewResponse!.stream) {
          if (!_liveViewRunning) break;
          buffer.addAll(chunk);

          // Try to extract as many complete frames as the buffer holds.
          while (_liveViewRunning) {
            // 1. Locate the next boundary.
            final boundaryIndex = _indexOfBytes(buffer, boundaryBytes);
            if (boundaryIndex < 0) {
              // No boundary yet — keep only a tail to avoid unbounded growth,
              // but never trim past where a boundary could still appear.
              if (buffer.length > boundaryBytes.length) {
                buffer = buffer.sublist(buffer.length - boundaryBytes.length);
              }
              break;
            }

            // 2. Discard anything before the boundary.
            var pos = boundaryIndex + boundaryBytes.length;

            // 3. Find the end of this frame's headers (\r\n\r\n).
            final headerEndIndex = _indexOfBytes(buffer, headerEnd, start: pos);
            if (headerEndIndex < 0) {
              // Headers not fully received yet — wait for more data, but trim
              // the discarded prefix so the buffer doesn't grow forever.
              buffer = buffer.sublist(boundaryIndex);
              break;
            }

            // 4. Parse Content-Length from the headers (fallback if missing).
            final headerStr = String.fromCharCodes(
                buffer.sublist(pos, headerEndIndex));
            var contentLength = -1;
            for (final line in headerStr.split('\r\n')) {
              final lower = line.toLowerCase();
              if (lower.startsWith('content-length:')) {
                contentLength =
                    int.tryParse(line.substring(15).trim()) ?? -1;
                break;
              }
            }

            final jpegStart = headerEndIndex + headerEnd.length;

            if (contentLength > 0) {
              // 5a. Need contentLength bytes available after headers.
              if (jpegStart + contentLength > buffer.length) {
                // Not enough body yet — wait for more, trim prefix.
                buffer = buffer.sublist(boundaryIndex);
                break;
              }
              final jpegBytes =
                  buffer.sublist(jpegStart, jpegStart + contentLength);

              // Skip past JPEG + optional trailing CRLF.
              pos = jpegStart + contentLength;
              if (pos + 2 <= buffer.length &&
                  buffer[pos] == crlf[0] && buffer[pos + 1] == crlf[1]) {
                pos += 2;
              }
              buffer = buffer.sublist(pos);

              _emitFrame(controller, jpegBytes, frameCount);
              frameCount++;
            } else {
              // 5b. No Content-Length — fall back to scanning for the next
              // boundary and taking everything in between.
              final nextBoundary = _indexOfBytes(
                buffer,
                boundaryBytes,
                start: jpegStart,
              );
              if (nextBoundary < 0) {
                // Incomplete frame — wait for more, trim prefix.
                buffer = buffer.sublist(boundaryIndex);
                break;
              }
              final jpegBytes = buffer.sublist(jpegStart, nextBoundary);
              buffer = buffer.sublist(nextBoundary);

              _emitFrame(controller, jpegBytes, frameCount);
              frameCount++;
            }
          }
        }

        AppLog.info('HttpCam', 'Live view stream ended after $frameCount frames');
      } catch (e) {
        AppLog.error('HttpCam', 'Live view error after $frameCount frames', e);
        debugPrint('[HttpCamera] live view error: $e');
      } finally {
        _liveViewRunning = false;
        _liveViewResponse = null;
        if (!controller.isClosed) {
          controller.close();
        }
        _liveViewController = null;
        _httpSlots.release();
      }
    }();

    return controller.stream;
  }

  void _emitFrame(
      StreamController<Uint8List> controller, List<int> jpegBytes, int frameCount) {
    // JPEG data must start with the SOI marker (0xFF 0xD8).
    if (jpegBytes.length < 2 ||
        jpegBytes[0] != 0xFF || jpegBytes[1] != 0xD8) {
      return;
    }
    if (frameCount == 0) {
      AppLog.info('HttpCam', 'First MJPEG frame received (${jpegBytes.length} bytes)');
    }
    if (!controller.isClosed) {
      controller.add(Uint8List.fromList(jpegBytes));
    }
  }

  @override
  Future<void> stopLiveView() async {
    _liveViewRunning = false;
    // Close the stream controller if still open.
    _liveViewController?.close();
    _liveViewController = null;
    // Discard the HTTP response reference; the async loop will exit
    // on the next _liveViewRunning check.
    _liveViewResponse = null;
    AppLog.info('HttpCam', 'Live view stopped');
  }

  /// Find first occurrence of [needle] in [haystack], starting from [start].
  static int _indexOfBytes(List<int> haystack, List<int> needle, {int start = 0}) {
    outer:
    for (var i = start; i <= haystack.length - needle.length; i++) {
      for (var j = 0; j < needle.length; j++) {
        if (haystack[i + j] != needle[j]) continue outer;
      }
      return i;
    }
    return -1;
  }

  // ── Capture ──

  @override
  Future<CaptureResult> capturePhoto({bool flash = false}) async {
    // POST /capture — trigger photo capture, returns {status, filename}
    // API spec: capture is synchronous, up to ~2.5s blocking. Use 10s to be safe.
    AppLog.info('HttpCam', 'Sending capture request (token=${_computeToken()})...');
    final capResponse = await _withSlot(() => _client
        .post(Uri.parse('$baseUrl/capture'), headers: _authHeaders)
        .timeout(const Duration(seconds: 10)));

    AppLog.info('HttpCam',
        'Capture response: HTTP ${capResponse.statusCode}, body=${capResponse.body}');

    if (capResponse.statusCode != 200) {
      throw Exception('Capture failed: HTTP ${capResponse.statusCode}');
    }

    final capResult = jsonDecode(capResponse.body) as Map<String, dynamic>;
    final filename = capResult['filename'] as String?;
    if (filename == null || capResult['status'] != 'ok') {
      throw Exception('Capture failed: unexpected response');
    }

    // Download the captured photo directly
    AppLog.info('HttpCam', 'Downloading captured photo: $filename');
    final fullImage = await downloadPhotoBytes(filename);
    final thumbnail = await _getThumbnailBytes(filename);

    return CaptureResult(
      id: filename,
      name: filename,
      sizeBytes: fullImage?.length ?? 0,
      timestamp: DateTime.now(),
      thumbnail: thumbnail ?? fullImage,
      fullImage: fullImage ?? thumbnail,
    );
  }

  // ── Recording (unsupported) ──

  @override
  Future<void> startRecording() {
    throw UnsupportedError('ZIVIGo does not support recording');
  }

  @override
  Future<CaptureResult> stopRecording() {
    throw UnsupportedError('ZIVIGo does not support recording');
  }

  // ── RTC Time Sync ──

  /// Sync phone time to camera RTC.
  ///
  /// Called automatically on connection and every 3 minutes thereafter.
  /// Also callable manually. Fails silently — non-critical operation.
  Future<void> syncRtc() async {
    try {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final body = jsonEncode({'timestamp': now});
      AppLog.info('HttpCam', 'RTC sync: POST /rtc body=$body');
      // /rtc is unauthenticated per spec, but send User-Agent anyway —
      // some camera firmware versions may reject requests without ZIVIGo UA.
      final response = await _withSlot(() => _client.post(
        Uri.parse('$baseUrl/rtc'),
        headers: {'Content-Type': 'application/json', 'User-Agent': _userAgent()},
        body: body,
      ).timeout(const Duration(seconds: 3)));
      AppLog.info('HttpCam', 'RTC synced: timestamp=$now (HTTP ${response.statusCode}, body=${response.body})');
    } catch (e) {
      // Silently ignore — RTC sync is best-effort
      AppLog.info('HttpCam', 'RTC sync failed: $e');
    }
  }

  // ── Storage ──

  @override
  Future<PhotoListResult> listPhotos({
    int offset = 0,
    int limit = 50,
    String sort = 'date_desc',
  }) async {
    try {
      AppLog.info('HttpCam', 'listPhotos: offset=$offset, limit=$limit (token=${_computeToken()})');
      final uri = Uri.parse('$baseUrl/list').replace(
        queryParameters: {
          'offset': offset.toString(),
          'limit': limit.toString(),
        },
      );
      final response = await _withSlot(() => _client
          .get(uri, headers: _authHeaders)
          .timeout(_timeout));

      if (response.statusCode != 200) {
        return const PhotoListResult(total: 0, offset: 0, limit: 0, photos: []);
      }

      final Map<String, dynamic> body =
          jsonDecode(response.body) as Map<String, dynamic>;

      final total = (body['total'] as num?)?.toInt() ?? 0;
      final files = (body['files'] as List<dynamic>?)
              ?.map((e) => _FileEntry.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [];

      // Sort: newest first (filename contains YYYYMMDD_HHMMSS, lexicographic = chronological)
      files.sort((a, b) => b.name.compareTo(a.name));

      // Build CameraPhoto list — fetch thumbnails concurrently. Per-request
      // concurrency is bounded by the global HTTP slot cap (_maxHttpConcurrency)
      // via _getThumbnailBytes → _withSlot, so no separate semaphore is needed.
      final photos = <CameraPhoto>[];

      await Future.wait(files.map((entry) async {
        Uint8List? thumbnail;
        // v1.5: thumbnails supported for both photos and videos.
        // For videos the server extracts the first MJPEG frame.
        try {
          thumbnail = await _getThumbnailBytes(entry.name);
        } catch (_) {}

        photos.add(CameraPhoto(
          id: entry.name,
          name: entry.name,
          sizeBytes: entry.size,
          timestamp: entry.mtime,
          thumbnail: thumbnail,
          fullImage: null, // full image loaded on demand
        ));
      }));

      // Sort results by name descending (newest first)
      photos.sort((a, b) => b.name.compareTo(a.name));

      return PhotoListResult(
        total: total,
        offset: offset,
        limit: limit,
        photos: photos,
      );
    } catch (e) {
      AppLog.error('HttpCam', 'listPhotos error', e);
      debugPrint('[HttpCamera] listPhotos error: $e');
      return const PhotoListResult(total: 0, offset: 0, limit: 0, photos: []);
    }
  }

  /// Get thumbnail bytes for a photo filename.
  Future<Uint8List?> _getThumbnailBytes(String filename) async {
    // Retry transient connection failures (the dev board resets connections
    // under concurrency). Don't retry a definitive HTTP error like 500 (the
    // camera returned an answer — for .avi thumbnails it means the firmware
    // can't extract a frame; retrying won't help).
    const maxAttempts = 3;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        final token = _computeToken();
        AppLog.info('HttpCam',
            'getThumbnail: $filename (token=$token${attempt > 1 ? ", retry $attempt" : ""})');
        final response = await _withSlot(() => _client
            .get(Uri.parse('$baseUrl/thumb/$filename'), headers: {'User-Agent': 'ZIVIGo/1.0 ($token)'})
            .timeout(const Duration(seconds: 5)));

        if (response.statusCode == 200) {
          AppLog.info('HttpCam', 'getThumbnail OK: $filename (${response.bodyBytes.length} bytes)');
          return response.bodyBytes;
        }
        // Non-200 = server answered. For 500 (e.g. video thumbnails the firmware
        // can't render) there's nothing to retry — bail out.
        AppLog.info('HttpCam', 'getThumbnail FAILED: $filename (HTTP ${response.statusCode})');
        return null;
      } catch (e) {
        AppLog.info('HttpCam', 'getThumbnail ERROR: $filename: $e');
        // Transient (connection reset/closed/timeout) → retry after a short
        // backoff so the slot pool drains a bit before we try again.
        if (attempt < maxAttempts) {
          await Future.delayed(Duration(milliseconds: 200 * attempt));
          continue;
        }
      }
    }
    return null;
  }

  @override
  Future<Uint8List?> getThumbnail(String photoId) async {
    return _getThumbnailBytes(photoId);
  }

  @override
  Stream<DownloadProgress> downloadPhoto(String photoId,
      {PhotoQuality quality = PhotoQuality.original}) async* {
    final token = _computeToken();
    AppLog.info('HttpCam', 'downloadPhoto (stream): $photoId (token=$token)');
    // Hold a concurrency slot across the whole streamed download.
    await _httpSlots.acquire();
    try {
      final request = http.Request('GET', Uri.parse('$baseUrl/file/$photoId'));
      request.headers['User-Agent'] = 'ZIVIGo/1.0 ($token)';
      final response = await _client.send(request).timeout(const Duration(seconds: 60));

      if (response.statusCode != 200) {
        throw Exception('Download failed: HTTP ${response.statusCode}');
      }

      final total = response.contentLength ?? 0;
      var received = 0;
      final chunks = <List<int>>[];

      await for (final chunk in response.stream) {
        received += chunk.length;
        chunks.add(chunk);

        if (total > 0) {
          yield DownloadProgress(received: received, total: total);
        }
      }

      // Final progress
      yield DownloadProgress(received: received, total: max(received, total));

      // Note: fullImage is not stored here — callers should use the streamed bytes.
      // The CameraPhoto.fullImage field is set by the caller if needed.
    } catch (e) {
      AppLog.error('HttpCam', 'downloadPhoto error', e);
      debugPrint('[HttpCamera] downloadPhoto error: $e');
      rethrow;
    } finally {
      _httpSlots.release();
    }
  }

  /// Download a photo and return its bytes directly (convenience wrapper).
  Future<Uint8List?> downloadPhotoBytes(String photoId) async {
    try {
      AppLog.info('HttpCam', 'downloadPhoto: $photoId (token=${_computeToken()})');
      final response = await _withSlot(() => _client
          .get(Uri.parse('$baseUrl/file/$photoId'), headers: _authHeaders)
          .timeout(const Duration(seconds: 60)));

      if (response.statusCode == 200) {
        return response.bodyBytes;
      }
    } catch (e) {
      debugPrint('[HttpCamera] downloadPhotoBytes error: $e');
    }
    return null;
  }

  @override
  Future<bool> deletePhoto(String photoId) async {
    try {
      AppLog.info('HttpCam', 'deletePhoto: $photoId (token=${_computeToken()})');
      final response = await _withSlot(() => _client
          .delete(Uri.parse('$baseUrl/file/$photoId'), headers: _authHeaders)
          .timeout(const Duration(seconds: 5)));

      return response.statusCode == 200;
    } catch (e) {
      debugPrint('[HttpCamera] deletePhoto error: $e');
      return false;
    }
  }

  // ── OTA Firmware Update ──

  /// Query the current OTA update status from the device.
  ///
  /// Returns a map with `status` (idle/receiving_boot/boot_done/flashing)
  /// and `boot_received` (bool), or null on failure.
  Future<Map<String, dynamic>?> getUpdateStatus() async {
    try {
      final response = await _withSlot(() => _client
          .get(Uri.parse('$baseUrl/update_status'), headers: _authHeaders)
          .timeout(const Duration(seconds: 5)));
      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
      AppLog.info('HttpCam', 'getUpdateStatus: HTTP ${response.statusCode}');
    } catch (e) {
      AppLog.info('HttpCam', 'getUpdateStatus failed: $e');
    }
    return null;
  }

  /// Upload firmware images to the device for OTA update.
  ///
  /// Emits [OtaProgress] events with a single unified progress percentage
  /// (0.0 → 1.0) covering both boot.img and rootfs.img uploads.
  /// After upload completes, monitors the device for flashing → reboot.
  ///
  /// The caller should listen to the stream and update UI accordingly.
  /// The stream completes when the update is done or fails.
  Stream<OtaProgress> uploadFirmware({
    required Uint8List bootBytes,
    required Uint8List rootfsBytes,
  }) async* {
    final totalSize = bootBytes.length + rootfsBytes.length;
    AppLog.info('HttpCam', 'OTA: starting firmware upload '
        '(boot=${bootBytes.length}, rootfs=${rootfsBytes.length}, total=$totalSize)');

    // ── Step 1: Upload boot.img ──
    yield const OtaProgress(status: OtaStatus.uploading, percent: 0.0);

    try {
      final bootResult = await _uploadFirmwareImage(
        bytes: bootBytes,
        firmwareType: 'boot',
        onProgress: (_) {
          // Progress tracked via total bytes sent after each upload completes
        },
      );

      if (!bootResult) {
        AppLog.error('HttpCam', 'OTA: boot.img upload failed');
        yield const OtaProgress(status: OtaStatus.failed, percent: 0.0,
            error: '固件上传失败');
        return;
      }

      // boot uploaded: 50%
      yield OtaProgress(status: OtaStatus.uploading,
          percent: bootBytes.length / totalSize);
      AppLog.info('HttpCam', 'OTA: boot.img uploaded successfully');
    } catch (e) {
      AppLog.error('HttpCam', 'OTA: boot.img upload error', e);
      yield OtaProgress(status: OtaStatus.failed,
          percent: bootBytes.length / totalSize, error: '固件上传失败: $e');
      return;
    }

    // ── Step 2: Upload rootfs.img (triggers flashing) ──
    try {
      final rootfsResult = await _uploadFirmwareImage(
        bytes: rootfsBytes,
        firmwareType: 'rootfs',
        onProgress: (_) {},
      );

      if (!rootfsResult) {
        AppLog.error('HttpCam', 'OTA: rootfs.img upload failed');
        yield const OtaProgress(status: OtaStatus.failed, percent: 0.5,
            error: '固件上传失败');
        return;
      }

      // rootfs uploaded: 100%
      yield const OtaProgress(status: OtaStatus.uploading, percent: 1.0);
      AppLog.info('HttpCam', 'OTA: rootfs.img uploaded successfully');
    } catch (e) {
      AppLog.error('HttpCam', 'OTA: rootfs.img upload error', e);
      yield OtaProgress(status: OtaStatus.failed,
          percent: 0.5, error: '固件上传失败: $e');
      return;
    }

    // ── Step 3: Wait for flashing → reboot ──
    yield const OtaProgress(status: OtaStatus.flashing, percent: 1.0);
    AppLog.info('HttpCam', 'OTA: firmware flashing, waiting for reboot...');

    // Poll /update_status until connection drops (device reboots)
    for (var i = 0; i < 30; i++) {
      await Future.delayed(const Duration(seconds: 2));
      try {
        final status = await getUpdateStatus();
        if (status == null) {
          // Connection lost = device is rebooting
          break;
        }
        final s = status['status'] as String? ?? '';
        AppLog.info('HttpCam', 'OTA: update_status = $s');
        if (s == 'flashing') {
          yield const OtaProgress(status: OtaStatus.flashing, percent: 1.0);
          continue;
        }
        // Any other status after we've uploaded means something went wrong
        if (s == 'idle' || s == 'receiving_boot' || s == 'boot_done') {
          // Device didn't enter flashing — unexpected
          yield OtaProgress(status: OtaStatus.failed, percent: 1.0,
              error: '设备未进入刷写状态');
          return;
        }
      } catch (e) {
        // Connection lost = device is rebooting (expected)
        AppLog.info('HttpCam', 'OTA: connection lost (device rebooting)');
        break;
      }
    }

    // ── Step 4: Wait for device to come back online ──
    yield const OtaProgress(status: OtaStatus.rebooting, percent: 1.0);
    AppLog.info('HttpCam', 'OTA: waiting for device to reboot...');

    // Wait ~30s for reboot, then try to reconnect
    await Future.delayed(const Duration(seconds: 30));

    for (var attempt = 0; attempt < 10; attempt++) {
      await Future.delayed(const Duration(seconds: 3));
      try {
        final status = await getConnectionStatus();
        if (status.connected) {
          AppLog.info('HttpCam', 'OTA: device back online, fw_version=${status.fwVersion}');
          yield const OtaProgress(status: OtaStatus.done, percent: 1.0);
          return;
        }
      } catch (_) {}
    }

    // Device didn't come back — might still be rebooting or update failed
    AppLog.info('HttpCam', 'OTA: device did not come back online after reboot');
    yield const OtaProgress(status: OtaStatus.done, percent: 1.0);
  }

  /// Upload a single firmware image (boot or rootfs) to POST /update.
  ///
  /// Uses dart:io [HttpClient] for chunked upload with progress tracking.
  /// Returns true on success (HTTP 200), false on failure.
  Future<bool> _uploadFirmwareImage({
    required Uint8List bytes,
    required String firmwareType,
    required void Function(int sent) onProgress,
  }) async {
    // Use dart:io HttpClient for streaming upload with progress
    final httpClient = HttpClient();
    // Account for this upload against the global HTTP concurrency cap.
    await _httpSlots.acquire();
    try {
      final uri = Uri.parse('$baseUrl/update');
      final request = await httpClient.postUrl(uri);

      // Set headers
      request.headers.set('Content-Type', 'application/octet-stream');
      request.headers.set('Content-Length', bytes.length.toString());
      request.headers.set('X-Firmware-Type', firmwareType);
      request.headers.set('User-Agent', _userAgent());

      // Write body in chunks for progress tracking
      const chunkSize = 32768; // 32KB chunks
      var sent = 0;
      for (var offset = 0; offset < bytes.length; offset += chunkSize) {
        final end = (offset + chunkSize).clamp(0, bytes.length);
        request.add(bytes.sublist(offset, end));
        sent = end;
        onProgress(sent);
      }

      await request.flush();
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();

      AppLog.info('HttpCam',
          'OTA: $firmwareType upload response: ${response.statusCode} body=$body');

      if (response.statusCode == 200) {
        return true;
      } else {
        AppLog.error('HttpCam',
            'OTA: $firmwareType upload failed: HTTP ${response.statusCode} $body');
        return false;
      }
    } catch (e) {
      AppLog.error('HttpCam', 'OTA: $firmwareType upload error', e);
      return false;
    } finally {
      httpClient.close();
      _httpSlots.release();
    }
  }

  /// Compare firmware version strings to determine if an update is needed.
  ///
  /// Version format: `V<major>.<minor>-<YYYYMMDD>` (e.g. "V0.5-20260729").
  /// Returns true if [cameraVersion] is older than [bundledVersion],
  /// or if [cameraVersion] is null (old firmware without version reporting).
  static bool needsFirmwareUpdate(String? cameraVersion, String bundledVersion) {
    if (cameraVersion == null || cameraVersion.isEmpty) return true;
    if (cameraVersion == bundledVersion) return false;

    // Parse version: "V0.5-20260729" → major=0, minor=5, date=20260729
    final cameraParts = _parseFwVersion(cameraVersion);
    final bundledParts = _parseFwVersion(bundledVersion);

    if (cameraParts == null || bundledParts == null) {
      // Can't parse — fall back to string comparison
      return cameraVersion.compareTo(bundledVersion) < 0;
    }

    // Compare major.minor first, then date
    final cameraMajor = cameraParts[0];
    final cameraMinor = cameraParts[1];
    final cameraDate = cameraParts[2];
    final bundledMajor = bundledParts[0];
    final bundledMinor = bundledParts[1];
    final bundledDate = bundledParts[2];

    if (cameraMajor != bundledMajor) return cameraMajor < bundledMajor;
    if (cameraMinor != bundledMinor) return cameraMinor < bundledMinor;
    return cameraDate < bundledDate;
  }

  /// Parse "V0.5-20260729" → [0, 5, 20260729], or null on failure.
  static List<int>? _parseFwVersion(String v) {
    final regex = RegExp(r'^V(\d+)\.(\d+)-(\d{8})$');
    final match = regex.firstMatch(v);
    if (match == null) return null;
    return [
      int.tryParse(match.group(1)!) ?? 0,
      int.tryParse(match.group(2)!) ?? 0,
      int.tryParse(match.group(3)!) ?? 0,
    ];
  }

  /// Release HTTP client resources and stop all timers.
  void dispose() {
    _stopSecurityTimers();
    _connectionCtrl.close();
    _liveViewRunning = false;
    _liveViewResponse = null;
    _liveViewController?.close();
    _liveViewController = null;
    _client.close();
  }
}

/// Parsed file entry from /list JSON.
class _FileEntry {
  final String name;
  final String type;
  final int size;
  final DateTime mtime;

  const _FileEntry({
    required this.name,
    required this.type,
    required this.size,
    required this.mtime,
  });

  factory _FileEntry.fromJson(Map<String, dynamic> json) {
    return _FileEntry(
      name: json['name'] as String? ?? '',
      type: json['type'] as String? ?? 'photo',
      size: (json['size'] as num?)?.toInt() ?? 0,
      mtime: DateTime.fromMillisecondsSinceEpoch(
        ((json['mtime'] as num?)?.toInt() ?? 0) * 1000,
      ),
    );
  }
}

/// Simple concurrency limiter for thumbnail fetching.
class _Semaphore {
  final int maxPermits;
  int _permits;

  _Semaphore(this.maxPermits) : _permits = maxPermits;

  Future<void> acquire() async {
    while (_permits <= 0) {
      await Future.delayed(const Duration(milliseconds: 50));
    }
    _permits--;
  }

  void release() {
    _permits++;
  }
}
