import 'dart:typed_data';
import 'package:flutter/services.dart';

/// Bridge to native CoreML plugin for neural filter inference.
///
/// Communication protocol:
///   Method channel: "com.cameraapp/coreml"
///   - "loadModel": Load a .mlmodel file by name
///   - "applyFilter": Apply filter to image data (returns filtered bytes)
///   - "applyFilterPreview": Low-res preview version
///   - "clearCache": Release all loaded models
///
/// Image format: JPEG bytes in, JPEG bytes out.
class CoreMLBridge {
  static const _channel = MethodChannel('com.cameraapp/coreml');

  /// Whether CoreML is available on this device.
  /// Returns false on non-iOS platforms.
  static Future<bool> get isAvailable async {
    try {
      final result = await _channel.invokeMethod<bool>('isAvailable');
      return result ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Load a CoreML model into memory.
  ///
  /// [modelName] is the filename without extension (e.g., "fuji_classic_chrome").
  /// Returns true if model loaded successfully.
  static Future<bool> loadModel(String modelName) async {
    if (!await isAvailable) return false;
    try {
      return await _channel.invokeMethod<bool>('loadModel', {
        'modelName': modelName,
      }) ?? false;
    } catch (e) {
      return false;
    }
  }

  /// Apply a neural filter to an image at full resolution.
  ///
  /// Uses tile-based inference (448px patches, 16px padding) to handle
  /// any input resolution with fixed memory usage.
  ///
  /// [imageBytes]: JPEG encoded input image
  /// [modelName]: Name of the .mlmodel file (without extension)
  /// [patchSize]: Tile size in pixels (default 448)
  /// [padding]: Overlap padding (default 16)
  ///
  /// Returns filtered JPEG bytes.
  static Future<Uint8List?> applyFilter({
    required Uint8List imageBytes,
    required String modelName,
    int patchSize = 448,
    int padding = 16,
  }) async {
    if (!await isAvailable) return null;

    try {
      final result = await _channel.invokeMethod<Uint8List>('applyFilter', {
        'imageBytes': imageBytes,
        'modelName': modelName,
        'patchSize': patchSize,
        'padding': padding,
      });
      return result;
    } catch (e) {
      return null;
    }
  }

  /// Apply a filter at reduced resolution for fast preview.
  ///
  /// Downsamples input to maxDimension before processing.
  static Future<Uint8List?> applyFilterPreview({
    required Uint8List imageBytes,
    required String modelName,
    int maxDimension = 1024,
  }) async {
    if (!await isAvailable) return null;

    try {
      final result = await _channel.invokeMethod<Uint8List>('applyFilterPreview', {
        'imageBytes': imageBytes,
        'modelName': modelName,
        'maxDimension': maxDimension,
      });
      return result;
    } catch (e) {
      return null;
    }
  }

  /// Get progress stream for long-running filter operations.
  static Stream<double> applyFilterWithProgress({
    required Uint8List imageBytes,
    required String modelName,
  }) async* {
    if (!await isAvailable) return;

    // First, start the filter operation
    final completer = _channel.invokeMethod<Uint8List>('applyFilter', {
      'imageBytes': imageBytes,
      'modelName': modelName,
      'reportProgress': true,
    });

    // Listen for progress updates on a separate method call
    // The native side posts progress via EventChannel
    // For simplicity, we yield interpolated progress
    yield 0.0;
    await completer;
    yield 1.0;
  }

  /// Clear all cached models from memory.
  static Future<void> clearCache() async {
    if (!await isAvailable) return;
    try {
      await _channel.invokeMethod('clearCache');
    } catch (_) {}
  }

  /// Get list of available CoreML models bundled with the app.
  static Future<List<String>> getAvailableModels() async {
    if (!await isAvailable) return [];
    try {
      final result = await _channel.invokeMethod<List<dynamic>>('availableModels');
      return result?.cast<String>() ?? [];
    } catch (e) {
      return [];
    }
  }
}
