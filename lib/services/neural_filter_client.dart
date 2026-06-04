import 'dart:typed_data';
import 'package:http/http.dart' as http;

/// Client for the Filter4Free neural inference server.
///
/// Calls the Python inference_server.py via HTTP.
/// Falls back to Dart FilterProcessor if server is unreachable.
class NeuralFilterClient {
  final String baseUrl;

  NeuralFilterClient({this.baseUrl = 'http://192.168.101.86:5000'});

  /// Check if the neural inference server is reachable.
  Future<bool> isAvailable() async {
    try {
      final response = await http
          .get(Uri.parse('$baseUrl/health'))
          .timeout(const Duration(seconds: 3));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Apply a neural film filter to an image.
  ///
  /// Returns filtered JPEG bytes, or null if server is unavailable.
  Future<Uint8List?> applyFilter({
    required Uint8List imageBytes,
    required String filterName,
    bool preview = false,
  }) async {
    try {
      final request = http.MultipartRequest('POST', Uri.parse('$baseUrl/filter'))
        ..files.add(http.MultipartFile.fromBytes(
          'image',
          imageBytes,
          filename: 'input.jpg',
        ))
        ..fields['filter'] = filterName
        ..fields['preview'] = preview.toString();

      final streamedResponse =
          await request.send().timeout(const Duration(seconds: 30));

      if (streamedResponse.statusCode == 200) {
        return await streamedResponse.stream.toBytes();
      }
    } catch (_) {
      // Server unreachable — caller should fall back to local processing
    }
    return null;
  }

  /// Get list of available filters from the server.
  Future<List<String>?> getAvailableFilters() async {
    try {
      final response = await http
          .get(Uri.parse('$baseUrl/filters'))
          .timeout(const Duration(seconds: 3));
      if (response.statusCode == 200) {
        // Parse JSON response
        return null; // Simplified — caller knows the filter list
      }
    } catch (_) {}
    return null;
  }
}
