import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Manages WiFi connection to cameras and photo transfer.
///
/// Most modern cameras (Sony, Fujifilm, Canon, Nikon, etc.) expose a
/// WiFi access point and a simple HTTP API for photo browsing and download.
///
/// Common camera WiFi API patterns:
/// - Sony: http://192.168.122.1:8080/  (Camera Remote API)
/// - Fujifilm: http://192.168.0.1/      (PC AutoSave)
/// - Canon: http://192.168.1.1/         (Camera Connect)
/// - Nikon: http://192.168.1.1/         (SnapBridge / WMU)
enum CameraBrand {
  auto,
  sony,
  fujifilm,
  canon,
  nikon,
  gopro,
  dji,
}

enum ConnectionState {
  disconnected,
  connecting,
  connected,
  transferring,
  error,
}

/// Represents a photo on a connected camera.
class CameraPhoto {
  final String id;
  final String name;
  final String url;
  final int sizeBytes;
  final DateTime? dateTaken;
  final String? thumbnailUrl;

  const CameraPhoto({
    required this.id,
    required this.name,
    required this.url,
    this.sizeBytes = 0,
    this.dateTaken,
    this.thumbnailUrl,
  });
}

/// Service for WiFi camera connectivity and photo transfer.
class CameraService extends ChangeNotifier {
  ConnectionState _state = ConnectionState.disconnected;
  String? _connectedSSID;
  String? _cameraBaseUrl;
  CameraBrand _detectedBrand = CameraBrand.auto;
  String? _errorMessage;
  final List<CameraPhoto> _photos = [];

  // Transfer progress tracking
  double _transferProgress = 0.0;
  int _transferredCount = 0;
  int _totalCount = 0;

  ConnectionState get state => _state;
  String? get connectedSSID => _connectedSSID;
  String? get cameraBaseUrl => _cameraBaseUrl;
  CameraBrand get detectedBrand => _detectedBrand;
  String? get errorMessage => _errorMessage;
  List<CameraPhoto> get photos => List.unmodifiable(_photos);
  double get transferProgress => _transferProgress;
  int get transferredCount => _transferredCount;
  int get totalCount => _totalCount;

  final http.Client _httpClient = http.Client();

  /// Try to connect to a camera at the given base URL.
  Future<bool> connect({String? baseUrl, String? ssid}) async {
    _state = ConnectionState.connecting;
    _errorMessage = null;
    _connectedSSID = ssid;
    notifyListeners();

    try {
      _cameraBaseUrl = baseUrl ?? await _autoDetectCamera();

      if (_cameraBaseUrl == null) {
        _state = ConnectionState.error;
        _errorMessage = '未检测到相机设备，请确认已连接相机WiFi';
        notifyListeners();
        return false;
      }

      // Try to get camera info to verify connection
      final response = await _httpClient
          .get(Uri.parse('$_cameraBaseUrl/info'))
          .timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        _state = ConnectionState.connected;
        _detectedBrand = _detectBrand(_cameraBaseUrl!);
        notifyListeners();
        return true;
      }

      // Even without /info endpoint, if we can reach the camera, consider it connected
      _state = ConnectionState.connected;
      notifyListeners();
      return true;
    } on TimeoutException {
      _state = ConnectionState.error;
      _errorMessage = '连接超时，请检查相机WiFi设置';
      notifyListeners();
      return false;
    } catch (e) {
      _state = ConnectionState.error;
      _errorMessage = '连接失败: $e';
      notifyListeners();
      return false;
    }
  }

  /// List photos available on the connected camera.
  Future<List<CameraPhoto>> listPhotos({int maxCount = 100}) async {
    if (_cameraBaseUrl == null || _state != ConnectionState.connected) {
      return [];
    }

    try {
      final response = await _httpClient
          .get(Uri.parse('$_cameraBaseUrl/photos'))
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        // Parse camera-specific photo list format
        _photos.clear();
        // TODO: Parse based on camera brand
        _photos.addAll(_parsePhotos(response.body));
        notifyListeners();
        return _photos;
      }

      // Try alternative endpoints based on brand
      return await _tryAlternativePhotoList();
    } catch (e) {
      _errorMessage = '无法获取照片列表: $e';
      return [];
    }
  }

  /// Download a single photo from the camera.
  Future<File?> downloadPhoto(CameraPhoto photo,
      {required String savePath}) async {
    if (_cameraBaseUrl == null) return null;

    try {
      final response = await _httpClient
          .get(Uri.parse(photo.url))
          .timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        final file = File(savePath);
        await file.writeAsBytes(response.bodyBytes);
        return file;
      }
    } catch (e) {
      _errorMessage = '下载失败: $e';
    }
    return null;
  }

  /// Download all photos from the camera.
  Stream<double> downloadAllPhotos(String saveDir) async* {
    if (_photos.isEmpty) {
      await listPhotos();
    }

    _state = ConnectionState.transferring;
    _totalCount = _photos.length;
    _transferredCount = 0;
    _transferProgress = 0.0;
    notifyListeners();

    for (final photo in _photos) {
      final savePath = '$saveDir/${photo.name}';
      await downloadPhoto(photo, savePath: savePath);
      _transferredCount++;
      _transferProgress = _transferredCount / _totalCount;
      notifyListeners();
      yield _transferProgress;
    }

    _state = ConnectionState.connected;
    _transferProgress = 1.0;
    notifyListeners();
  }

  /// Disconnect from the camera.
  void disconnect() {
    _state = ConnectionState.disconnected;
    _cameraBaseUrl = null;
    _connectedSSID = null;
    _detectedBrand = CameraBrand.auto;
    _photos.clear();
    _errorMessage = null;
    _httpClient.close();
    notifyListeners();
  }

  /// Try to auto-detect camera by probing known URLs.
  Future<String?> _autoDetectCamera() async {
    // Common camera IPs to probe
    final knownUrls = [
      'http://192.168.122.1:8080',  // Sony
      'http://192.168.0.1',          // Fujifilm
      'http://192.168.1.1',          // Canon/Nikon
      'http://10.0.0.1',             // Various
      'http://192.168.122.1',        // Sony (alt)
    ];

    for (final url in knownUrls) {
      try {
        final response = await _httpClient
            .get(Uri.parse(url))
            .timeout(const Duration(seconds: 3));
        if (response.statusCode < 500) {
          return url;
        }
      } catch (_) {
        // Continue to next URL
      }
    }
    return null;
  }

  CameraBrand _detectBrand(String url) {
    if (url.contains('192.168.122.1')) return CameraBrand.sony;
    if (url.contains('192.168.0.1')) return CameraBrand.fujifilm;
    return CameraBrand.auto;
  }

  List<CameraPhoto> _parsePhotos(String body) {
    // TODO: Parse camera-specific JSON/XML responses
    // Each camera brand has a different photo list format
    return [];
  }

  Future<List<CameraPhoto>> _tryAlternativePhotoList() async {
    // Try different endpoints depending on brand
    final altEndpoints = [
      '/api/photos',
      '/media',
      '/DCIM',
      '/list',
    ];

    for (final endpoint in altEndpoints) {
      try {
        final response = await _httpClient
            .get(Uri.parse('$_cameraBaseUrl$endpoint'))
            .timeout(const Duration(seconds: 5));
        if (response.statusCode == 200) {
          return _parsePhotos(response.body);
        }
      } catch (_) {}
    }
    return [];
  }

  @override
  void dispose() {
    _httpClient.close();
    super.dispose();
  }
}
