import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'camera_protocol.dart';

/// V821CAM HTTP protocol implementation.
///
/// Communicates with the DIY camera dev board over WiFi.
/// Provides live view (MJPEG stream), photo capture, file listing,
/// download, thumbnail, and delete.
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
        final ssid = info['ssid'] as String? ?? 'V821CAM';

        // Only V821 devices are supported
        if (model == 'V821') {
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

    final controller = StreamController<Uint8List>();

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
    final response = _liveViewResponse;
    _liveViewResponse = null;
    if (response != null) {
      try {
        await response.cancel();
      } catch (_) {}
    }
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
    // POST /capture — trigger photo capture
    final capResponse = await _client
        .post(Uri.parse('$baseUrl/capture'))
        .timeout(const Duration(seconds: 5));

    if (capResponse.statusCode != 200) {
      throw Exception('Capture failed: HTTP ${capResponse.statusCode}');
    }

    // After capture, fetch the latest photo from list
    final listResult = await listPhotos(limit: 1);
    if (listResult.photos.isEmpty) {
      throw Exception('Capture succeeded but no photo found in list');
    }

    final photo = listResult.photos.first;
    final fullImage = await downloadPhotoBytes(photo.id);
    final thumbnail = photo.thumbnail ?? await getThumbnail(photo.id);

    return CaptureResult(
      id: photo.id,
      name: photo.name,
      sizeBytes: fullImage?.length ?? photo.sizeBytes,
      timestamp: photo.timestamp,
      thumbnail: thumbnail ?? fullImage,
      fullImage: fullImage ?? thumbnail,
    );
  }

  // ── Recording (unsupported) ──

  @override
  Future<void> startRecording() {
    throw UnsupportedError('V821CAM does not support recording');
  }

  @override
  Future<CaptureResult> stopRecording() {
    throw UnsupportedError('V821CAM does not support recording');
  }

  // ── Storage ──

  @override
  Future<PhotoListResult> listPhotos({
    int offset = 0,
    int limit = 50,
    String sort = 'date_desc',
  }) async {
    try {
      final response = await _client
          .get(Uri.parse('$baseUrl/list'))
          .timeout(_timeout);

      if (response.statusCode != 200) {
        return const PhotoListResult(total: 0, offset: 0, limit: 0, photos: []);
      }

      final List<dynamic> rawList = jsonDecode(response.body) as List<dynamic>;

      // Parse file entries
      final entries = rawList.map((e) => _FileEntry.fromJson(e as Map<String, dynamic>)).toList();

      // Sort: newest first (filename contains YYYYMMDD_HHMMSS, lexicographic = chronological)
      entries.sort((a, b) => b.name.compareTo(a.name));

      // Apply pagination
      final total = entries.length;
      final page = entries.skip(offset).take(limit).toList();

      // Build CameraPhoto list — fetch thumbnails concurrently (max 6 at a time)
      final photos = <CameraPhoto>[];
      final semaphore = _Semaphore(6);

      await Future.wait(page.map((entry) async {
        await semaphore.acquire();
        try {
          Uint8List? thumbnail;
          try {
            thumbnail = await _getThumbnailBytes(entry.name);
          } catch (_) {
            // Thumbnail fetch failure is non-fatal
          }

          photos.add(CameraPhoto(
            id: entry.name, // filename as id
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
      debugPrint('[HttpCamera] listPhotos error: $e');
      _emitStatus(const ConnectionStatus(connected: false));
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
      debugPrint('[HttpCamera] downloadPhoto error: $e');
      _emitStatus(const ConnectionStatus(connected: false));
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
