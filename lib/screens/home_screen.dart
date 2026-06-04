import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/camera_service.dart';
import '../widgets/wifi_indicator.dart';
import '../widgets/camera_preview.dart';
import '../widgets/capture_controls.dart';
import '../widgets/bottom_tabs.dart';
import 'camera_connect_screen.dart';
import 'effects_screen.dart';

/// Main camera screen per user's mockup design.
///
/// Layout:
/// ┌──────────────────────────┐
/// │ [WiFi]            [📁]  │  Top bar
/// ├──────────────────────────┤
/// │                          │
/// │    Camera Live Preview   │  Viewfinder area
/// │   (black when disconnected)
/// │                          │
/// ├──────────────────────────┤
/// │ [📷]     [○]     [●]   │  Capture controls
/// │ thumb   shutter  record  │
/// ├──────────────────────────┤
/// │  CAMERA      EFFECTS     │  Bottom tabs
/// └──────────────────────────┘
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _wifiConnected = true; // 原型阶段默认模拟已连接
  bool _isRecording = false;
  Uint8List? _lastPhoto;
  String _activeTab = 'camera';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      body: SafeArea(
        child: Column(
          children: [
            // ── Top Bar ──
            _buildTopBar(),

            // ── Camera Viewfinder ──
            Expanded(
              child: CameraPreview(
                isConnected: _wifiConnected,
              ),
            ),

            // ── Capture Controls ──
            CaptureControls(
              lastPhoto: _lastPhoto,
              onShutter: _onShutterPressed,
              onRecord: _onRecordPressed,
              isRecording: _isRecording,
            ),

            const SizedBox(height: 24),

            // ── Bottom Tabs ──
            BottomTabs(
              activeTab: _activeTab,
              onTabChanged: _onTabChanged,
            ),
          ],
        ),
      ),
    );
  }

  /// Top bar with WiFi indicator (left) and folder button (right).
  Widget _buildTopBar() {
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(
        color: Color(0xFF0A0A0A),
      ),
      child: Row(
        children: [
          // WiFi signal indicator
          GestureDetector(
            onTap: () {
              // Toggle WiFi for demo purposes
              // In production, this would navigate to WiFi settings
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ChangeNotifierProvider(
                    create: (_) => CameraService(),
                    child: const CameraConnectScreen(),
                  ),
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

          // Folder button (camera photo list)
          IconButton(
            onPressed: () {
              // TODO: Open camera photo preview list
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('相机照片列表（页面开发中）'),
                  backgroundColor: Color(0xFF1A1A2E),
                  duration: Duration(seconds: 1),
                ),
              );
            },
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

  /// Shutter button pressed - take a photo.
  void _onShutterPressed() {
    // Simulate taking a photo
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('📸 拍照'),
        backgroundColor: Color(0xFF1A1A2E),
        duration: Duration(milliseconds: 600),
        behavior: SnackBarBehavior.floating,
        margin: EdgeInsets.only(bottom: 160),
      ),
    );

    // Simulate a dark thumbnail appearing
    setState(() {
      _lastPhoto = Uint8List.fromList([
        0x89, 0x50, 0x4E, 0x47 // minimal PNG header simulation
      ]);
    });
  }

  /// Record button pressed - start/stop video.
  void _onRecordPressed() {
    setState(() {
      _isRecording = !_isRecording;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(_isRecording ? '🔴 录制中...' : '⏹ 录制停止'),
        backgroundColor: _isRecording
            ? const Color(0xFFC62828)
            : const Color(0xFF1A1A2E),
        duration: const Duration(milliseconds: 800),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.only(bottom: 160),
      ),
    );
  }

  /// Bottom tab changed.
  void _onTabChanged(String tab) {
    if (tab == 'effects') {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => EffectsScreen(
            wifiConnected: _wifiConnected,
          ),
        ),
      );
      return;
    }
    setState(() {
      _activeTab = tab;
    });
  }
}
