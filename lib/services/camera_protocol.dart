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

  // ── Sound Effects (API v1.6) ──

  /// Query the camera's capture sound effect switch (photo + recording start).
  ///
  /// Returns null when the camera cannot answer (not connected / old firmware
  /// that doesn't implement `/sound`).
  Future<SoundSetting?> getSoundEnabled();

  /// Set the camera's capture sound effect switch. The setting is persisted on
  /// the device (`/mnt/UDISK/sound_enabled`) and survives reboot.
  ///
  /// Throws [SoundControlException] when the camera rejects or cannot serve the
  /// request (e.g. old firmware returning 404).
  Future<SoundSetting> setSoundEnabled(bool enabled);
}

// ── Data Models ──

enum PhotoQuality { original, medium, small }

class ConnectionStatus {
  final bool connected;
  final String? ssid;
  final int? signalStrength; // 0-3
  final String? cameraBrand;
  final String? cameraModel;
  final String? fwVersion; // Firmware version, e.g. "V0.5-20260729"
  final bool? otaSupported; // Whether device supports WiFi OTA update

  const ConnectionStatus({
    required this.connected,
    this.ssid,
    this.signalStrength,
    this.cameraBrand,
    this.cameraModel,
    this.fwVersion,
    this.otaSupported,
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

// ── Sound Effect Switch (API v1.6 §12) ──

/// State of the camera's capture sound effect switch.
class SoundSetting {
  /// true = the photo / recording-start beep is on (factory default).
  final bool enabled;

  /// Whether the camera can actually answer `/sound` at all. Old firmware
  /// (pre-v1.6) returns 404 — the UI should then hide/disable the control
  /// instead of showing a switch that does nothing.
  final bool supported;

  /// true = the value was written to the device's persistent storage and will
  /// survive a reboot. false = applied now but NOT persisted (usually because
  /// the device's UDISK is read-only) — worth telling the user about.
  final bool persisted;

  const SoundSetting({
    required this.enabled,
    this.supported = true,
    this.persisted = true,
  });

  /// Camera cannot handle `/sound` (unsupported firmware / not reachable).
  static const SoundSetting unsupported = SoundSetting(
    enabled: true,
    supported: false,
    persisted: false,
  );
}

/// Raised when the camera refuses a `/sound` request.
class SoundControlException implements Exception {
  final String message;
  const SoundControlException(this.message);

  @override
  String toString() => message;
}

/// Raised when the camera rejects our access token (HTTP 403).
///
/// This is NOT a connection failure: `/info` and `/stream` may still answer,
/// only the token-checked endpoints refuse. Two flavours exist (API v1.7):
/// the token is simply wrong, or the device is inside its 60 s temporary
/// lockout after 10 consecutive failures ([locked] == true). There is no
/// permanent lockout in v1.7 — both situations recover on their own.
class CameraAuthException implements Exception {
  final String message;

  /// true = device answered `403 Locked` (temporary, auto-expires in 60 s).
  /// Retrying immediately is pointless; waiting is the correct response.
  final bool locked;

  const CameraAuthException(this.message, {this.locked = false});

  @override
  String toString() => message;
}

// ── OTA Firmware Update ──

/// OTA update status.
enum OtaStatus {
  idle, // No update in progress
  uploading, // Firmware image being uploaded
  flashing, // Device is flashing firmware
  rebooting, // Device is rebooting after flash
  done, // Update completed successfully
  failed, // Update failed
}

/// OTA progress event emitted during firmware update.
class OtaProgress {
  final OtaStatus status;
  final double percent; // 0.0 ~ 1.0 (upload progress only, 1.0 when done)
  final String? error;

  const OtaProgress({
    required this.status,
    this.percent = 0.0,
    this.error,
  });
}
