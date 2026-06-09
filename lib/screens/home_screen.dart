import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/camera_protocol.dart';
import '../widgets/wifi_indicator.dart';
import '../widgets/camera_preview.dart';
import '../widgets/capture_controls.dart';
import '../widgets/bottom_tabs.dart';
import 'effects_screen.dart';
import 'borders_screen.dart';

/// Main camera screen.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _wifiConnected = true; // Prototype: always connected
  bool _isRecording = false;
  Uint8List? _lastPhoto;
  String _activeTab = 'camera';

  CameraProtocol get _protocol => context.read<CameraProtocol>();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      body: SafeArea(
        child: Column(
          children: [
            _buildTopBar(),
            Expanded(
              child: CameraPreview(isConnected: _wifiConnected),
            ),
            CaptureControls(
              lastPhoto: _lastPhoto,
              onShutter: _onShutterPressed,
              onRecord: _onRecordPressed,
              isRecording: _isRecording,
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
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('已连接 DIY-CAM-001'),
                  backgroundColor: Color(0xFF1A1A2E),
                  duration: Duration(seconds: 1),
                ),
              );
            },
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                WifiIndicator(isConnected: _wifiConnected),
                const SizedBox(width: 6),
                Text(
                  _wifiConnected ? '已连接' : '未连接',
                  style: TextStyle(
                    color: _wifiConnected
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
            onPressed: _onOpenGallery,
            icon: Icon(
              Icons.folder_outlined,
              color: Colors.white.withValues(alpha: 0.7),
              size: 22,
            ),
            tooltip: '相机照片',
          ),
        ],
      ),
    );
  }

  void _onOpenGallery() async {
    try {
      final result = await _protocol.listPhotos(limit: 20);
      if (!mounted) return;

      if (result.photos.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('相册为空'),
            backgroundColor: Color(0xFF1A1A2E),
          ),
        );
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已加载 ${result.photos.length} 张照片'),
          backgroundColor: const Color(0xFF1A1A2E),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('加载失败: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  void _onShutterPressed() async {
    try {
      final result = await _protocol.capturePhoto();
      if (!mounted) return;
      setState(() {
        _lastPhoto = result.thumbnail ?? result.fullImage;
      });
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

  void _onRecordPressed() async {
    if (_isRecording) {
      try {
        final result = await _protocol.stopRecording();
        if (!mounted) return;
        setState(() => _isRecording = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('⏹ ${result.name}'),
            backgroundColor: const Color(0xFF1A1A2E),
            duration: const Duration(milliseconds: 800),
            behavior: SnackBarBehavior.floating,
            margin: const EdgeInsets.only(bottom: 160),
          ),
        );
      } catch (e) {
        if (!mounted) return;
        setState(() => _isRecording = false);
      }
    } else {
      await _protocol.startRecording();
      if (!mounted) return;
      setState(() => _isRecording = true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('🔴 录制中...'),
          backgroundColor: Color(0xFFC62828),
          duration: Duration(milliseconds: 800),
          behavior: SnackBarBehavior.floating,
          margin: EdgeInsets.only(bottom: 160),
        ),
      );
    }
  }

  void _onTabChanged(String tab) {
    if (tab == 'effects') {
      _navigateTo(EffectsScreen(wifiConnected: _wifiConnected));
      return;
    }
    if (tab == 'borders') {
      _navigateTo(BordersScreen(wifiConnected: _wifiConnected));
      return;
    }
    setState(() => _activeTab = tab);
  }

  void _navigateTo(Widget page) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => page),
    );
  }
}
