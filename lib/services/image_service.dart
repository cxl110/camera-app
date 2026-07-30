import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'neural_filter_client.dart';
import 'coreml_bridge.dart';
import 'app_log.dart';

/// Manages local photo storage, caching, and image operations.
class ImageService extends ChangeNotifier {
  final Uuid _uuid = const Uuid();
  Directory? _cacheDir;
  Directory? _editedDir;
  bool _isInitialized = false;

  /// Recently edited images for quick access.
  final List<_EditedImage> _recentEdits = [];

  /// Current photo shared across CAMERA / EFFECTS / BORDERS screens.
  Uint8List? originalPhoto;
  Uint8List? currentPhoto;
  String? currentPhotoName;

  // Filter state preserved across page navigations.
  String selectedPreset = 'NONE';
  bool grainEnabled = false;
  double grainIntensity = 40.0;
  bool lightLeakEnabled = false;
  double lightLeakIntensity = 30.0;
  String lightLeakStyle = 'WARM';

  bool get hasCurrentPhoto => currentPhoto != null;

  bool get isInitialized => _isInitialized;
  List<_EditedImage> get recentEdits => List.unmodifiable(_recentEdits);

  Future<void> initialize() async {
    if (_isInitialized) return;

    final appDir = await getApplicationDocumentsDirectory();
    _cacheDir = Directory(p.join(appDir.path, 'cache'));
    _editedDir = Directory(p.join(appDir.path, 'edited'));

    await _cacheDir?.create(recursive: true);
    await _editedDir?.create(recursive: true);

    _isInitialized = true;
    notifyListeners();
  }

  /// Load a new photo as the shared current photo.
  ///
  /// Resets both the original and the working copy.
  void loadPhoto(Uint8List bytes, {String? name}) {
    originalPhoto = bytes;
    currentPhoto = bytes;
    currentPhotoName = name ?? 'IMG_${DateTime.now().millisecondsSinceEpoch}.jpg';
    notifyListeners();
  }

  /// Update the working copy of the current photo (e.g. after filter/border).
  void updateCurrentPhoto(Uint8List bytes) {
    currentPhoto = bytes;
    notifyListeners();
  }

  /// Clear the shared current photo.
  void clearCurrentPhoto() {
    originalPhoto = null;
    currentPhoto = null;
    currentPhotoName = null;
    notifyListeners();
  }

  /// Composite a frame PNG over the photo.
  ///
  /// The photo itself is not resized or distorted. The frame is stretched to
  /// match the photo dimensions and then alpha-blended on top.
  Future<Uint8List> compositeBorder(Uint8List photoBytes, String frameFileName) async {
    // Read the frame asset on the main thread (isolate can't access rootBundle).
    final frameData = await rootBundle.load('assets/frames/$frameFileName');
    final frameBytes = frameData.buffer.asUint8List();

    // Run the heavy decode/resize/composite/encode in an isolate so the
    // saving spinner animates smoothly.
    return compute(_compositeBorderIsolate, {
      'photo': photoBytes,
      'frame': frameBytes,
    });
  }

  /// Isolate entry: stretch frame to photo dimensions and alpha-blend.
  static Uint8List _compositeBorderIsolate(Map<String, dynamic> params) {
    final photoBytes = params['photo'] as Uint8List;
    final frameBytes = params['frame'] as Uint8List;

    final photo = img.decodeImage(photoBytes);
    if (photo == null) return photoBytes;

    final frame = img.decodePng(frameBytes);
    if (frame == null) return photoBytes;

    // Stretch frame to photo dimensions (frame may be distorted/cropped).
    final stretchedFrame = img.copyResize(
      frame,
      width: photo.width,
      height: photo.height,
    );

    // Alpha-blend the frame on top of the photo.
    final composited = img.compositeImage(photo, stretchedFrame);
    return Uint8List.fromList(img.encodeJpg(composited, quality: 95));
  }

  /// Cache a downloaded image from a URL.
  Future<File> cacheImage(String url) async {
    final ext = p.extension(url).isNotEmpty ? p.extension(url) : '.jpg';
    final cacheFile = File(p.join(_cacheDir!.path, '${_uuid.v4()}$ext'));
    // Caching will be handled by the caller
    return cacheFile;
  }

