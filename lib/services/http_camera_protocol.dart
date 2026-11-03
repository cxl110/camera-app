import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'camera_protocol.dart';
import 'image_mirror.dart';
import 'app_log.dart';

/// ZIVIGo HTTP protocol implementation.
///
/// Communicates with the ZIVIGo camera dev board over WiFi.
/// Provides live view (MJPEG stream), photo capture, file listing,
/// download, thumbnail, delete, and RTC time sync.
///
/// Security (API v1.7): token-based auth in the User-Agent header.
/// `/heartbeat` is a plain heartbeat (no longer a honeypot) and there is **no
/// permanent lockout** 鈥?the worst case is a 60 s temporary lock that expires
/// on its own, and the device self-heals its clock from rejected tokens.
/// Spec: C:\H3\APP\HTTPAPI\V821CAM-HTTP-API.md
class HttpCameraProtocol extends CameraProtocol {
  static const _defaultBaseUrl = 'http://192.168.5.1';
  static const _timeout = Duration(seconds: 10);

  // Token algorithm constants (API v1.7 搂瀹夊叏閴存潈 鈥?unchanged since v1.5)
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

  // 鈹€鈹€ Security timers 鈹€鈹€
  Timer? _heartbeatTimer;
  Timer? _rtcSyncTimer;
  bool _isConnected = false;

  // 鈹€鈹€ Disconnect detection 鈹€鈹€
  /// Consecutive /info failures while we believed the camera was connected.
  /// A single transient failure is ignored; 2+ in a row 鈫?emit disconnect.
  int _connectionFailStreak = 0;

  // 鈹€鈹€ HTTP concurrency cap 鈹€鈹€
  /// Global limit on simultaneous in-flight HTTP connections to the camera.
  /// The ZIVIGo dev board's HTTP server has a very low concurrency ceiling:
  /// under more than ~4 simultaneous connections it starts dropping/closing
  /// them ("Connection reset by peer", "Connection closed before full header
  /// was received"), which manifests as a cascade of thumbnail failures. So
  /// the cap is deliberately small (4) 鈥?every outbound request acquires a
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

  // 鈹€鈹€ Token 鈹€鈹€

  /// Device-clock offset in seconds: `deviceTime - phoneTime`.
  ///
  /// The token must be computed from the CAMERA's clock, because that is what
  /// the firmware validates it against (API v1.7: 卤10 min window, 21 candidate
  /// minutes). The phone's clock is only used as a monotonic reference: after
  /// every `/rtc` we learn the device's time from the response and derive the
  /// token from `phoneNow + offset`, so a wrong/drifting phone clock can no
  /// longer poison every authenticated request (heartbeat / capture / sound /
  /// delete).
  ///
  /// v1.7 also self-heals the device clock from rejected tokens, but that only
  /// helps when we send phone-based tokens; tracking the device clock is the
  /// more robust choice and additionally keeps `/rtc` from overwriting a good
  /// device RTC with a bad phone date.
  int _deviceTimeOffsetSec = 0;
  bool _timeBaseSynced = false;

  // 鈹€鈹€ v1.8 device clock metadata (no RTC in hardware) 鈹€鈹€

  /// `boot_id` from the last `/info`, `/list` or `/rtc` response. A change means
  /// the camera rebooted: its clock restarted from the value saved at power-off
  /// (it may be arbitrarily behind) and this boot's photos have not been rebased
  /// yet, so the offset learned earlier no longer applies.
  String? _bootId;

  /// `clock_synced` from the last device response. `false` means the device clock
  /// is only a relative ordering reference 鈥?no token can validate until we
  /// `POST /rtc` (v1.8 搂鏃堕棿妯″瀷 point 5).
  bool? _clockSynced;

  /// `clock_source`: `rtc` | `flash` | `build` | `none`.
  String? _clockSource;

  /// Device `timestamp` (Unix seconds) from the last device response.
  int? _deviceTimestampSec;

  /// Last known device clock metadata, for diagnostics in the UI/log.
  String? get bootId => _bootId;
  bool? get clockSynced => _clockSynced;
  String? get clockSource => _clockSource;

