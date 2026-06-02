import 'package:flutter/material.dart';

/// Camera viewfinder overlay with rule-of-thirds grid.
///
/// Simulates a camera viewfinder when no live camera is available.
/// On a real device, this would be replaced by a CameraPreview widget.
class ViewfinderOverlay extends StatelessWidget {
  final bool showGrid;

  const ViewfinderOverlay({
    super.key,
    this.showGrid = true,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF0A0A0F),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Simulated dark viewfinder background
          // In production: CameraPreview() widget here
          _buildViewfinder(context),

          // Rule of thirds grid
          if (showGrid) _buildGrid(),

          // Corner brackets (focus area)
          _buildCornerBrackets(),

          // Center focus indicator
          const Center(
            child: _FocusIndicator(),
          ),

          // Exposure metering text
          Positioned(
            bottom: 60,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.4),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text(
                  '400  •  f/5.6  •  ISO 400',
                  style: TextStyle(
                    color: Color(0xFFFF6B35),
                    fontSize: 11,
                    fontFamily: 'monospace',
                    letterSpacing: 1.5,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildViewfinder(BuildContext context) {
    // Simulate a dark camera viewfinder with subtle vignette
    return Container(
      decoration: const BoxDecoration(
        // Vignette effect via radial gradient
        // In production, this is CameraPreview
      ),
      child: CustomPaint(
        painter: _VignettePainter(),
        size: Size.infinite,
      ),
    );
  }

  Widget _buildGrid() {
    return CustomPaint(
      painter: _GridPainter(),
      size: Size.infinite,
    );
  }

  Widget _buildCornerBrackets() {
    return Center(
      child: Container(
        width: 240,
        height: 240,
        decoration: BoxDecoration(
          border: Border.all(
            color: Colors.white.withOpacity(0.2),
            width: 0.5,
          ),
        ),
        child: Stack(
          children: [
            // Top-left corner
            Positioned(
              top: 0,
              left: 0,
              child: _CornerBracket(isTopLeft: true),
            ),
            // Top-right corner
            Positioned(
              top: 0,
              right: 0,
              child: _CornerBracket(isTopLeft: false),
            ),
            // Bottom-left corner
            Positioned(
              bottom: 0,
              left: 0,
              child: _CornerBracket(isTopLeft: true, isBottom: true),
            ),
            // Bottom-right corner
            Positioned(
              bottom: 0,
              right: 0,
              child: _CornerBracket(isTopLeft: false, isBottom: true),
            ),
          ],
        ),
      ),
    );
  }
}

/// Rule of thirds grid lines.
class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withOpacity(0.08)
      ..strokeWidth = 0.5;

    // Vertical thirds
    for (int i = 1; i < 3; i++) {
      final x = size.width * i / 3;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }

    // Horizontal thirds
    for (int i = 1; i < 3; i++) {
      final y = size.height * i / 3;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Dark vignette effect around viewfinder edges.
class _VignettePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final gradient = RadialGradient(
      center: Alignment.center,
      radius: 0.75,
      colors: [
        Colors.transparent,
        Colors.black.withOpacity(0.6),
      ],
    );
    canvas.drawRect(rect, Paint()..shader = gradient.createShader(rect));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// 'L' shaped corner bracket for focus area.
class _CornerBracket extends StatelessWidget {
  final bool isTopLeft;
  final bool isBottom;

  const _CornerBracket({
    required this.isTopLeft,
    this.isBottom = false,
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(20, 20),
      painter: _BracketPainter(
        isTopLeft: isTopLeft,
        isBottom: isBottom,
      ),
    );
  }
}

class _BracketPainter extends CustomPainter {
  final bool isTopLeft;
  final bool isBottom;

  _BracketPainter({
    required this.isTopLeft,
    required this.isBottom,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withOpacity(0.5)
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;

    final path = Path();
    final x = isTopLeft ? 0.0 : size.width;
    final dx = isTopLeft ? 1.0 : -1.0;
    final y = isBottom ? size.height : 0.0;
    final dy = isBottom ? -1.0 : 1.0;

    // Vertical line
    path.moveTo(x, y);
    path.lineTo(x, y + dy * 16);
    path.moveTo(x, y);
    // Horizontal line
    path.lineTo(x - dx * 16, y);

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Animated focus indicator in center of viewfinder.
class _FocusIndicator extends StatefulWidget {
  const _FocusIndicator();

  @override
  State<_FocusIndicator> createState() => _FocusIndicatorState();
}

class _FocusIndicatorState extends State<_FocusIndicator>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, child) {
        return Container(
          width: 40 + _ctrl.value * 4,
          height: 40 + _ctrl.value * 4,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: Colors.white.withOpacity(0.2 + _ctrl.value * 0.3),
              width: 1,
            ),
          ),
        );
      },
    );
  }
}
