import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/camera_protocol.dart';
import '../widgets/bottom_tabs.dart';

/// BORDERS page — select film frame overlay and adjust thickness.
///
/// Shares selected photo with EFFECTS page.
class BordersScreen extends StatefulWidget {
  final bool wifiConnected;
  final Uint8List? selectedPhoto;

  const BordersScreen({
    super.key,
    required this.wifiConnected,
    this.selectedPhoto,
  });

  @override
  State<BordersScreen> createState() => _BordersScreenState();
}

class _BordersScreenState extends State<BordersScreen> {
  Uint8List? _previewImage;
  String? _selectedBorder;
  double _borderThickness = 100; // 0-100%, 100 = original

  static const _borderFiles = [
    'frame_00.png', 'frame_06.png', 'frame_07.png', 'frame_09.png',
    'frame_10.png', 'frame_11.png', 'frame_12.png', 'frame_13.png',
    'frame_14.png', 'frame_16.png', 'frame_17.png', 'frame_18.png',
    'frame_19.png', 'frame_21.png', 'frame_22.png', 'frame_23.png',
    'frame_24.png', 'frame_25.png', 'frame_26.png', 'frame_27.png',
    'kodak 400 52.png', 'kodak 400 52_2.png',
  ];

  @override
  void initState() {
    super.initState();
    if (widget.selectedPhoto != null) {
      _previewImage = widget.selectedPhoto;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.wifiConnected) {
      return Scaffold(
        backgroundColor: const Color(0xFF0A0A0A),
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white54),
            onPressed: () => Navigator.pop(context, _previewImage),
          ),
        ),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.wifi_off, size: 48,
                  color: Colors.white.withValues(alpha: 0.2)),
              const SizedBox(height: 16),
              Text('请先连接相机WiFi',
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.3), fontSize: 15)),
            ],
          ),
        ),
        bottomNavigationBar: BottomTabs(
          activeTab: 'BORDERS',
          onTabChanged: (tab) {
            if (tab == 'CAMERA') {
              Navigator.popUntil(context, (route) => route.isFirst);
            } else if (tab == 'EFFECTS') {
              Navigator.pop(context, _previewImage);
            }
          },
        ),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      body: SafeArea(
        child: Column(
          children: [
            // ── Top Bar ──
            _buildTopBar(),

            // ── Image Preview ──
            _buildPreview(),

            // ── Border Grid ──
            _buildBorderGrid(),

            // ── Thickness Slider ──
            _buildThicknessSlider(),

            // ── Bottom Tabs ──
            BottomTabs(
              activeTab: 'BORDERS',
              onTabChanged: (tab) {
                if (tab == 'CAMERA') Navigator.popUntil(context, (route) => route.isFirst);
                if (tab == 'EFFECTS') Navigator.pop(context, _previewImage);
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: const BoxDecoration(color: Color(0xFF0A0A0A)),
      child: Row(
        children: [
          // Back button
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white70, size: 22),
            onPressed: () => Navigator.pop(context, _previewImage),
            tooltip: '返回',
          ),

          const Spacer(),

          // Save button
          IconButton(
            icon: Icon(Icons.save_alt,
                color: _selectedBorder != null
                    ? Colors.white.withValues(alpha: 0.7)
                    : Colors.white.withValues(alpha: 0.2),
                size: 22),
            onPressed: _selectedBorder != null ? _onSave : null,
            tooltip: '保存',
          ),

          // Select image button
          IconButton(
            icon: Icon(Icons.add_photo_alternate_outlined,
                color: Colors.white.withValues(alpha: 0.7), size: 22),
            onPressed: _onSelectImage,
            tooltip: '选择图片',
          ),
        ],
      ),
    );
  }

  Widget _buildPreview() {
    return Container(
      height: MediaQuery.of(context).size.height * 0.30,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: _previewImage != null ? Colors.transparent : const Color(0xFF1A1A1E),
        borderRadius: BorderRadius.circular(8),
      ),
      child: _previewImage != null
          ? Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(7),
                  child: Image.memory(_previewImage!, fit: BoxFit.contain, width: double.infinity, height: double.infinity),
                ),
                // Border overlay would go here in production
                if (_selectedBorder != null)
                  Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '${_selectedBorder!.replaceAll('.png', '')}  ${_borderThickness.round()}%',
                        style: const TextStyle(color: Color(0xFFD89A0F), fontSize: 11),
                      ),
                    ),
                  ),
              ],
            )
          : Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.image_outlined, size: 48,
                      color: Colors.white.withValues(alpha: 0.15)),
                  const SizedBox(height: 8),
                  Text('请选择图片',
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.25), fontSize: 13)),
                ],
              ),
            ),
    );
  }

  Widget _buildBorderGrid() {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              'BORDERS',
              style: TextStyle(
                color: Colors.white38, fontSize: 11,
                fontWeight: FontWeight.w600, letterSpacing: 2,
              ),
            ),
          ),
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 4,
                mainAxisSpacing: 6,
                crossAxisSpacing: 6,
                childAspectRatio: 1.35,
              ),
              itemCount: _borderFiles.length,
              itemBuilder: (context, index) {
                final file = _borderFiles[index];
                final isSelected = _selectedBorder == file;
                return GestureDetector(
                  onTap: () => setState(() => _selectedBorder = file),
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: isSelected
                            ? const Color(0xFFD89A0F)
                            : Colors.white.withValues(alpha: 0.08),
                        width: isSelected ? 2 : 1,
                      ),
                      color: Colors.white.withValues(alpha: 0.03),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(5),
                      child: Image.asset(
                        'assets/frames/$file',
                        fit: BoxFit.contain,
                        errorBuilder: (_, __, ___) => Center(
                          child: Icon(Icons.crop_free,
                              size: 20,
                              color: Colors.white.withValues(alpha: 0.15)),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildThicknessSlider() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Row(
        children: [
          const Text(
            'THICKNESS',
            style: TextStyle(
              color: Colors.white, fontSize: 12, fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '${_borderThickness.round()}%',
            style: const TextStyle(
              color: Color(0xFFD89A0F), fontSize: 12, fontWeight: FontWeight.w600,
            ),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderThemeData(
                trackHeight: 3,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                activeTrackColor: const Color(0xFFD89A0F),
                inactiveTrackColor: Colors.white.withValues(alpha: 0.1),
                thumbColor: const Color(0xFFD89A0F),
                overlayColor: const Color(0xFFD89A0F).withValues(alpha: 0.1),
              ),
              child: Slider(
                value: _borderThickness,
                min: 10,
                max: 100,
                onChanged: (v) => setState(() => _borderThickness = v),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _onSelectImage() async {
    final protocol = context.read<CameraProtocol>();
    try {
      final result = await protocol.listPhotos(limit: 20);
      if (!mounted) return;
      if (result.photos.isNotEmpty && result.photos.first.fullImage != null) {
        setState(() => _previewImage = result.photos.first.fullImage);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('加载失败: $e'), backgroundColor: Colors.red),
      );
    }
  }

  void _onSave() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已保存 $_selectedBorder (${_borderThickness.round()}%)'),
        backgroundColor: const Color(0xFF2E7D32),
        duration: const Duration(seconds: 1),
      ),
    );
  }
}