  /// Read the v1.8 clock fields from any device response (`/info`, `/list`,
  /// `/rtc`) and report whether the device clock must be re-synced before we are
  /// allowed to send a token-authenticated request.
  ///
  /// Returns true when either:
  /// - `boot_id` changed (the camera rebooted), or
  /// - the device says `clock_synced == false`.
  bool _applyClockFields(Map<String, dynamic> json) {
    final boot = json['boot_id'] as String?;
    final synced = json['clock_synced'] as bool?;
    final source = json['clock_source'] as String?;
    final ts = (json['timestamp'] as num?)?.toInt();

    var needSync = false;

    if (boot != null) {
      if (_bootId != null && boot != _bootId) {
        AppLog.info('HttpCam',
            'Device rebooted (boot_id $_bootId -> $boot) 鈥?discarding clock offset and resyncing');
        _deviceTimeOffsetSec = 0;
        _timeBaseSynced = false;
        needSync = true;
      }
      _bootId = boot;
    }

    if (synced != null) {
      if (!synced && _clockSynced != false) {
        AppLog.info('HttpCam',
            'Device clock not synced (source=${source ?? "?"}) 鈥?/rtc required before any token call');
      }
      if (!synced) needSync = true;
      _clockSynced = synced;
    }

    if (source != null) _clockSource = source;
    if (ts != null) _deviceTimestampSec = ts;

    return needSync;
  }

  /// Compute the 8-char hex token from the device time base.
  ///
  /// Algorithm (API v1.6 搂瀹夊叏閴存潈): seed = floor(unixtime / 60),
  /// token = (seed * A + B) & 0xFFFFFFFF.
  String _computeToken() {
    final phoneSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final deviceSec = _timeBaseSynced ? phoneSec + _deviceTimeOffsetSec : phoneSec;
    final seed = deviceSec ~/ 60;
    final token = (seed * _tokenMul + _tokenAdd) & _tokenMask;
    return token.toRadixString(16).padLeft(8, '0');
  }

  /// Build the User-Agent header value with embedded token.
  String _userAgent() => 'ZIVIGo/1.0 (${_computeToken()})';

