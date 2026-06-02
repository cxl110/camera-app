import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/filter_service.dart';
import '../widgets/film_strip.dart';
import '../widgets/viewfinder_overlay.dart';
import '../widgets/shutter_button.dart';
import '../widgets/top_toolbar.dart';
import '../widgets/quick_filter_strip.dart';
import 'camera_connect_screen.dart';

/// Kontax-Cam inspired main camera screen.
///
/// Layout:
/// ┌──────────────────────────┐
/// │  [flash] [📸] [⚙️] [⟳]  │  ← Top toolbar
/// ├──────────────────────────┤
/// │                          │
/// │     Viewfinder           │
/// │  (camera live preview)   │  ← Central camera view
/// │    with grid overlay     │
/// │                          │
/// │  [brand pill]            │
/// ├──────────────────────────┤
/// │  ┌──┐ ┌──┐ ┌──┐ ┌──┐   │
/// │  │AC│ │CC│ │ET│ │CN│   │  ← Film strip filter picker
/// │  └──┘ └──┘ └──┘ └──┘   │
/// │        ⚪ SHUTTER        │  ← Large shutter button
/// └──────────────────────────┘
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _shimmerCtrl;

  // Simulated camera states
  bool _hasFlash = false;
  bool _showGrid = true;
  String _selectedFilm = 'CLASSIC CHROME';

  @override
  void initState() {
    super.initState();
    _shimmerCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
  }

  @override
  void dispose() {
    _shimmerCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF08080A),
      body: SafeArea(
        child: Stack(
          children: [
            // ── Viewfinder Area ──
            const ViewfinderOverlay(showGrid: true),

            // ── Top Toolbar ──
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: TopToolbar(
                hasFlash: _hasFlash,
                onFlashToggle: () => setState(() => _hasFlash = !_hasFlash),
                onGridToggle: () => setState(() => _showGrid = !_showGrid),
              ),
            ),

            // ── Quick Filter Strip (right side) ──
            const Positioned(
              right: 8,
              top: 120,
              bottom: 280,
              child: QuickFilterStrip(),
            ),

            // ── Selected Film Brand Pill ──
            Positioned(
              left: 20,
              bottom: 240,
              child: _FilmBrandPill(brand: _selectedFilm),
            ),

            // ── Bottom Sheet: Film Strip + Shutter ──
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _BottomDock(
                selectedFilm: _selectedFilm,
                onFilmSelected: (film) => setState(() => _selectedFilm = film),
                onShutterPressed: _onShutterPress,
                onConnectPress: _onConnectPress,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _onShutterPress() {
    // Haptic-like flash animation would go here
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('📸 拍摄中 — $_selectedFilm'),
        duration: const Duration(milliseconds: 800),
        backgroundColor: const Color(0xFF1A1A2E),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.only(bottom: 280, left: 60, right: 60),
      ),
    );
  }

  void _onConnectPress() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const CameraConnectScreen()),
    );
  }
}

/// Floating film brand indicator pill.
class _FilmBrandPill extends StatelessWidget {
  final String brand;
  const _FilmBrandPill({required this.brand});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.6),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withOpacity(0.15)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.4),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: const BoxDecoration(
              color: Color(0xFFFF6B35),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            brand,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w600,
              letterSpacing: 2,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }
}

/// Bottom dock containing film strip carousel and shutter button.
class _BottomDock extends StatelessWidget {
  final String selectedFilm;
  final ValueChanged<String> onFilmSelected;
  final VoidCallback onShutterPressed;
  final VoidCallback onConnectPress;

  const _BottomDock({
    required this.selectedFilm,
    required this.onFilmSelected,
    required this.onShutterPressed,
    required this.onConnectPress,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 260,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            const Color(0xFF08080A).withOpacity(0),
            const Color(0xFF08080A).withOpacity(0.8),
            const Color(0xFF08080A),
          ],
        ),
      ),
      child: Column(
        children: [
          // Film strip row
          SizedBox(
            height: 120,
            child: Consumer<FilterService>(
              builder: (context, filterService, _) {
                return FilmStrip(
                  filters: filterService.filters,
                  selectedId: selectedFilm,
                  onSelected: (filter) {
                    filterService.selectFilter(filter.id);
                    onFilmSelected(filter.name);
                  },
                );
              },
            ),
          ),

          // Shutter + Connect row
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // WiFi connect button
                GestureDetector(
                  onTap: onConnectPress,
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.1),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.wifi,
                      color: Colors.white38,
                      size: 20,
                    ),
                  ),
                ),

                // Shutter button
                ShutterButton(onTap: onShutterPressed),

                // Gallery button
                GestureDetector(
                  onTap: () {
                    // TODO: Open gallery
                  },
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.white.withOpacity(0.2)),
                      color: Colors.white.withOpacity(0.05),
                    ),
                    child: const Icon(
                      Icons.photo_library_outlined,
                      color: Colors.white38,
                      size: 20,
                    ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
