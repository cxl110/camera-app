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
/// Spec: C:\H3\APP\HTTPAPI\V821CAM-HTTP-API.md
class HttpCameraProtocol extends CameraProtocol {
  static const _defaultBaseUrl = 'http://192.168.5.1';
  static const _timeout = Duration(seconds: 10);

  final String baseUrl;
  final http.Client _client;
  final StreamController<ConnectionStatus> _connectionCtrl =
      StreamController<ConnectionStatus>.broadcast();

  ConnectionStatus? _lastStatus;
  http.StreamedResponse? _liveViewResponse;
  bool _liveViewRunning = false;

  HttpCameraProtocol({String? baseUrl, http.Client? client})
      : baseUrl = (baseUrl ?? _defaultBaseUrl).replaceAll(RegExp(r'/$'), ''),
        _client = client ?? http.Client();

  @override
  Stream<ConnectionStatus> get connectionStream => _connectionCtrl.stream;

  // ── Connection ──

  @override
  Future<ConnectionStatus> getConnectionStatus() async {
    try {
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
    } catch (_) {
      // Not connected
    }

    final status = const ConnectionStatus(connected: false);
    AppLog.debug('HttpCam', 'Connection check failed — not connected');
    _emitStatus(status);
    return status;
  }

  void _emitStatus(ConnectionStatus status) {
    if (_lastStatus?.connected != status.connected) {
      _lastStatus = status;
      _connectionCtrl.add(status);
    }
  }

  // ── Live View (MJPEG stream) ──

  @override
  Stream<Uint8List> startLiveView() {
    if (_liveViewRunning) {
      throw StateError('Live view is already running');
    }

    AppLog.info('HttpCam', 'Starting MJPEG live view stream...');
    final controller = StreamController<Uint8List>();
    var frameCount = 0;

    _liveViewRunning = true;

    () async {
      try {
        final request = http.Request('GET', Uri.parse('$baseUrl/stream'));
        _liveViewResponse = await _client.send(request).timeout(
          const Duration(seconds: 5),
          onTimeout: () => throw TimeoutException('Live view connection timeout'),
        );

        if (_liveViewResponse!.statusCode != 200) {
          throw Exception('Live view unavailable: HTTP ${_liveViewResponse!.statusCode}');
        }

        // Parse MJPEG multipart stream
        const boundary = '--mjpegstream';
        final boundaryBytes = boundary.codeUnits;
        final headerEnd = '\r\n\r\n'.codeUnits;

        var buffer = <int>[];

        await for (final chunk in _liveViewResponse!.stream) {
          if (!_liveViewRunning) break;

          buffer.addAll(chunk);

          // Search for complete frames
          while (_liveViewRunning && buffer.length > boundaryBytes.length) {
            // Find boundary start
            final boundaryIndex = _indexOfBytes(buffer, boundaryBytes);
            if (boundaryIndex < 0) break;

            // Find next boundary after this one
            final nextBoundary = _indexOfBytes(
              buffer,
              boundaryBytes,
              start: boundaryIndex + boundaryBytes.length,
            );

            if (nextBoundary < 0) break; // incomplete frame, wait for more data

            // Extract frame body between boundaries
            final frameSection = buffer.sublist(boundaryIndex, nextBoundary);

            // Find JPEG data (after \r\n\r\n headers)
            final headerEndIndex = _indexOfBytes(frameSection, headerEnd);
            if (headerEndIndex > 0) {
              final jpegStart = headerEndIndex + headerEnd.length;
              final jpegBytes = frameSection.sublist(jpegStart);
              if (jpegBytes.length > 100) {
                frameCount++;
                if (frameCount == 1) {
                  AppLog.info('HttpCam', 'First MJPEG frame received (${jpegBytes.length} bytes)');
                }
                // Valid JPEG should be > 100 bytes
                if (!controller.isClosed) {
                  controller.add(Uint8List.fromList(jpegBytes));
                }
              }
            }

            // Remove processed data from buffer
            buffer = buffer.sublist(nextBoundary);
          }
        }
      } catch (e) {
        AppLog.error('HttpCam', 'Live view error after $frameCount frames', e);
        debugPrint('[HttpCamera] live view error: $e');
      } finally {
        _liveViewRunning = false;
        _liveViewResponse = null;
        if (!controller.isClosed) {
          controller.close();
        }
      }
    }();

    return controller.stream;
  }

  @override
  Future<void> stopLiveView() async {
    _liveViewRunning = false;
    _liveViewResponse = null;
    // The stream will detect _liveViewRunning==false and stop itself
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
    final capResponse = await _client
        .post(Uri.parse('$baseUrl/capture'))
        .timeout(const Duration(seconds: 5));

    if (capResponse.statusCode != 200) {
      throw Exception('Capture failed: HTTP ${capResponse.statusCode}');
    }

    final capResult = jsonDecode(capResponse.body) as Map<String, dynamic>;
    final filename = capResult['filename'] as String?;
    if (filename == null || capResult['status'] != 'ok') {
      throw Exception('Capture failed: unexpected response');
    }

    // Download the captured photo directly
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

  /// Sync phone time to camera RTC. Called on every connection.
  /// Fails silently — non-critical operation.
  Future<void> syncRtc() async {
    try {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      await _client.post(
        Uri.parse('$baseUrl/rtc'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'timestamp': now}),
      ).timeout(const Duration(seconds: 3));
    } catch (_) {
      // Silently ignore — RTC sync is best-effort
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
      final uri = Uri.parse('$baseUrl/list').replace(
        queryParameters: {
          'offset': offset.toString(),
          'limit': limit.toString(),
        },
      );
      final response = await _client.get(uri).timeout(_timeout);

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

      // Build CameraPhoto list — fetch thumbnails concurrently (max 6 at a time)
      final photos = <CameraPhoto>[];
      final semaphore = _Semaphore(6);

      await Future.wait(files.map((entry) async {
        await semaphore.acquire();
        try {
          Uint8List? thumbnail;
          if (entry.type == 'photo') {
            try {
              thumbnail = await _getThumbnailBytes(entry.name);
            } catch (_) {}
          }

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
      final response = await _client
          .get(Uri.parse('$baseUrl/thumb/$filename'))
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
      final request = http.Request('GET', Uri.parse('$baseUrl/file/$photoId'));
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
      final response = await _client
          .get(Uri.parse('$baseUrl/file/$photoId'))
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
      final response = await _client
          .delete(Uri.parse('$baseUrl/file/$photoId'))
          .timeout(const Duration(seconds: 5));

      return response.statusCode == 200;
    } catch (e) {
      debugPrint('[HttpCamera] deletePhoto error: $e');
      return false;
    }
  }

  /// Release HTTP client resources.
  void dispose() {
    _connectionCtrl.close();
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
