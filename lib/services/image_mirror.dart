import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'app_log.dart';

/// Camera images are **not** mirrored — measured, not assumed.
///
/// History, because this cost a build cycle: an early report said the sensor was
/// mounted mirrored and the firmware could not fix it, so the app flipped every
/// camera image at ingest. That made the live preview and every photo appear
/// mirrored. The firmware side then explained the actual behaviour:
///
///   * the firmware mirrors **only its own LCD preview** (LUT `hflip=1`, commit
///     d545546) because of how the panel is mounted;
///   * the MJPEG `/stream` and the photo files (`/file`, `/thumb`) are already
///     correct and need no mirroring.
///
/// So the app must not flip anything. This code stays as an **opt-in** escape
/// hatch for a unit that really does deliver mirrored pixels:
///
///     --dart-define=MIRROR_CAMERA=true
///
/// Keep it off by default: flipping twice looks exactly like not flipping at all,
/// which is a very confusing bug to chase.
const bool kMirrorCameraImages = bool.fromEnvironment('MIRROR_CAMERA');

/// Live-stream mirror, separate switch: flipping the preview at render time is
/// cheaper than re-encoding every frame. Both default to off.
const bool kMirrorLiveStream = bool.fromEnvironment('MIRROR_STREAM');

/// Above this size the flip runs in a background isolate: a 12 MP JPEG is a few
/// hundred milliseconds of decode+encode, which would visibly jank the UI.
const int mirrorIsolateThreshold = 400 * 1024;

/// Flip [bytes] horizontally, preserving the container (JPEG stays JPEG).
///
/// Exposed separately from [mirrorCameraImage] so the flip itself can be tested
/// independently of the build-time switch.
Uint8List flipHorizontally(Uint8List bytes) {
  if (bytes.isEmpty) return bytes;

  try {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return bytes;

    // Bake any EXIF rotation into the pixels first: re-encoding drops the EXIF
    // block, so an orientation tag of 6/8 would otherwise be lost.
    final oriented = img.bakeOrientation(decoded);
    final flipped = img.flipHorizontal(oriented);

    if (_isPng(bytes)) {
      return Uint8List.fromList(img.encodePng(flipped));
    }
    return Uint8List.fromList(img.encodeJpg(flipped, quality: 95));
  } catch (e) {
    AppLog.info('Mirror', 'horizontal flip failed, keeping original bytes: $e');
    return bytes;
  }
}

/// Entry point used by the protocol layer. Returns [bytes] untouched unless the
/// build explicitly opted into mirroring (see [kMirrorCameraImages]).
Uint8List mirrorCameraImage(Uint8List bytes) =>
    kMirrorCameraImages ? flipHorizontally(bytes) : bytes;

/// True when [bytes] decode as an image (used by tests and diagnostics).
bool isDecodableImage(Uint8List bytes) {
  try {
    return img.decodeImage(bytes) != null;
  } catch (_) {
    return false;
  }
}

bool _isPng(Uint8List b) =>
    b.length > 8 &&
    b[0] == 0x89 &&
    b[1] == 0x50 &&
    b[2] == 0x4E &&
    b[3] == 0x47;
