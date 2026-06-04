import 'dart:async';
import 'dart:typed_data';

/// Abstract camera communication protocol.
///
/// Implementations:
/// - [MockCameraProtocol] — uses phone camera + gallery for prototyping
/// - [HttpCameraProtocol] — communicates with DIY camera over WiFi (todo)
abstract class CameraProtocol {
  // ── Connection ──

  /// Check if camera is reachable. Returns current connection state.
  Future<ConnectionStatus> getConnectionStatus();

  /// Stream of connection status changes.
  Stream<ConnectionStatus> get connectionStream;

  // ── Live View ──

  /// Start MJPEG live view stream.
  /// Returns a stream of JPEG frame bytes.
  Stream<Uint8List> startLiveView();

  /// Stop live view stream.
  Future<void> stopLiveView();

  // ── Capture ──

  /// Capture a photo. Returns photo metadata and thumbnail.
  Future<CaptureResult> capturePhoto({bool flash = false});

  /// Get thumbnail for a previously captured photo.
  Future<Uint8List?> getThumbnail(String photoId);

  // ── Recording ──

  /// Start video recording.
  Future<void> startRecording();

  /// Stop video recording. Returns video metadata.
  Future<CaptureResult> stopRecording();

  // ── Storage ──

  /// List photos on camera storage. Supports pagination.
  Future<PhotoListResult> listPhotos({
    int offset = 0,
    int limit = 50,
    String sort = 'date_desc',
  });

  /// Download a full-resolution photo from camera.
  /// Returns a stream of download progress, completing with file bytes.
  Stream<DownloadProgress> downloadPhoto(String photoId, {PhotoQuality quality = PhotoQuality.original});

  /// Delete a photo from camera.
  Future<bool> deletePhoto(String photoId);
}

// ── Data Models ──

enum PhotoQuality { original, medium, small }

class ConnectionStatus {
  final bool connected;
  final String? ssid;
  final int? signalStrength; // 0-3
  final String? cameraBrand;
  final String? cameraModel;

  const ConnectionStatus({
    required this.connected,
    this.ssid,
    this.signalStrength,
    this.cameraBrand,
    this.cameraModel,
  });
}

class CaptureResult {
  final String id;
  final String name;
  final int sizeBytes;
  final DateTime timestamp;
  final Uint8List? thumbnail;
  final Uint8List? fullImage;

  const CaptureResult({
    required this.id,
    required this.name,
    required this.sizeBytes,
    required this.timestamp,
    this.thumbnail,
    this.fullImage,
  });
}

class CameraPhoto {
  final String id;
  final String name;
  final int sizeBytes;
  final DateTime timestamp;
  final Uint8List? thumbnail;
  final Uint8List? fullImage;

  const CameraPhoto({
    required this.id,
    required this.name,
    required this.sizeBytes,
    required this.timestamp,
    this.thumbnail,
    this.fullImage,
  });
}

class PhotoListResult {
  final int total;
  final int offset;
  final int limit;
  final List<CameraPhoto> photos;

  const PhotoListResult({
    required this.total,
    required this.offset,
    required this.limit,
    required this.photos,
  });
}

class DownloadProgress {
  final int received;
  final int total;
  double get percent => total > 0 ? received / total : 0.0;

  const DownloadProgress({required this.received, required this.total});
}
