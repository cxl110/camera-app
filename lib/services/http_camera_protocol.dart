import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
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

  // ── Connection ──

  @override
  Future<ConnectionStatus> getConnectionStatus() async {
    try {
      // /info is unauthenticated — no token needed
      final response = await _client
          .get(Uri.parse('$baseUrl/info'))
          .timeout(_timeout);

      if (response.statusCode == 200) {
        final info = jsonDecode(response.body) as Map<String, dynamic>;
        final model = info['model'] as String? ?? '';
        final fw = info['fw'] as String? ?? '';
        final ssid = info['ssid'] as String? ?? 'ZIVIGo';

        // Only ZIVIGo devices are supported
        if (model == 'ZIVIGo') {
          AppLog.info('HttpCam', 'Connected to ZIVIGo fw=$fw ssid=$ssid');
          final status = ConnectionStatus(
            connected: true,
            ssid: ssid,
            signalStrength: 3,
            cameraBrand: model,
            cameraModel: fw,
          );
          _emitStatus(status);
          return status;
        }
      }
    } catch (e) {
      // Transient failure — don't emit a disconnect event.
      // The caller should treat this as "unknown", not "disconnected".
      AppLog.info('HttpCam', 'Connection check failed: $e');
    }

    return _lastStatus ?? const ConnectionStatus(connected: false);
  }

  void _emitStatus(ConnectionStatus status) {
    if (_lastStatus?.connected != status.connected) {
      _lastStatus = status;
      _connectionCtrl.add(status);

      // Start/stop security timers based on connection state
      if (status.connected) {
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

    // Sync RTC immediately on connection
    syncRtc();

    // Heartbeat every 30 seconds (honeypot — must carry token)
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _sendHeartbeat();
    });
    // Send first heartbeat immediately
    _sendHeartbeat();

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
  Future<void> _sendHeartbeat() async {
    final token = _computeToken();
    try {
      final request = http.Request('GET', Uri.parse('$baseUrl/heartbeat'));
      request.headers['User-Agent'] = 'ZIVIGo/1.0 ($token)';
      final response = await _client.send(request).timeout(const Duration(seconds: 3));
      // Drain the response body
      await response.stream.drain();
      AppLog.info('HttpCam', 'Heartbeat OK (token=$token, HTTP ${response.statusCode})');
    } catch (e) {
      AppLog.info('HttpCam', 'Heartbeat FAILED (token=$token): $e');
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
    final capResponse = await _client
        .post(Uri.parse('$baseUrl/capture'), headers: _authHeaders)
        .timeout(const Duration(seconds: 10));

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
      // /rtc is unauthenticated — no token needed
      await _client.post(
        Uri.parse('$baseUrl/rtc'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'timestamp': now}),
      ).timeout(const Duration(seconds: 3));
      AppLog.info('HttpCam', 'RTC synced: timestamp=$now');
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
      final response = await _client
          .get(uri, headers: _authHeaders)
          .timeout(_timeout);

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

      // Build CameraPhoto list — fetch thumbnails concurrently (max 8 at a time)
      final photos = <CameraPhoto>[];
      final semaphore = _Semaphore(8);

      await Future.wait(files.map((entry) async {
        await semaphore.acquire();
        try {
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
        } finally {
          semaphore.release();
        }
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
    try {
      AppLog.info('HttpCam', 'getThumbnail: $filename (token=${_computeToken()})');
      final response = await _client
          .get(Uri.parse('$baseUrl/thumb/$filename'), headers: _authHeaders)
          .timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        return response.bodyBytes;
      }
    } catch (e) {
      debugPrint('[HttpCamera] thumbnail error for $filename: $e');
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
    try {
      final token = _computeToken();
      AppLog.info('HttpCam', 'downloadPhoto (stream): $photoId (token=$token)');
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
    }
  }

  /// Download a photo and return its bytes directly (convenience wrapper).
  Future<Uint8List?> downloadPhotoBytes(String photoId) async {
    try {
      AppLog.info('HttpCam', 'downloadPhoto: $photoId (token=${_computeToken()})');
      final response = await _client
          .get(Uri.parse('$baseUrl/file/$photoId'), headers: _authHeaders)
          .timeout(const Duration(seconds: 60));

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
      final response = await _client
          .delete(Uri.parse('$baseUrl/file/$photoId'), headers: _authHeaders)
          .timeout(const Duration(seconds: 5));

      return response.statusCode == 200;
    } catch (e) {
      debugPrint('[HttpCamera] deletePhoto error: $e');
      return false;
    }
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
