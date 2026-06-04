import 'package:flutter/material.dart';
import '../widgets/film_presets.dart';
import '../widgets/grain_control.dart';
import '../widgets/light_leak_control.dart';
import '../widgets/bottom_tabs.dart';

/// EFFECTS filter page.
///
/// Only accessible when connected to camera WiFi.
/// Shows image preview, film presets, grain, and light leak controls.
class EffectsScreen extends StatefulWidget {
  final bool wifiConnected;

  const EffectsScreen({
    super.key,
    required this.wifiConnected,
  });

  @override
  State<EffectsScreen> createState() => _EffectsScreenState();
}

class _EffectsScreenState extends State<EffectsScreen> {
  bool _showBefore = false; // false=AFTER (filtered), true=BEFORE (original)

  // Film presets
  String _selectedPreset = 'CLASSIC CHROME';

  // Grain
  bool _grainEnabled = false;
  double _grainIntensity = 40.0;

  // Light leak
  bool _lightLeakEnabled = false;
  double _lightLeakIntensity = 30.0;
  String _lightLeakStyle = 'NONE';

  @override
  Widget build(BuildContext context) {
    // Block access when WiFi is disconnected
    if (!widget.wifiConnected) {
      return Scaffold(
        backgroundColor: const Color(0xFF0A0A0A),
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white54),
            onPressed: () => Navigator.pop(context),
          ),
        ),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.wifi_off, size: 48, color: Colors.white.withValues(alpha: 0.2)),
              const SizedBox(height: 16),
              Text(
                '请先连接相机WiFi',
                style: TextStyle(color: Colors.white.withValues(alpha: 0.3), fontSize: 15),
              ),
            ],
          ),
        ),
        bottomNavigationBar: BottomTabs(
          activeTab: 'effects',
          onTabChanged: (_) {},
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

            // ── Image Preview Area (~1/3) ──
            _buildPreviewArea(),

            // ── Scrollable Content ──
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  // ── FILM PRESETS ──
                  FilmPresets(
                    selectedPreset: _selectedPreset,
                    onPresetSelected: (preset) {
                      setState(() => _selectedPreset = preset);
                    },
                  ),

                  const SizedBox(height: 8),

                  // ── GRAIN ──
                  GrainControl(
                    enabled: _grainEnabled,
                    intensity: _grainIntensity,
                    onToggle: (v) => setState(() => _grainEnabled = v),
                    onIntensityChanged: (v) => setState(() => _grainIntensity = v),
                  ),

                  const SizedBox(height: 4),

                  // ── LIGHT LEAK ──
                  LightLeakControl(
                    enabled: _lightLeakEnabled,
                    intensity: _lightLeakIntensity,
                    selectedStyle: _lightLeakStyle,
                    onToggle: (v) => setState(() => _lightLeakEnabled = v),
                    onIntensityChanged: (v) => setState(() => _lightLeakIntensity = v),
                    onStyleChanged: (s) => setState(() => _lightLeakStyle = s),
                  ),

                  const SizedBox(height: 24),
                ],
              ),
            ),

            // ── Bottom Tabs ──
            BottomTabs(
              activeTab: 'effects',
              onTabChanged: (_) {},
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
      decoration: const BoxDecoration(
        color: Color(0xFF0A0A0A),
      ),
      child: Row(
        children: [
          // Back button
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white70, size: 22),
            onPressed: () => Navigator.pop(context),
            tooltip: '返回',
          ),

          const Spacer(),

          // Album button
          IconButton(
            icon: Icon(Icons.folder_outlined, color: Colors.white.withValues(alpha: 0.7), size: 22),
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('相机照片列表（页面开发中）'),
                  backgroundColor: Color(0xFF1A1A2E),
                  duration: Duration(seconds: 1),
                ),
              );
            },
            tooltip: '相册',
          ),
        ],
      ),
    );
  }

  Widget _buildPreviewArea() {
    return Container(
      height: MediaQuery.of(context).size.height * 0.32,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1E),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Stack(
        children: [
          // Preview image placeholder
          Center(
            child: Icon(
              Icons.image_outlined,
              size: 64,
              color: Colors.white.withValues(alpha: 0.1),
            ),
          ),

          // ── Top-left: Filter name ──
          Positioned(
            top: 10,
            left: 10,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                _selectedPreset,
                style: const TextStyle(
                  color: Color(0xFFD89A0F),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.2,
                ),
              ),
            ),
          ),

          // ── Top-right: BEFORE / AFTER toggle ──
          Positioned(
            top: 10,
            right: 10,
            child: Row(
              children: [
                _BeforeAfterChip(
                  label: 'BEFORE',
                  isActive: _showBefore,
                  onTap: () => setState(() => _showBefore = true),
                ),
                const SizedBox(width: 4),
                _BeforeAfterChip(
                  label: 'AFTER',
                  isActive: !_showBefore,
                  onTap: () => setState(() => _showBefore = false),
                ),
              ],
            ),
          ),

          // ── Center: BEFORE/AFTER indicator ──
          if (_showBefore)
            Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text(
                  'BEFORE',
                  style: TextStyle(color: Colors.white54, fontSize: 14, letterSpacing: 2),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Toggle chip for BEFORE / AFTER.
class _BeforeAfterChip extends StatelessWidget {
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  const _BeforeAfterChip({
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: isActive
              ? const Color(0xFFD89A0F)
              : Colors.black.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isActive ? Colors.black : Colors.white54,
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.5,
          ),
        ),
      ),
    );
  }
}
