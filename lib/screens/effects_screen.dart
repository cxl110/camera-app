import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/filter_processor.dart';
import '../widgets/film_presets.dart';
import '../widgets/grain_control.dart';
import '../widgets/light_leak_control.dart';
import '../widgets/bottom_tabs.dart';
import '../services/image_service.dart';
import '../services/neural_filter_client.dart';
import 'borders_screen.dart';
import 'gallery_screen.dart';

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

  /// The photo bytes that the current filter was computed from.
  /// Used to detect when a NEW photo is loaded (not a post-effect update).
  Uint8List? _originalSource;

  /// The filtered image displayed in the preview (includes grain/leak).
  Uint8List? _displayImage;

  /// The pure filter result (no grain/leak). Cached so we don't re-run CoreML
  /// when only grain/leak settings change.
  Uint8List? _baseFilteredImage;

  // Debounce timer for post-effect slider changes
  Timer? _postEffectTimer;
  bool _isProcessing = false;
  bool _isSaving = false;

  // Claude-style reasoning spinner
  Timer? _spinnerTimer;
  int _spinnerIndex = 0;
  bool _showSpinner = false;

  static const _spinnerVerbs = [
    'Accomplishing', 'Actioning', 'Actualizing', 'Architecting', 'Baking',
    'Beaming', "Beboppin'", 'Befuddling', 'Billowing', 'Blanching',
    'Bloviating', 'Boogieing', 'Boondoggling', 'Booping', 'Bootstrapping',
    'Brewing', 'Bunning', 'Burrowing', 'Calculating', 'Canoodling',
    'Caramelizing', 'Cascading', 'Catapulting', 'Cerebrating', 'Channeling',
    'Channelling', 'Choreographing', 'Churning', 'Clauding', 'Coalescing',
    'Cogitating', 'Combobulating', 'Composing', 'Computing', 'Concocting',
    'Considering', 'Contemplating', 'Cooking', 'Crafting', 'Creating',
    'Crunching', 'Crystallizing', 'Cultivating', 'Deciphering', 'Deliberating',
    'Determining', 'Dilly-dallying', 'Discombobulating', 'Doing', 'Doodling',
    'Drizzling', 'Ebbing', 'Effecting', 'Elucidating', 'Embellishing',
    'Enchanting', 'Envisioning', 'Evaporating', 'Fermenting', 'Fiddle-faddling',
    'Finagling', 'Flambéing', 'Flibbertigibbeting', 'Flowing', 'Flummoxing',
    'Fluttering', 'Forging', 'Forming', 'Frolicking', 'Frosting',
    'Gallivanting', 'Galloping', 'Garnishing', 'Generating', 'Gesticulating',
    'Germinating', 'Gitifying', 'Grooving', 'Gusting', 'Harmonizing',
    'Hashing', 'Hatching', 'Herding', 'Honking', 'Hullaballooing',
    'Hyperspacing', 'Ideating', 'Imagining', 'Improvising', 'Incubating',
    'Inferring', 'Infusing', 'Ionizing', 'Jitterbugging', 'Julienning',
    'Kneading', 'Leavening', 'Levitating', 'Lollygagging', 'Manifesting',
    'Marinating', 'Meandering', 'Metamorphosing', 'Misting', 'Moonwalking',
    'Moseying', 'Mulling', 'Mustering', 'Musing', 'Nebulizing', 'Nesting',
    'Newspapering', 'Noodling', 'Nucleating', 'Orbiting', 'Orchestrating',
    'Osmosing', 'Perambulating', 'Percolating', 'Perusing', 'Philosophising',
    'Photosynthesizing', 'Pollinating', 'Pondering', 'Pontificating',
    'Pouncing', 'Precipitating', 'Prestidigitating', 'Processing', 'Proofing',
    'Propagating', 'Puttering', 'Puzzling', 'Quantumizing', 'Razzle-dazzling',
    'Razzmatazzing', 'Recombobulating', 'Reticulating', 'Roosting',
    'Ruminating', 'Sautéing', 'Scampering', 'Schlepping', 'Scurrying',
    'Seasoning', 'Shenaniganing', 'Shimmying', 'Simmering', 'Skedaddling',
    'Sketching', 'Slithering', 'Smooshing', 'Sock-hopping', 'Spelunking',
    'Spinning', 'Sprouting', 'Stewing', 'Sublimating', 'Swirling', 'Swooping',
    'Symbioting', 'Synthesizing', 'Tempering', 'Thinking', 'Thundering',
    'Tinkering', 'Tomfoolering', 'Topsy-turvying', 'Transfiguring',
    'Transmuting', 'Twisting', 'Undulating', 'Unfurling', 'Unravelling',
    'Vibing', 'Waddling', 'Wandering', 'Warping', 'Whatchamacalliting',
    'Whirlpooling', 'Whirring', 'Whisking', 'Wibbling', 'Working',
    'Wrangling', 'Zesting', 'Zigzagging',
  ];

  // Film presets
  String _selectedPreset = 'NONE';

  // Grain
  bool _grainEnabled = false;
  double _grainIntensity = 40.0;

  // Light leak
  bool _lightLeakEnabled = false;
  double _lightLeakIntensity = 30.0;
  String _lightLeakStyle = 'WARM';

  @override
  void initState() {
    super.initState();
    // Schedule initial filter application after first frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initFilter();
    });
  }

  /// Initialize: apply default filter to the loaded photo.
  void _initFilter() {
    final imageService = context.read<ImageService>();
    final original = imageService.originalPhoto ?? imageService.currentPhoto;
    if (original == null) return;
    _originalSource = original;
    _applyFilter(_selectedPreset);
  }

  @override
  Widget build(BuildContext context) {
    final imageService = context.watch<ImageService>();

    // Detect when a NEW photo is loaded (different from our source).
    // Only reset when originalPhoto actually changes identity.
    final newOriginal = imageService.originalPhoto;
    if (newOriginal != null && !identical(newOriginal, _originalSource)) {
      _originalSource = newOriginal;
      _displayImage = null;
      _baseFilteredImage = null;
      // Apply filter in next frame to avoid calling setState during build
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _applyFilter(_selectedPreset);
      });
    }

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

    // Choose which image to display
    final displayBytes = _getDisplayBytes(imageService);

    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      body: SafeArea(
        child: Column(
          children: [
            // ── Top Bar ──
            _buildTopBar(imageService),

            // ── Image Preview Area ──
            _buildPreviewArea(imageService, displayBytes),

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

  /// Choose which image bytes to show in the preview.
  Uint8List? _getDisplayBytes(ImageService imageService) {
    if (_showBefore) {
      // BEFORE: show original unfiltered photo
      return imageService.originalPhoto ?? imageService.currentPhoto;
    }
    if (_displayImage != null) {
      // AFTER with effects applied
      return _displayImage;
    }
    // No filter applied yet, show original
    return imageService.originalPhoto ?? imageService.currentPhoto;
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
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white70, size: 22),
            onPressed: () => Navigator.pop(context),
            tooltip: '返回',
          ),
          const Spacer(),
          IconButton(
            icon: Icon(Icons.save_alt, color: Colors.white.withValues(alpha: 0.7), size: 22),
            onPressed: (imageService.currentPhoto != null && !_isSaving) ? _onSaveFiltered : null,
            tooltip: '保存',
          ),
          IconButton(
            icon: Icon(Icons.folder_outlined, color: Colors.white.withValues(alpha: 0.7), size: 22),
            onPressed: _onOpenAlbum,
            tooltip: '相册',
          ),
        ],
      ),
    );
  }

  Widget _buildPreviewArea(ImageService imageService, Uint8List? displayBytes) {
    final previewWidth = MediaQuery.of(context).size.width - 32; // horizontal margin
    final indicatorSize = previewWidth / 3;

    return Container(
      height: MediaQuery.of(context).size.height * 0.42,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1E),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Stack(
        children: [
          if (displayBytes != null)
            Positioned.fill(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(7),
                child: Image.memory(
                  displayBytes,
                  key: ValueKey(displayBytes.length), // force rebuild when content changes
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
          if (_displayImage != null)
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

          // ── Saving progress overlay ──
          if (_isSaving)
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Center(
                  child: SizedBox(
                    width: indicatorSize,
                    height: indicatorSize,
                    child: const CircularProgressIndicator(
                      strokeWidth: 3,
                      valueColor: AlwaysStoppedAnimation<Color>(Color(0xFFD89A0F)),
                    ),
                  ),
                ),
              ),
            ),

          // ── Claude-style reasoning spinner (bottom-left) ──
          if (_showSpinner)
            Positioned(
              bottom: 10,
              left: 10,
              child: _buildSpinnerLabel(),
            ),
        ],
      ),
    );
  }

  Widget _buildSpinnerLabel() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 12, height: 12,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              valueColor: AlwaysStoppedAnimation<Color>(Color(0xFFD89A0F)),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _spinnerVerbs[_spinnerIndex],
            style: const TextStyle(
              color: Color(0xFFD89A0F),
              fontSize: 12,
              fontWeight: FontWeight.w500,
              fontStyle: FontStyle.italic,
            ),
          ),
          const Text(
            '…',
            style: TextStyle(color: Color(0xFFD89A0F), fontSize: 12),
          ),
        ],
      ),
    );
  }

  void _onOpenAlbum() async {
    // 跳转相册浏览页（iOS 相册风格），而不是直接加载第一张照片。
    // EFFECTS 页本身不持有 live view，直接 push 即可。
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const GalleryScreen()),
    );
  }

  void _onSaveFiltered() async {
    final imageService = context.read<ImageService>();
    // Use full-resolution output with effects applied
    final output = _getFullResOutput() ?? _displayImage ?? imageService.currentPhoto;
    if (output == null) return;

    setState(() => _isSaving = true);

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
          content: Text('已保存 $_selectedPreset'),
          backgroundColor: const Color(0xFF2E7D32),
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败: $e'), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  void _onTabChanged(String tab) {
    if (tab == 'BORDERS') {
      // Share the filtered result with BORDERS before navigating
      if (_displayImage != null) {
        context.read<ImageService>().updateCurrentPhoto(_displayImage!);
      }
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

  /// Apply a named filter preset to the original photo.
  void _applyFilter(String preset) {
    // Always use original photo as source (never a previously filtered result)
    final source = _originalSource;
    if (source == null) {
      debugPrint('[Effects] _applyFilter: no original source');
      return;
    }

    setState(() {
      _selectedPreset = preset;
      _showBefore = false;
    });

    // NONE = no filter, use original directly
    if (preset == 'NONE') {
      _baseFilteredImage = source;
      _applyPostEffects();
      return;
    }

    _startSpinner();
    debugPrint('[Effects] applying filter: $preset on ${source.length} bytes');

    // Force minimum spinner display time so user can see it
    final spinnerStart = DateTime.now();

    // Process neural inference in background
    FilterProcessor.apply(source, preset).then((filtered) {
      if (!mounted) return;
      // Ensure spinner shows for at least 600ms
      final elapsed = DateTime.now().difference(spinnerStart).inMilliseconds;
      final delay = elapsed < 600 ? 600 - elapsed : 0;
      Future.delayed(Duration(milliseconds: delay), () {
        if (!mounted) return;
        _stopSpinner();
      });
      debugPrint('[Effects] filter result: ${filtered.length} bytes');
      _baseFilteredImage = filtered;
      _applyPostEffects();
    }).catchError((e) {
      _stopSpinner();
      debugPrint('[Effects] filter error: $e');
    });
  }

  /// Apply grain and light leak post-processing on top of [_baseFilteredImage].
  /// Uses a downsampled preview for fast interactive feedback.
  void _applyPostEffects() {
    _postEffectTimer?.cancel();
    _postEffectTimer = Timer(const Duration(milliseconds: 150), () {
      _applyPostEffectsNow();
    });
  }

  void _applyPostEffectsNow() async {
    final base = _baseFilteredImage;
    if (base == null || _isProcessing) return;

    final grainI = _grainEnabled ? _grainIntensity : 0.0;
    final leakRange = _lightLeakEnabled ? _lightLeakIntensity : 0.0;
    final leakI = leakRange > 0 ? (40.0 + leakRange * 0.6) : 0.0;

    setState(() => _isProcessing = true);

    try {
      // Downsample for fast preview processing (~1000px max)
      final preview = FilterProcessor.downsampleForPreview(base, maxDim: 1000);
      final result = FilterProcessor.applyPostEffects(
        preview,
        grainIntensity: grainI,
        lightLeakIntensity: leakI,
        lightLeakRange: leakRange,
        lightLeakStyle: _lightLeakStyle,
      );

      if (!mounted) return;

      setState(() {
        _displayImage = result;
        _isProcessing = false;
      });

      // Share with BORDERS (downsampled preview is fine for borders UI)
      context.read<ImageService>().updateCurrentPhoto(result);
    } catch (e) {
      debugPrint('[Effects] post-effects error: $e');
      if (!mounted) return;
      setState(() {
        _displayImage = base;
        _isProcessing = false;
      });
    }
  }

  /// Get full-resolution image with effects applied (for saving).
  Uint8List? _getFullResOutput() {
    final base = _baseFilteredImage;
    if (base == null) return null;

    final grainI = _grainEnabled ? _grainIntensity : 0.0;
    final leakRange = _lightLeakEnabled ? _lightLeakIntensity : 0.0;
    final leakI = leakRange > 0 ? (40.0 + leakRange * 0.6) : 0.0;

    if (grainI <= 0 && leakI <= 0) return base;

    return FilterProcessor.applyPostEffects(
      base,
      grainIntensity: grainI,
      lightLeakIntensity: leakI,
      lightLeakRange: leakRange,
      lightLeakStyle: _lightLeakStyle,
    );
  }

  void _startSpinner() {
    _spinnerTimer?.cancel();
    _spinnerIndex = 0;
    _showSpinner = true;
    _spinnerTimer = Timer.periodic(const Duration(milliseconds: 2000), (t) {
      if (!mounted) { t.cancel(); return; }
      setState(() => _spinnerIndex = (_spinnerIndex + 1) % _spinnerVerbs.length);
    });
  }

  void _stopSpinner() {
    _spinnerTimer?.cancel();
    if (mounted) {
      setState(() => _showSpinner = false);
    }
  }

  @override
  void dispose() {
    _postEffectTimer?.cancel();
    _spinnerTimer?.cancel();
    super.dispose();
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