  /// Parse the device clock out of a `/rtc` response body.
  ///
  /// Response shape: `{"status":"ok","time":"2026-10-16 18:52:20"}` 鈥?the
  /// device reports its own local time, which is the same clock its token
  /// window is based on.
  DateTime? _parseDeviceTime(String body) {
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;
      final raw = json['time'] as String?;
      if (raw == null) return null;
      return DateTime.tryParse(raw.trim().replaceFirst(' ', 'T'));
    } catch (_) {
      return null;
    }
  }

  /// Learn the device clock from a `/rtc` response so tokens stop depending on
  /// the phone's absolute time.
  void _adoptDeviceTime(String body) {
    final deviceTime = _parseDeviceTime(body);
    if (deviceTime == null) return;

    final offset = deviceTime.millisecondsSinceEpoch ~/ 1000 -
        DateTime.now().millisecondsSinceEpoch ~/ 1000;
    _deviceTimeOffsetSec = offset;
    _timeBaseSynced = true;
    AppLog.info('HttpCam',
        'Time base synced to device clock (offset=${offset}s, token=${_computeToken()})');
  }

  /// A `/rtc` request is already in flight 鈥?don't stack them.
  bool _rtcInFlight = false;

  /// Throttle for re-syncing the time base after an auth rejection.
  DateTime _lastAuthResync = DateTime(2000);

  /// Broadcasts `true` when the camera rejects our token (HTTP 403).
  ///
  /// The UI uses this to explain why live view / the sound switch are dead
  /// instead of silently retrying. Note this is NOT a connection loss: `/info`
  /// and `/stream` still answer, only token-checked endpoints refuse.
  final StreamController<bool> _authFailureCtrl = StreamController<bool>.broadcast();

  /// Stream of token-rejection notifications (true = rejected, false = recovered).
  Stream<bool> get authFailureStream => _authFailureCtrl.stream;

  /// Device is inside its 60 s temporary lockout (`403 Locked`).
  ///
  /// API v1.7: 10 consecutive token failures lock every request for 60 s, then
  /// the device unlocks by itself (and any correct token unlocks immediately).
  /// There is NO permanent lockout in v1.7 鈥?hitting this is recoverable, the
  /// only sane response is to wait out the window instead of retrying.
  DateTime _tempLockUntil = DateTime(2000);

  /// True while the device is expected to answer `403 Locked`.
  bool get _isTempLocked => DateTime.now().isBefore(_tempLockUntil);

  /// v1.7: the body distinguishes `{"error":"Locked"}` (temp lock) from
  /// `{"error":"Forbidden"}` (token wrong). Both are HTTP 403.
  static bool _bodyIsTempLock(String body) =>
      body.toLowerCase().contains('locked');

  /// Called whenever an authenticated request comes back 403.
  ///
  /// Handles the two v1.7 flavours differently:
  /// - `403 Locked` 鈫?device is in the 60 s lockout; record the deadline and
  ///   back off. Retrying cannot help and only extends the pain.
  /// - `403 Forbidden` 鈫?our token was wrong. Re-read the device clock via
  ///   `/rtc` (unauthenticated, so it works even when locked) and let the
  ///   caller retry: v1.7 self-heals the device clock from two consecutive
  ///   rejected tokens, so a bounded retry is genuinely useful now.
  void _onAuthRejected(String where, {String body = ''}) {
    final locked = _bodyIsTempLock(body);
    AppLog.info('HttpCam',
        'Auth rejected (403${locked ? " Locked" : ""}) on $where 鈥?'
        'token=${_computeToken()}, offset=${_deviceTimeOffsetSec}s, '
        'synced=$_timeBaseSynced, body=$body');

    if (locked) {
      // 60 s from the first rejection is enough; re-arming on every rejected
      // request would push the deadline out forever while we keep polling.
      if (!_isTempLocked) {
        _tempLockUntil = DateTime.now().add(const Duration(seconds: 60));
        AppLog.info('HttpCam',
            'Device temp-lock detected 鈥?pausing token-checked calls for 60s');
      }
    } else {
      // Plain token mismatch: re-learn the device clock (also gives the device
      // its second self-heal sample). Throttled so a burst of 403s from
      // parallel requests doesn't turn into a burst of /rtc calls.
      final now = DateTime.now();
      if (now.difference(_lastAuthResync).inSeconds >= 10) {
        _lastAuthResync = now;
        syncRtc();
      }
    }

    if (!_authFailureCtrl.isClosed) _authFailureCtrl.add(true);
  }

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

  // 鈹€鈹€ Connection 鈹€鈹€

  @override
  Future<ConnectionStatus> getConnectionStatus() async {
    try {
      // /info is unauthenticated 鈥?no token needed
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
          // Camera answered 鈥?reset the failure streak.
          _connectionFailStreak = 0;

          // v1.8: the hardware has no RTC battery, so the device clock can be
          // arbitrarily behind after a power-off. /info tells us whether it has
          // been synced this boot and whether the device rebooted since we last
          // talked to it. If either is the case, POST /rtc BEFORE announcing
          // "connected": everything the UI then fires (sound state, heartbeat,
          // /list) carries a token, and an unsynced device rejects all of them.
          final needSync = _applyClockFields(info);
          if (needSync) {
            await syncRtc(attempts: 1);
          }

          final status = ConnectionStatus(
            connected: true,
            ssid: ssid,
            signalStrength: 3,
            cameraBrand: model,
            cameraModel: fw,
            fwVersion: fwVersion,
            otaSupported: otaSupported,
            clockSynced: _clockSynced,
            clockSource: _clockSource,
            bootId: _bootId,
            deviceTimestamp: _deviceTimestampSec,
          );
          _emitStatus(status);
          return status;
        }
      }
    } catch (e) {
      // Transient failure 鈥?don't emit a disconnect on the first blip.
      // But if we previously believed we were connected and /info keeps
      // failing, the camera has genuinely gone away 鈫?emit disconnect so
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
    if (!_isConnected) return; // already disconnected 鈥?nothing to do
    _connectionFailStreak++;
    if (_connectionFailStreak >= 2) {
      AppLog.info('HttpCam', 'Camera unreachable after $_connectionFailStreak consecutive checks 鈫?disconnect');
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

  // 鈹€鈹€ Security: Heartbeat + RTC Sync 鈹€鈹€

  /// Start heartbeat (every 30s) and periodic RTC sync (every 3 min).
  void _startSecurityTimers() {
    if (_isConnected) return; // already running
    _isConnected = true;

    // Sync RTC FIRST, then start heartbeat.
    // Token is time-based 鈥?if camera RTC is wrong (e.g. 1970),
    // heartbeat with our token will be rejected (403).
    syncRtc().then((_) {
      // Send first heartbeat after RTC sync completes
      _sendHeartbeat();
    });

    // Heartbeat every 30 seconds (honeypot 鈥?must carry token)
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

  /// Send the 30 s heartbeat with token.
  ///
  /// The heartbeat is the ground-truth signal that the camera is alive: the
  /// token only validates on a running camera, so a network-level failure means
  /// the device is gone 鈫?emit a disconnect so the UI stops retrying.
  ///
  /// API v1.7: `/heartbeat` is **no longer a honeypot** and there is **no
  /// permanent lockout**. A 403 here is an ordinary auth rejection (temp lock,
  /// auto-expiring after 60 s), so it must not be treated as fatal.
  Future<void> _sendHeartbeat() async {
    // Skip while the device is temp-locked: the request is guaranteed to fail
    // and would only re-arm the 60 s window.
    if (_isTempLocked) {
      AppLog.info('HttpCam', 'Heartbeat skipped (device temp-locked)');
      return;
    }
    final token = _computeToken();
    try {
      final request = http.Request('GET', Uri.parse('$baseUrl/heartbeat'));
      request.headers['User-Agent'] = 'ZIVIGo/1.0 ($token)';
      final response = await _withSlot(() =>
          _client.send(request).timeout(const Duration(seconds: 3)));
      final body = await response.stream.bytesToString();
      if (response.statusCode == 200) {
        AppLog.info('HttpCam', 'Heartbeat OK (token=$token)');
        _connectionFailStreak = 0; // camera is alive 鈥?reset streak
        if (!_authFailureCtrl.isClosed) _authFailureCtrl.add(false);
      } else if (response.statusCode == 403) {
        AppLog.info('HttpCam',
            'Heartbeat REJECTED (token=$token, HTTP 403, body=$body)');
        // Camera is up but refused the token: re-sync the device clock / back
        // off on temp lock. Both cases are recoverable in v1.7.
        _onAuthRejected('heartbeat', body: body);
      } else {
        AppLog.info(
            'HttpCam', 'Heartbeat rejected (token=$token, HTTP ${response.statusCode})');
        // Rejected = camera is up; not a disconnect.
      }
    } catch (e) {
      AppLog.info('HttpCam', 'Heartbeat FAILED (token=$token): $e');
      // Connection refused / no route 鈫?camera is unreachable. This is the
      // definitive "camera gone" signal that the silent /info failure path
      // might miss during the 30s heartbeat gap. Emit disconnect immediately.
      _emitStatus(const ConnectionStatus(connected: false));
      _stopSecurityTimers();
    }
  }

  // 鈹€鈹€ Live View (MJPEG stream) 鈹€鈹€

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
        // Stream is authenticated 鈥?token checked at connection start only
        final token = _computeToken();
        request.headers['User-Agent'] = 'ZIVIGo/1.0 ($token)';
        AppLog.info('HttpCam', 'Starting MJPEG live view stream (token=$token)...');
        _liveViewResponse = await _client.send(request).timeout(
          const Duration(seconds: 5),
          onTimeout: () => throw TimeoutException('Live view connection timeout'),
        );

        if (_liveViewResponse!.statusCode != 200) {
          final code = _liveViewResponse!.statusCode;
          if (code == 403) {
            // Read the body to tell "token wrong" from "device temp-locked".
            final body = await _liveViewResponse!.stream
                .bytesToString()
                .timeout(const Duration(seconds: 2),
                    onTimeout: () => '');
            _onAuthRejected('live view', body: body);
            final locked = _bodyIsTempLock(body);
            throw CameraAuthException(
              locked
                  ? 'Camera is temporarily locked (60s) after repeated token failures'
                  : 'Camera rejected the access token (HTTP 403)',
              locked: locked,
            );
          }
          throw Exception('Live view unavailable: HTTP $code');
        }

        AppLog.info('HttpCam',
            'Live view connected: ${_liveViewResponse!.statusCode}, '
            'Content-Type=${_liveViewResponse!.headers['content-type']}');

        // Parse MJPEG multipart stream.
        //
        // Frame format (per HTTP API v1.5 搂5):
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
              // No boundary yet 鈥?keep only a tail to avoid unbounded growth,
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
              // Headers not fully received yet 鈥?wait for more data, but trim
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
                // Not enough body yet 鈥?wait for more, trim prefix.
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
              // 5b. No Content-Length 鈥?fall back to scanning for the next
              // boundary and taking everything in between.
              final nextBoundary = _indexOfBytes(
                buffer,
                boundaryBytes,
                start: jpegStart,
              );
              if (nextBoundary < 0) {
                // Incomplete frame 鈥?wait for more, trim prefix.
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

  // 鈹€鈹€ Capture 鈹€鈹€

  @override
  Future<CaptureResult> capturePhoto({bool flash = false}) async {
    // POST /capture 鈥?trigger photo capture, returns {status, filename}
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

  // 鈹€鈹€ Recording (unsupported) 鈹€鈹€

  @override
  Future<void> startRecording() {
    throw UnsupportedError('ZIVIGo does not support recording');
  }

  @override
  Future<CaptureResult> stopRecording() {
    throw UnsupportedError('ZIVIGo does not support recording');
  }

  // 鈹€鈹€ RTC Time Sync 鈹€鈹€

  /// Sync phone time to camera RTC and 鈥?crucially 鈥?learn the camera's clock.
  ///
  /// Called automatically on connection and every 3 minutes thereafter, and
  /// retried with backoff on failure. `/rtc` is unauthenticated, so this is the
  /// only reliable way to bootstrap the token when the phone clock and the
  /// device clock disagree: the response carries the device's own time, which
  /// we adopt as the token time base (see [_deviceTimeOffsetSec]).
  Future<void> syncRtc({int attempts = 3}) async {
    if (_rtcInFlight) return;
    _rtcInFlight = true;
    try {
      for (var attempt = 1; attempt <= attempts; attempt++) {
        try {
          final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
          final body = jsonEncode({'timestamp': now});
          AppLog.info('HttpCam',
              'RTC sync: POST /rtc body=$body${attempt > 1 ? " (retry $attempt)" : ""}');
          // /rtc is unauthenticated per spec, but send User-Agent anyway 鈥?          // some camera firmware versions may reject requests without ZIVIGo UA.
          final response = await _withSlot(() => _client.post(
            Uri.parse('$baseUrl/rtc'),
            headers: {'Content-Type': 'application/json', 'User-Agent': _userAgent()},
            body: body,
          ).timeout(const Duration(seconds: 3)));

          AppLog.info('HttpCam',
              'RTC synced: timestamp=$now (HTTP ${response.statusCode}, body=${response.body})');
          if (response.statusCode == 200) {
            _adoptDeviceTime(response.body);
            // v1.8 response detail: prev_timestamp / delta / mtime_fixed /
            // boot_id / hwclock_ok. hwclock_ok=false is NORMAL (no RTC battery)
            // and must not be treated as a failure.
            try {
              final j = jsonDecode(response.body) as Map<String, dynamic>;
              _applyClockFields(j);
              // A successful /rtc makes the device clock trustworthy for this boot.
              _clockSynced = true;
              final delta = (j['delta'] as num?)?.toInt();
              final fixed = (j['mtime_fixed'] as num?)?.toInt();
              final hw = j['hwclock_ok'] as bool?;
              if (delta != null || fixed != null || hw != null) {
                AppLog.info('HttpCam',
                    'RTC detail: delta=${delta ?? "?"}s mtime_fixed=${fixed ?? "?"} '
                    'hwclock_ok=${hw ?? "?"} boot=${_bootId ?? "?"}');
              }
              if (fixed != null && fixed > 0) {
                // The device just rebased this boot's photo mtimes to real time,
                // so any list fetched before this point shows stale dates.
                AppLog.info('HttpCam',
                    'Device rebased $fixed photo mtime(s) 鈥?photo dates are now real capture times');
              }
            } catch (_) {}
          } else if (response.statusCode == 400) {
            // 400 BadTimestamp: the phone's time is outside the device's accepted
            // range (1000000000..2000000000). Retrying with the same clock cannot
            // help, so fail fast and let the caller surface it.
            AppLog.info('HttpCam',
                'RTC rejected (400 BadTimestamp) 鈥?phone clock out of range, not retrying');
          }
          return;
        } catch (e) {
          AppLog.info('HttpCam', 'RTC sync failed: $e');
          if (attempt < attempts) {
            // The first /rtc after a reconnect often loses the connection while
            // the device is still bringing its HTTP server up. Retry instead of
            // leaving the token time base wrong 鈥?a wrong base makes EVERY
            // authenticated request 403 and can trip the device's L1 lock.
            await Future.delayed(Duration(milliseconds: 600 * attempt));
          }
        }
      }
    } finally {
      _rtcInFlight = false;
    }
  }

  // 鈹€鈹€ Storage 鈹€鈹€

  @override
  Future<PhotoListResult> listPhotos({
    int offset = 0,
    int limit = 50,
    String sort = 'date_desc',
  }) async {
    try {
      // 鈹€鈹€ Paginate from the newest end, whatever order the device uses 鈹€鈹€
      // The device's /list is not guaranteed to return newest-first (the spec's
      // own example is ascending). Callers must never have to care: `offset` here
      // always means "skip N of the NEWEST photos", and we translate it into a
      // server offset. One cheap `limit: 2` probe per fresh open gives us `total`
      // and the direction — two files, because a single one cannot reveal it.
      if (offset == 0 || _listTotal == null) {
        final probe = await _fetchListJson(0, 2);
        if (probe != null) {
          _listTotal = (probe['total'] as num?)?.toInt() ?? 0;
          _listAscending = _looksAscending(probe['files']);
          AppLog.info('HttpCam',
              'listPhotos: total=$_listTotal ascending=$_listAscending (paging newest-first)');
        }
      }

      final total = _listTotal ?? 0;

      // Clamp the window to what is actually left, otherwise the final partial
      // page would overlap the previous one and duplicate photos.
      final remaining = total - offset;
      final pageLimit = remaining > 0 && remaining < limit ? remaining : limit;
      final serverOffset =
          _listAscending ? (total - offset - pageLimit).clamp(0, total) : offset;

      AppLog.info('HttpCam',
          'listPhotos: newestOffset=$offset limit=$pageLimit 鈫?serverOffset=$serverOffset (token=${_computeToken()})');
      final body = await _fetchListJson(serverOffset, pageLimit);
      if (body == null) {
        return PhotoListResult(total: total, offset: offset, limit: limit, photos: const []);
      }

      // v1.8: /list also carries boot_id + timestamp. If the device rebooted
      // between requests its clock restarted, so kick off a resync 鈥?the mtimes
      // in this very response are still consistently ordered, just shifted.
      if (_applyClockFields(body)) {
        AppLog.info('HttpCam', 'listPhotos: device clock needs resync 鈥?scheduling /rtc');
        syncRtc(attempts: 1);
      }

      final files = (body['files'] as List<dynamic>?)
              ?.map((e) => _FileEntry.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [];

      // Newest first. Sorted by the timestamp embedded in the filename, NOT by
      // mtime: v1.8 guarantees the filename order is always correct (the boot
      // clock never restarts earlier than the newest file), while mtime is
      // shifted around by /rtc and would reorder the grid mid-session.
      files.sort((a, b) => captureKeyOf(b.name).compareTo(captureKeyOf(a.name)));

      // Build CameraPhoto list 鈥?fetch thumbnails concurrently. Per-request
      // concurrency is bounded by the global HTTP slot cap (_maxHttpConcurrency)
      // via _getThumbnailBytes 鈫?_withSlot, so no separate semaphore is needed.
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

      // Newest first by filename timestamp 鈥?the only ordering key that stays
      // correct across clock jumps (see captureKeyOf).
      sortPhotosNewestFirst(photos);

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

  /// Total number of files, cached for newest-first pagination.
  int? _listTotal;

  /// Whether the device returns `/list` oldest-first. Our own spec example is
  /// ascending, so we must not assume.
  bool _listAscending = false;

  /// Raw `GET /list`. Returns the decoded body, or null on any failure.
  Future<Map<String, dynamic>?> _fetchListJson(int offset, int limit) async {
    try {
      final uri = Uri.parse('$baseUrl/list').replace(
        queryParameters: {'offset': offset.toString(), 'limit': limit.toString()},
      );
      final response =
          await _withSlot(() => _client.get(uri, headers: _authHeaders).timeout(_timeout));
      if (response.statusCode != 200) return null;
      return jsonDecode(response.body) as Map<String, dynamic>;
    } catch (e) {
      AppLog.info('HttpCam', 'GET /list?offset=$offset&limit=$limit failed: $e');
      return null;
    }
  }

  /// Decide the device's list direction from the raw `files` array.
  static bool _looksAscending(dynamic files) {
    if (files is! List || files.length < 2) return false;
    final first = (files.first as Map<String, dynamic>)['name'] as String? ?? '';
    final last = (files.last as Map<String, dynamic>)['name'] as String? ?? '';
    return captureKeyOf(first).compareTo(captureKeyOf(last)) < 0;
  }

  /// Get thumbnail bytes for a photo filename.
  Future<Uint8List?> _getThumbnailBytes(String filename) async {
    // Retry transient connection failures (the dev board resets connections
    // under concurrency). Don't retry a definitive HTTP error like 500 (the
    // camera returned an answer 鈥?for .avi thumbnails it means the firmware
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
          // Sensor output is horizontally mirrored and firmware can't fix it, so
          // flip once here — every consumer (grid, capture strip) then just works.
          return mirrorCameraImage(response.bodyBytes);
        }
        // Non-200 = server answered. For 500 (e.g. video thumbnails the firmware
        // can't render) there's nothing to retry 鈥?bail out.
        AppLog.info('HttpCam', 'getThumbnail FAILED: $filename (HTTP ${response.statusCode})');
        return null;
      } catch (e) {
        AppLog.info('HttpCam', 'getThumbnail ERROR: $filename: $e');
        // Transient (connection reset/closed/timeout) 鈫?retry after a short
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
    // NOTE: file downloads are NOT throttled by the global concurrency cap.
    // The cap exists to protect the camera from BURST traffic (20 thumbnails at
    // once). A file download is a single connection and runs at full WiFi speed;
    // putting it behind the 4-slot pool made large video downloads queue behind
    // thumbnails/live view and slowed them several-fold.
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

      // Note: fullImage is not stored here 鈥?callers should use the streamed bytes.
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
      // Unthrottled 鈥?file downloads run at full speed (see downloadPhoto above).
      final response = await _client
          .get(Uri.parse('$baseUrl/file/$photoId'), headers: _authHeaders)
          .timeout(const Duration(seconds: 60));

      if (response.statusCode == 200) {
        // Normalise the mirrored sensor image at ingest (see image_mirror.dart):
        // the editor, the export path and the share sheet all consume these bytes.
        //
        // A 12 MP photo takes a few hundred milliseconds to decode+flip+encode,
        // which would jank the UI on the main isolate, so anything larger than
        // [mirrorIsolateThreshold] is handed to a background isolate. Thumbnails
        // stay inline: they are small and there are dozens of them.
        final bytes = response.bodyBytes;
        return bytes.length > mirrorIsolateThreshold
            ? await compute(mirrorCameraImage, bytes)
            : mirrorCameraImage(bytes);
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

  // 鈹€鈹€ Sound Effect Switch (API v1.6 搂12) 鈹€鈹€

  /// GET /sound 鈥?query the photo / recording-start beep switch.
  ///
  /// Returns null when the camera can't be reached. Only a genuine 404/501
  /// means "firmware has no /sound endpoint" ([SoundSetting.unsupported]); a
  /// 403 is a TOKEN problem and is rethrown as [CameraAuthException] so the UI
  /// can say so instead of greying the switch out forever.
  @override
  Future<SoundSetting?> getSoundEnabled() async {
    try {
      final response = await _withSlot(() => _client
          .get(Uri.parse('$baseUrl/sound'), headers: _authHeaders)
          .timeout(const Duration(seconds: 5)));

      if (response.statusCode == 200) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        final enabled = _parseBool(body['enabled']) ?? true;
        AppLog.info('HttpCam', 'getSoundEnabled: enabled=$enabled');
        return SoundSetting(enabled: enabled);
      }

      AppLog.info('HttpCam', 'getSoundEnabled: HTTP ${response.statusCode}');
      if (response.statusCode == 403) {
        // Camera is up but the token was refused 鈥?NOT "unsupported firmware".
        _onAuthRejected('get /sound', body: response.body);
        final locked = _bodyIsTempLock(response.body);
        throw CameraAuthException(
          locked
              ? 'Camera is temporarily locked (60s)'
              : 'Camera rejected the access token (HTTP 403)',
          locked: locked,
        );
      }
      // 404/501 鈫?firmware predates the /sound API.
      return SoundSetting.unsupported;
    } on CameraAuthException {
      rethrow;
    } catch (e) {
      AppLog.info('HttpCam', 'getSoundEnabled failed: $e');
      return null;
    }
  }

  /// POST /sound 鈥?set the photo / recording-start beep switch.
  ///
  /// The device persists the value (`/mnt/UDISK/sound_enabled`); when it could
  /// not be written the response reports `persisted: false`, which is surfaced
  /// to the caller so it can warn the user.
  @override
  Future<SoundSetting> setSoundEnabled(bool enabled) async {
    AppLog.info('HttpCam', 'setSoundEnabled: $enabled (token=${_computeToken()})');
    final response = await _withSlot(() => _client
        .post(
          Uri.parse('$baseUrl/sound'),
          headers: {
            ..._authHeaders,
            'Content-Type': 'application/json',
          },
          body: jsonEncode({'enabled': enabled}),
        )
        .timeout(const Duration(seconds: 5)));

    if (response.statusCode != 200) {
      AppLog.info('HttpCam',
          'setSoundEnabled FAILED: HTTP ${response.statusCode} body=${response.body}');
      if (response.statusCode == 403) {
        _onAuthRejected('post /sound', body: response.body);
        final locked = _bodyIsTempLock(response.body);
        throw CameraAuthException(
          locked
              ? 'Camera is temporarily locked (60s) 鈥?try again shortly'
              : 'Camera rejected the access token (HTTP 403)',
          locked: locked,
        );
      }
      // 404 鈫?firmware older than v1.6 (no /sound endpoint); 403 鈫?token refused.
      if (response.statusCode == 404 || response.statusCode == 501) {
        throw const SoundControlException(
            'Camera firmware has no sound switch (/sound) 鈥?update firmware');
      }
      throw SoundControlException(
          'Camera rejected the sound setting (HTTP ${response.statusCode})');
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final applied = _parseBool(body['enabled']) ?? enabled;
    final persisted = body['persisted'] as bool? ?? true;
    AppLog.info('HttpCam', 'setSoundEnabled OK: enabled=$applied persisted=$persisted');
    return SoundSetting(enabled: applied, persisted: persisted);
  }

  /// Accept `true`/`false` and the weak-typed numeric `1`/`0` the firmware
  /// also sends for compatibility. Returns null when unrecognised.
  static bool? _parseBool(dynamic value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final v = value.trim().toLowerCase();
      if (v == 'true' || v == '1') return true;
      if (v == 'false' || v == '0') return false;
    }
    return null;
  }

  // 鈹€鈹€ OTA Firmware Update 鈹€鈹€

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
  /// (0.0 鈫?1.0) covering both boot.img and rootfs.img uploads.
  /// After upload completes, monitors the device for flashing 鈫?reboot.
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

    // 鈹€鈹€ Step 1: Upload boot.img 鈹€鈹€
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
            error: 'Firmware upload failed');
        return;
      }

      // boot uploaded: 50%
      yield OtaProgress(status: OtaStatus.uploading,
          percent: bootBytes.length / totalSize);
      AppLog.info('HttpCam', 'OTA: boot.img uploaded successfully');
    } catch (e) {
      AppLog.error('HttpCam', 'OTA: boot.img upload error', e);
      yield OtaProgress(status: OtaStatus.failed,
          percent: bootBytes.length / totalSize, error: 'Firmware upload failed: $e');
      return;
    }

    // 鈹€鈹€ Step 2: Upload rootfs.img (triggers flashing) 鈹€鈹€
    try {
      final rootfsResult = await _uploadFirmwareImage(
        bytes: rootfsBytes,
        firmwareType: 'rootfs',
        onProgress: (_) {},
      );

      if (!rootfsResult) {
        AppLog.error('HttpCam', 'OTA: rootfs.img upload failed');
        yield const OtaProgress(status: OtaStatus.failed, percent: 0.5,
            error: 'Firmware upload failed');
        return;
      }

      // rootfs uploaded: 100%
      yield const OtaProgress(status: OtaStatus.uploading, percent: 1.0);
      AppLog.info('HttpCam', 'OTA: rootfs.img uploaded successfully');
    } catch (e) {
      AppLog.error('HttpCam', 'OTA: rootfs.img upload error', e);
      yield OtaProgress(status: OtaStatus.failed,
          percent: 0.5, error: 'Firmware upload failed: $e');
      return;
    }

    // 鈹€鈹€ Step 3: Wait for flashing 鈫?device reboots (WiFi drops) 鈹€鈹€
    yield const OtaProgress(status: OtaStatus.flashing, percent: 1.0);
    AppLog.info('HttpCam', 'OTA: firmware flashing, waiting for reboot...');

    // Poll /update_status until the connection drops 鈥?that means the device
    // has finished flashing and is rebooting. We do NOT wait for the device to
    // come back online here: a reboot takes ~3 minutes, and blocking the UI on
    // that would freeze the update screen. Instead we hand control back to the
    // caller (which dismisses the dialog and asks the user to wait & reconnect).
    bool connectionDropped = false;
    for (var i = 0; i < 30; i++) {
      await Future.delayed(const Duration(seconds: 2));
      try {
        final status = await getUpdateStatus();
        if (status == null) {
          // Connection lost = device is rebooting
          connectionDropped = true;
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
          // Device didn't enter flashing 鈥?unexpected
          yield const OtaProgress(status: OtaStatus.failed, percent: 1.0,
              error: 'Device did not enter flashing state');
          return;
        }
      } catch (e) {
        // Connection lost = device is rebooting (expected)
        AppLog.info('HttpCam', 'OTA: connection lost (device rebooting)');
        connectionDropped = true;
        break;
      }
    }

    // Connection dropped (or polling window elapsed) 鈫?device is rebooting.
    // Signal rebooting and end the stream; the caller dismisses the dialog and
    // tells the user to wait for the camera to restart, then reconnect.
    AppLog.info('HttpCam', 'OTA: device rebooting 鈥?handing back to user');
    yield const OtaProgress(status: OtaStatus.rebooting, percent: 1.0);
    return;
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

    // Parse version: "V0.5-20260729" -> major=0, minor=5, date=20260729
    final cameraParts = _parseFwVersion(cameraVersion);
    final bundledParts = _parseFwVersion(bundledVersion);

    if (bundledParts == null) {
      // Nothing sensible to compare against — do not nag.
      return false;
    }
    if (cameraParts == null) {
      // The camera reports something that is not a version at all (e.g. "dev",
      // the default when the firmware was built without a version stamp). We
      // cannot prove it is current, so OFFER the update: silently deciding
      // "unknown means up to date" is how a field unit that is missing the fix
      // never gets flashed. Note the old fallback here compared the raw strings,
      // and "dev" sorts *after* "V0.5-…" (0x64 > 0x56), so it always looked
      // newer and the update prompt never appeared.
      return true;
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

  /// Parse "V0.5-20260729" -> [0, 5, 20260729], or null on failure.
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
    _authFailureCtrl.close();
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
