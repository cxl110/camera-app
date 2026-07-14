import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/camera_protocol.dart';
import '../services/filter_processor.dart';
import '../widgets/film_presets.dart';
import '../widgets/grain_control.dart';
import '../widgets/light_leak_control.dart';
import '../widgets/bottom_tabs.dart';
import '../services/image_service.dart';
import '../services/neural_filter_client.dart';
import 'borders_screen.dart';

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
  bool _showBefore = false;
  Uint8List? _baseFilteredImage;  // Filter result without grain/leak (avoids re-running CoreML)
  Uint8List? _filteredImage;      // Final result with grain/leak applied (for display)
  Uint8List? _filterSource;       // The originalPhoto this filter was computed from

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
  void didChangeDependencies() {
    super.didChangeDependencies();
    final current = context.read<ImageService>().currentPhoto;
    // If the shared photo changed underneath us (e.g. new load or border saved),
    // drop the stale filtered preview and re-apply the current preset.
    if (current != null &&
        !identical(current, _filterSource) &&
        !identical(current, _filteredImage)) {
      setState(() {
        _filteredImage = null;
        _filterSource = current;
      });
      _applyFilter(_selectedPreset);
    }
  }

  @override
  Widget build(BuildContext context) {
    final imageService = context.watch<ImageService>();

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
          activeTab: 'EFFECTS',
          onTabChanged: (tab) => _onTabChanged(tab),
        ),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      body: SafeArea(
        child: Column(
          children: [
            // ── Top Bar ──
            _buildTopBar(imageService),

            // ── Image Preview Area (~1/3) ──
            _buildPreviewArea(imageService),

            // ── Scrollable Content ──
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  // ── FILM PRESETS ──
                  FilmPresets(
                    selectedPreset: _selectedPreset,
                    onPresetSelected: (preset) {
                      _applyFilter(preset);
                    },
                  ),

                  const SizedBox(height: 2),

                  // ── GRAIN ──
                  GrainControl(
                    enabled: _grainEnabled,
                    intensity: _grainIntensity,
                    onToggle: (v) {
                      setState(() => _grainEnabled = v);
                      _applyPostEffects();
                    },
                    onIntensityChanged: (v) {
                      setState(() => _grainIntensity = v);
                      _applyPostEffects();
                    },
                  ),

                  const SizedBox(height: 0),

                  // ── LIGHT LEAK ──
                  LightLeakControl(
                    enabled: _lightLeakEnabled,
                    intensity: _lightLeakIntensity,
                    selectedStyle: _lightLeakStyle,
                    onToggle: (v) {
                      setState(() => _lightLeakEnabled = v);
                      _applyPostEffects();
                    },
                    onIntensityChanged: (v) {
                      setState(() => _lightLeakIntensity = v);
                      _applyPostEffects();
                    },
                    onStyleChanged: (s) {
                      setState(() => _lightLeakStyle = s);
                      _applyPostEffects();
                    },
                  ),

                  const SizedBox(height: 8),
                ],
              ),
            ),

            // ── Bottom Tabs ──
            BottomTabs(
              activeTab: 'EFFECTS',
              onTabChanged: (tab) => _onTabChanged(tab),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar(ImageService imageService) {
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

          // Save button
          IconButton(
            icon: Icon(Icons.save_alt, color: Colors.white.withValues(alpha: 0.7), size: 22),
            onPressed: imageService.currentPhoto != null ? _onSaveFiltered : null,
            tooltip: '保存',
          ),

          // Album button
          IconButton(
            icon: Icon(Icons.folder_outlined, color: Colors.white.withValues(alpha: 0.7), size: 22),
            onPressed: _onOpenAlbum,
            tooltip: '相册',
          ),
        ],
      ),
    );
  }

  Widget _buildPreviewArea(ImageService imageService) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.42,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1E),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Stack(
        children: [
          // Preview image (show filtered by default, original when BEFORE)
          if (imageService.currentPhoto != null)
            Positioned.fill(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(7),
                child: Image.memory(
                  (_showBefore || _filteredImage == null)
                      ? (imageService.originalPhoto ?? imageService.currentPhoto!)
                      : _filteredImage!,
                  fit: BoxFit.contain,
                ),
              ),
            )
          else
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

        ],
      ),
    );
  }

  void _onOpenAlbum() async {
    final protocol = context.read<CameraProtocol>();
    final imageService = context.read<ImageService>();
    try {
      final result = await protocol.listPhotos(limit: 20);
      if (!mounted) return;

      if (result.photos.isNotEmpty) {
        final firstPhoto = result.photos.first;
        if (firstPhoto.fullImage != null) {
          imageService.loadPhoto(firstPhoto.fullImage!, name: firstPhoto.name);
          setState(() {
            _filteredImage = null;
            _baseFilteredImage = null;
            _filterSource = null;
          });
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已加载 ${result.photos.length} 张照片'),
            backgroundColor: const Color(0xFF1A1A2E),
          ),
        );
      }
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

  void _onSaveFiltered() async {
    final imageService = context.read<ImageService>();
    final output = _filteredImage ?? imageService.currentPhoto;
    if (output == null) return;
    try {
      final neuralClient = NeuralFilterClient();
      await imageService.saveWithUpscale(
        output,
        imageService.currentPhotoName ?? '${_selectedPreset}_${DateTime.now().millisecondsSinceEpoch}',
        neuralClient: neuralClient,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已保存 $_selectedPreset (x2超分)'),
          backgroundColor: const Color(0xFF2E7D32),
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败: $e'), backgroundColor: Colors.red),
      );
    }
  }

  void _onTabChanged(String tab) {
    if (tab == 'BORDERS') {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => BordersScreen(wifiConnected: widget.wifiConnected),
        ),
      );
      return;
    }
    if (tab == 'CAMERA') {
      Navigator.pop(context);
      return;
    }
  }

  void _applyFilter(String preset) {
    final imageService = context.read<ImageService>();
    // Always apply filter from the ORIGINAL photo, not the already-filtered one.
    // This prevents stacking filters on top of each other when switching presets.
    final source = imageService.originalPhoto ?? imageService.currentPhoto;
    if (source == null) return;

    // Immediately highlight selected preset
    setState(() {
      _selectedPreset = preset;
      _showBefore = false; // show current filtered result while loading
      _filterSource = source;
    });

    // Process neural inference in background
    FilterProcessor.apply(source, preset).then((filtered) {
      if (!mounted) return;
      _baseFilteredImage = filtered;
      // Now apply grain/leak on top
      _applyPostEffects();
    });
  }

  /// Apply grain and light leak post-processing on top of [_baseFilteredImage].
  ///
  /// This is fast (Dart-only pixel ops) and does NOT re-run CoreML,
  /// so adjusting grain/leak sliders is responsive.
  void _applyPostEffects() {
    final base = _baseFilteredImage;
    if (base == null) return;

    final imageService = context.read<ImageService>();

    final grainI = _grainEnabled ? _grainIntensity : 0.0;
    final leakRange = _lightLeakEnabled ? _lightLeakIntensity : 0.0;
    // Light leak intensity is proportional to range so brighter leaks reach further
    final leakI = leakRange > 0 ? (30.0 + leakRange * 0.7) : 0.0;

    // Run post-processing asynchronously to avoid jank on the UI thread.
    Future(() {
      return FilterProcessor.applyPostEffects(
        base,
        grainIntensity: grainI,
        lightLeakIntensity: leakI,
        lightLeakRange: leakRange,
        lightLeakStyle: _lightLeakStyle,
        imageName: imageService.currentPhotoName,
      );
    }).then((result) {
      if (!mounted) return;
      imageService.updateCurrentPhoto(result); // share with BORDERS
      setState(() => _filteredImage = result);
    });
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
