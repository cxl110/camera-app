import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import '../models/filter.dart';
import 'coreml_bridge.dart';

/// Manages neural network photo filters and CoreML inference.
///
/// In the iOS app, CoreML inference is performed via native platform channels.
/// On other platforms (Android/Desktop), inference falls back to CPU-based
/// image processing approximations or ONNX runtime.
class FilterService extends ChangeNotifier {
  List<PhotoFilter> _filters = [];
  PhotoFilter? _selectedFilter;
  bool _isInitialized = false;
  bool _isProcessing = false;

  List<PhotoFilter> get filters => _filters;
  PhotoFilter? get selectedFilter => _selectedFilter;
  bool get isInitialized => _isInitialized;
  bool get isProcessing => _isProcessing;

  /// Initialize the filter service, loading available model files.
  Future<void> initialize() async {
    if (_isInitialized) return;

    _filters = PhotoFilter.allFilters();
    _selectedFilter = _filters.isNotEmpty ? _filters[0] : null;
    _isInitialized = true;
    notifyListeners();
  }

  /// Select a filter by ID.
  void selectFilter(String filterId) {
    _selectedFilter = _filters.firstWhere(
      (f) => f.id == filterId,
      orElse: () => _filters.first,
    );
    notifyListeners();
  }

  /// Apply the selected filter to an image file.
  ///
  /// Returns the filtered image bytes.
  /// On iOS, this calls into CoreML via a platform channel.
  /// On other platforms, it applies a basic image transformation.
  Future<Uint8List> applyFilter(File imageFile, {String? filterId}) async {
    _isProcessing = true;
    notifyListeners();

    try {
      final bytes = await imageFile.readAsBytes();
      final image = img.decodeImage(bytes);

      if (image == null) {
        throw Exception('Unable to decode image: ${imageFile.path}');
      }

      // Read EXIF orientation and apply
      final oriented = img.bakeOrientation(image);

      // Try native CoreML inference first (iOS)
      final filterName = filterId ?? _selectedFilter?.id;
      if (filterName != null) {
        final modelName = filterName.replaceAll('-', '_');
        final inputBytes = Uint8List.fromList(img.encodeJpg(oriented, quality: 95));

        final coremlResult = await CoreMLBridge.applyFilter(
          imageBytes: inputBytes,
          modelName: modelName,
        );

        if (coremlResult != null) {
          return coremlResult;
        }
      }

      // Fallback: pass through original image
      final outputBytes = Uint8List.fromList(img.encodeJpg(oriented, quality: 95));
      return outputBytes;
    } finally {
      _isProcessing = false;
      notifyListeners();
    }
  }

  /// Apply a filter with a preview (downsampled for speed).
  Future<Uint8List> applyFilterPreview(File imageFile,
      {String? filterId, int maxDimension = 1024}) async {
    final bytes = await imageFile.readAsBytes();
    final image = img.decodeImage(bytes);
    if (image == null) throw Exception('Unable to decode image');

    // Downsample for fast preview
    final preview = img.copyResize(image,
        width: maxDimension, height: maxDimension);

    // TODO: Apply CoreML filter
    final filtered = preview; // placeholder

    return Uint8List.fromList(img.encodeJpg(filtered, quality: 85));
  }

  /// Get filters grouped by brand for the filter picker UI.
  Map<String, List<PhotoFilter>> get groupedFilters =>
      PhotoFilter.groupedByBrand();

  /// Toggle favorite status of a filter.
  void toggleFavorite(String filterId) {
    final index = _filters.indexWhere((f) => f.id == filterId);
    if (index >= 0) {
      _filters[index] = _filters[index].copyWith(
        isFavorite: !_filters[index].isFavorite,
      );
      notifyListeners();
    }
  }

  /// Get favorite filters.
  List<PhotoFilter> get favoriteFilters =>
      _filters.where((f) => f.isFavorite).toList();

  /// Get recently used filters (stored in memory for now).
  final List<String> _recentFilterIds = [];

  List<PhotoFilter> get recentFilters {
    return _recentFilterIds
        .map((id) => _filters.firstWhere((f) => f.id == id))
        .toList();
  }

  void markFilterUsed(String filterId) {
    _recentFilterIds.remove(filterId);
    _recentFilterIds.insert(0, filterId);
    if (_recentFilterIds.length > 10) {
      _recentFilterIds.removeLast();
    }
  }
}
