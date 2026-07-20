import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../services/camera_protocol.dart';
import '../services/image_service.dart';
import '../widgets/wifi_indicator.dart';
import '../widgets/camera_preview.dart';
import '../widgets/capture_controls.dart';
import '../widgets/bottom_tabs.dart';
import 'effects_screen.dart';
import 'borders_screen.dart';
import 'gallery_screen.dart';

/// Main camera screen.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  bool _isConnected = false;
  bool _isVerifying = true;
  String _activeTab = 'CAMERA';
  String? _cameraModel;

  StreamSubscription<ConnectionStatus>? _connectionSub;
  Stream<Uint8List>? _liveViewStream;

  CameraProtocol get _protocol => context.read<CameraProtocol>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initConnection();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _connectionSub?.cancel();
    _stopLiveView();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Only re-check connection if we were previously connected.
      // Don't show WiFi guide on resume — just silently retry.
      _retryConnection();
    } else if (state == AppLifecycleState.paused) {
      _stopLiveView();
    }
  }

  // ── Connection State Machine ──

  Future<void> _initConnection() async {
    // Listen for connection status changes
    _connectionSub = _protocol.connectionStream.listen((status) {
      if (!mounted) return;
      setState(() {
        _isConnected = status.connected;
        _cameraModel = status.cameraBrand;
        if (_isConnected) {
          _isVerifying = false;
          _startLiveView();
        } else {
          _stopLiveView();
        }
      });
    });

    // Initial check
    await _retryConnection();
    // If still not connected after initial check, show WiFi guide
    if (!mounted) return;
    if (!_isConnected) {
      _showWiFiGuide();
    }
  }

  Future<void> _retryConnection() async {
    try {
      final status = await _protocol.getConnectionStatus();
      if (!mounted) return;
      final wasConnected = _isConnected;
      setState(() {
        _isConnected = status.connected;
        _cameraModel = status.cameraBrand;
        _isVerifying = false;
      });
      if (status.connected && !wasConnected) {
        _startLiveView();
      }
    } catch (_) {
      // Silent retry — don't show WiFi guide on resume
    }
  }

  void _showWiFiGuide() {
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title: const Row(
          children: [
            Icon(Icons.wifi_find, color: Color(0xFFD89A0F), size: 24),
            SizedBox(width: 10),
            Text('连接相机WiFi', style: TextStyle(color: Colors.white, fontSize: 16)),
          ],
        ),
        content: const Text(
          '请先在系统设置中连接相机WiFi热点：\n\n'
          'SSID: V821CAM\n密码: 12345678\n\n'
          '连接成功后返回APP即可自动识别。',
          style: TextStyle(color: Colors.white60, fontSize: 14, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              // Open system WiFi settings
              try {
                const MethodChannel('com.cameraapp/system')
                    .invokeMethod('openWiFiSettings');
              } catch (_) {}
            },
            child: const Text('打开设置', style: TextStyle(color: Color(0xFFD89A0F))),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              _retryConnection();
            },
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF2D5BD8),
            ),
            child: const Text('已连接，重新检测'),
          ),
        ],
      ),
    );
  }

  // ── Live View ──

  void _startLiveView() {
    _stopLiveView();

    try {
      _liveViewStream = _protocol.startLiveView();
      // Reconnect on error after delay
      _liveViewStream!.listen(
        null,
        onError: (e) {
          debugPrint('[HomeScreen] live view error: $e');
          Future.delayed(const Duration(seconds: 3), () {
            if (mounted && _isConnected) _startLiveView();
          });
        },
        onDone: () {
          debugPrint('[HomeScreen] live view ended');
        },
      );
    } catch (e) {
      debugPrint('[HomeScreen] failed to start live view: $e');
    }
  }

  void _stopLiveView() {
    _liveViewStream = null;
    try {
      _protocol.stopLiveView();
    } catch (_) {}
  }

  // ── UI ──

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      body: SafeArea(
        child: Column(
          children: [
            _buildTopBar(),
            Expanded(
              child: CameraPreview(
                isConnected: _isConnected,
                frameStream: _liveViewStream,
              ),
            ),
            Selector<ImageService, Uint8List?>(
              selector: (_, service) => service.currentPhoto,
              builder: (_, currentPhoto, __) => CaptureControls(
                lastPhoto: currentPhoto,
                onShutter: _onShutterPressed,
                enabled: _isConnected,
              ),
            ),
            const SizedBox(height: 24),
            BottomTabs(
              activeTab: _activeTab,
              onTabChanged: _onTabChanged,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(color: Color(0xFF0A0A0A)),
      child: Row(
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              if (_isConnected) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('已连接 $_cameraModel'),
                    backgroundColor: const Color(0xFF1A1A2E),
                    duration: const Duration(seconds: 1),
                  ),
                );
              } else if (_isVerifying) {
                _retryConnection();
              } else {
                _showWiFiGuide();
              }
            },
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                WifiIndicator(isConnected: _isConnected),
                const SizedBox(width: 6),
                Text(
                  _isConnected ? '已连接' : (_isVerifying ? '检测中...' : '未连接'),
                  style: TextStyle(
                    color: _isConnected
                        ? const Color(0xFF4CAF50)
                        : const Color(0xFFF44336),
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          const Spacer(),
          IconButton(
            onPressed: _isConnected ? _onOpenGallery : null,
            icon: Icon(
              Icons.folder_outlined,
              color: Colors.white.withValues(alpha: _isConnected ? 0.7 : 0.2),
              size: 22,
            ),
            tooltip: '相机照片',
          ),
        ],
      ),
    );
  }

  void _onOpenGallery() async {
    if (!_isConnected) return;
    _stopLiveView();
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const GalleryScreen()),
    );
    if (_isConnected) _startLiveView();
  }

  void _onShutterPressed() async {
    if (!_isConnected) return;
    try {
      final result = await _protocol.capturePhoto();
      if (!mounted) return;

      final bytes = result.thumbnail ?? result.fullImage;
      if (bytes != null) {
        context.read<ImageService>().loadPhoto(bytes, name: result.name);
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('📸 ${result.name}'),
          backgroundColor: const Color(0xFF1A1A2E),
          duration: const Duration(milliseconds: 600),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.only(bottom: 160),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('拍照失败: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  void _onTabChanged(String tab) {
    if (tab == 'EFFECTS') {
      _stopLiveView();
      _navigateTo(EffectsScreen(wifiConnected: _isConnected)).then((_) {
        if (_isConnected) _startLiveView();
      });
      return;
    }
    if (tab == 'BORDERS') {
      _stopLiveView();
      _navigateTo(BordersScreen(wifiConnected: _isConnected)).then((_) {
        if (_isConnected) _startLiveView();
      });
      return;
    }
    setState(() => _activeTab = tab);
  }

  Future<void> _navigateTo(Widget page) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => page),
    );
  }
}
