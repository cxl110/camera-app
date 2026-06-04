import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image/image.dart' as img;
import 'package:uuid/uuid.dart';
import 'camera_protocol.dart';

/// Mock camera protocol using phone camera and photo library.
///
/// When DIY camera is ready, swap this out for [HttpCameraProtocol].
class MockCameraProtocol extends CameraProtocol {
  final ImagePicker _picker = ImagePicker();
  final Uuid _uuid = const Uuid();
  final StreamController<ConnectionStatus> _connectionCtrl =
      StreamController<ConnectionStatus>.broadcast();

  // Simulated camera storage
  final List<_StoredPhoto> _storage = [];
  bool _isRecording = false;

  MockCameraProtocol() {
    // Always connected in mock mode
    _connectionCtrl.add(const ConnectionStatus(
      connected: true,
      ssid: 'DIY-CAM-001',
      signalStrength: 3,
      cameraBrand: 'DIY',
      cameraModel: 'ESP32-CAM',
    ));
  }

  @override
  Stream<ConnectionStatus> get connectionStream => _connectionCtrl.stream;

  @override
  Future<ConnectionStatus> getConnectionStatus() async {
    return _connectionCtrl.stream.first;
  }

  // ── Live View ──

  @override
  Stream<Uint8List> startLiveView() {
    // Mock: generate a static color frame every 200ms
    return Stream.periodic(const Duration(milliseconds: 200), (i) {
      return _generateMockFrame();
    });
  }

  Uint8List _generateMockFrame() {
    // Simple gradient frame as live view placeholder
    final image = img.Image(width: 640, height: 480);
    for (var y = 0; y < image.height; y++) {
      for (var x = 0; x < image.width; x++) {
        final r = (x * 255 ~/ image.width);
        final g = (y * 255 ~/ image.height);
        final b = 128;
        image.setPixelRgba(x, y, r, g, b, 255);
      }
    }
    return Uint8List.fromList(img.encodeJpg(image, quality: 60));
  }

  @override
  Future<void> stopLiveView() async {
    // No cleanup needed for mock
  }

  // ── Capture ──

  @override
  Future<CaptureResult> capturePhoto({bool flash = false}) async {
    try {
      final XFile? xfile = await _picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 95,
        preferredCameraDevice: CameraDevice.rear,
      );

      if (xfile == null) {
        throw Exception('用户取消拍照');
      }

      final bytes = await xfile.readAsBytes();
      final thumbnail = _generateThumbnail(bytes);
      final id = 'IMG_${_uuid.v4().substring(0, 8)}';
      final name = '$id.JPG';

      // Store in mock storage
      _storage.insert(0, _StoredPhoto(
        id: id,
        name: name,
        bytes: bytes,
        timestamp: DateTime.now(),
      ));

      return CaptureResult(
        id: id,
        name: name,
        sizeBytes: bytes.length,
        timestamp: DateTime.now(),
        thumbnail: thumbnail,
        fullImage: bytes,
      );
    } catch (e) {
      rethrow;
    }
  }

  @override
  Future<Uint8List?> getThumbnail(String photoId) async {
    final photo = _findPhoto(photoId);
    if (photo == null) return null;
    return _generateThumbnail(photo.bytes);
  }

  // ── Recording ──

  @override
  Future<void> startRecording() async {
    _isRecording = true;
  }

  @override
  Future<CaptureResult> stopRecording() async {
    _isRecording = false;
    final id = 'VID_${_uuid.v4().substring(0, 8)}';
    return CaptureResult(
      id: id,
      name: '$id.MP4',
      sizeBytes: 0,
      timestamp: DateTime.now(),
    );
  }

  // ── Storage ──

  @override
  Future<PhotoListResult> listPhotos({
    int offset = 0,
    int limit = 50,
    String sort = 'date_desc',
  }) async {
    // Mock: pick from phone gallery
    try {
      final List<XFile> xfiles = await _picker.pickMultiImage(
        imageQuality: 85,
        limit: limit,
      );

      final photos = <CameraPhoto>[];
      for (final xfile in xfiles) {
        final bytes = await xfile.readAsBytes();
        final id = 'GAL_${_uuid.v4().substring(0, 8)}';
        final name = xfile.name;

        // Store for later download
        _storage.add(_StoredPhoto(
          id: id,
          name: name,
          bytes: bytes,
          timestamp: DateTime.now(),
        ));

        photos.add(CameraPhoto(
          id: id,
          name: name,
          sizeBytes: bytes.length,
          timestamp: DateTime.now(),
          thumbnail: _generateThumbnail(bytes),
          fullImage: bytes,
        ));
      }

      return PhotoListResult(
        total: photos.length,
        offset: offset,
        limit: limit,
        photos: photos,
      );
    } catch (e) {
      // Return simulated storage if picker fails
      final photos = _storage
          .skip(offset)
          .take(limit)
          .map((s) => CameraPhoto(
                id: s.id,
                name: s.name,
                sizeBytes: s.bytes.length,
                timestamp: s.timestamp,
                thumbnail: _generateThumbnail(s.bytes),
                fullImage: s.bytes,
              ))
          .toList();

      return PhotoListResult(
        total: _storage.length,
        offset: offset,
        limit: limit,
        photos: photos,
      );
    }
  }

  @override
  Stream<DownloadProgress> downloadPhoto(String photoId,
      {PhotoQuality quality = PhotoQuality.original}) async* {
    final photo = _findPhoto(photoId);
    if (photo == null) {
      throw Exception('Photo not found: $photoId');
    }

    var imageBytes = photo.bytes;

    // Resize for quality
    if (quality == PhotoQuality.medium) {
      final decoded = img.decodeImage(imageBytes);
      if (decoded != null) {
        final resized = img.copyResize(decoded, width: 2048);
        imageBytes = Uint8List.fromList(img.encodeJpg(resized, quality: 85));
      }
    } else if (quality == PhotoQuality.small) {
      final decoded = img.decodeImage(imageBytes);
      if (decoded != null) {
        final resized = img.copyResize(decoded, width: 1024);
        imageBytes = Uint8List.fromList(img.encodeJpg(resized, quality: 80));
      }
    }

    // Simulate download progress
    final total = imageBytes.length;
    const chunkSize = 65536; // 64KB chunks
    for (var i = 0; i < total; i += chunkSize) {
      yield DownloadProgress(
        received: min(i + chunkSize, total),
        total: total,
      );
      await Future.delayed(const Duration(milliseconds: 20));
    }
  }

  @override
  Future<bool> deletePhoto(String photoId) async {
    _storage.removeWhere((s) => s.id == photoId);
    return true;
  }

  // ── Helpers ──

  _StoredPhoto? _findPhoto(String id) {
    try {
      return _storage.firstWhere((s) => s.id == id);
    } catch (_) {
      return null;
    }
  }

  Uint8List _generateThumbnail(Uint8List fullImage) {
    try {
      final decoded = img.decodeImage(fullImage);
      if (decoded == null) return fullImage;
      final thumb = img.copyResize(decoded, width: 160);
      return Uint8List.fromList(img.encodeJpg(thumb, quality: 60));
    } catch (_) {
      return fullImage;
    }
  }
}

class _StoredPhoto {
  final String id;
  final String name;
  final Uint8List bytes;
  final DateTime timestamp;

  _StoredPhoto({
    required this.id,
    required this.name,
    required this.bytes,
    required this.timestamp,
  });
}