  /// Save a photo to local storage and system gallery.
  ///
  /// By default applies x2 CoreML super-resolution before saving (3MP → 12MP).
  /// The APP UI always works with downsampled previews; full upscale only
  /// happens at save time.
  Future<File> saveWithUpscale(Uint8List imageBytes, String originalName,
      {NeuralFilterClient? neuralClient, bool upscale = true}) async {
    Uint8List finalBytes = imageBytes;

    if (upscale) {
      // Try CoreML on-device super-resolution upscale
      AppLog.info('ImageService', 'Upscale input: ${imageBytes.length} bytes');
      try {
        final coremlUpscaled = await CoreMLBridge.upscalePhoto(imageBytes: imageBytes);
        // Lanczos upscale is reliable — just check output is not empty.
        // No need for the expensive _isAllBlack decode check (that was for EDSR).
        if (coremlUpscaled != null && coremlUpscaled.length > 1000) {
          AppLog.info('ImageService',
              'Upscale done: ${imageBytes.length}B → ${coremlUpscaled.length}B');
          finalBytes = coremlUpscaled;
        } else {
          AppLog.error('ImageService', 'Upscale returned null or tiny output');
        }
      } catch (e) {
        AppLog.error('ImageService', 'Upscale failed, fallback to original', e);
      }
    }

    AppLog.info('ImageService',
        'Saving: ${finalBytes.length} bytes, upscale=$upscale, name=$originalName');

    final name = p.basenameWithoutExtension(originalName);
    final outputPath = p.join(_editedDir!.path, '${name}.jpg');
    final file = File(outputPath);
    await file.writeAsBytes(finalBytes);

    // Also save to system photo gallery so it shows in Photos.app
    try {
      final hasAccess = await Gal.hasAccess(toAlbum: false);
      if (!hasAccess) {
        final granted = await Gal.requestAccess(toAlbum: false);
        if (!granted) {
          AppLog.error('ImageService', 'Gallery access denied — photo saved to app storage only');
          return file;
        }
      }
      await Gal.putImageBytes(finalBytes, name: name);
      AppLog.info('ImageService', 'Saved to system gallery: $name');
    } catch (e) {
      AppLog.error('ImageService', 'Gallery save failed (file still in local storage)', e);
    }

    _recentEdits.insert(
      0,
      _EditedImage(
        path: outputPath,
        originalName: originalName,
        editedAt: DateTime.now(),
      ),
    );

    if (_recentEdits.length > 50) {
      _recentEdits.removeLast();
    }

    notifyListeners();
    return file;
  }

  /// Save an edited (filtered) image (without upscale).
  Future<File> saveEditedImage(Uint8List bytes, String originalName) async {
    final name = p.basenameWithoutExtension(originalName);
    final outputPath = p.join(_editedDir!.path, '${name}_edited.jpg');
    final file = File(outputPath);
    await file.writeAsBytes(bytes);

    _recentEdits.insert(
      0,
      _EditedImage(
        path: outputPath,
        originalName: originalName,
        editedAt: DateTime.now(),
      ),
    );

    if (_recentEdits.length > 50) {
      _recentEdits.removeLast();
    }

    notifyListeners();
    return file;
  }

  /// Get the path for a temporary preview file.
  Future<String> getPreviewPath(String originalName) async {
    final name = p.basenameWithoutExtension(originalName);
    return p.join(_cacheDir!.path, 'preview_$name.jpg');
  }

  /// Add watermark text to an image.
  Uint8List addTextWatermark(
    Uint8List imageBytes, {
    required String text,
    double opacity = 0.3,
    String fontFamily = 'Arial',
  }) {
    final image = img.decodeImage(imageBytes);
    if (image == null) return imageBytes;

    // Draw text watermark using the image library
    // For production, this would use a more sophisticated approach
    // with custom font rendering and positioning options
    final watermarked = img.drawString(
      image,
      text,
      font: img.arial24, // default font
      x: image.width - 200,
      y: image.height - 50,
      color: img.ColorRgba8(255, 255, 255, (opacity * 255).toInt()),
    );

    return Uint8List.fromList(img.encodeJpg(watermarked, quality: 95));
  }

  /// Clean up old cache files.
  Future<void> cleanCache({int maxAgeDays = 7}) async {
    if (_cacheDir == null) return;
    final cutoff = DateTime.now().subtract(Duration(days: maxAgeDays));

    await for (final file in _cacheDir!.list()) {
      if (file is File) {
        final stat = await file.stat();
        if (stat.modified.isBefore(cutoff)) {
          await file.delete();
        }
      }
    }
  }
}

/// Represents an edited image in local storage.
class _EditedImage {
  final String path;
  final String originalName;
  final DateTime editedAt;

  const _EditedImage({
    required this.path,
    required this.originalName,
    required this.editedAt,
  });
}
