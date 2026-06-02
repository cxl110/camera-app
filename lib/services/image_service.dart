import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

/// Manages local photo storage, caching, and image operations.
class ImageService extends ChangeNotifier {
  final Uuid _uuid = const Uuid();
  Directory? _cacheDir;
  Directory? _editedDir;
  bool _isInitialized = false;

  /// Recently edited images for quick access.
  final List<_EditedImage> _recentEdits = [];

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

  /// Cache a downloaded image from a URL.
  Future<File> cacheImage(String url) async {
    final ext = p.extension(url).isNotEmpty ? p.extension(url) : '.jpg';
    final cacheFile = File(p.join(_cacheDir!.path, '${_uuid.v4()}$ext'));
    // Caching will be handled by the caller
    return cacheFile;
  }

  /// Save an edited (filtered) image.
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

    // Keep only last 50 edits in memory
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
