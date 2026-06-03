import 'package:flutter/material.dart';

/// WiFi signal indicator for camera connection status.
///
/// Connected: Full green bars
/// Disconnected: Single red bar
class WifiIndicator extends StatelessWidget {
  final bool isConnected;

  const WifiIndicator({
    super.key,
    this.isConnected = false,
  });

  @override
  Widget build(BuildContext context) {
    final Color color = isConnected
        ? const Color(0xFF4CAF50) // Green when connected
        : const Color(0xFFF44336); // Red when disconnected

    final double opacity1 = isConnected ? 0.3 : 1.0;
    final double opacity2 = isConnected ? 0.6 : 0.0;
    final double opacity3 = isConnected ? 1.0 : 0.0;

    return SizedBox(
      width: 22,
      height: 18,
      child: CustomPaint(
        painter: _WifiPainter(
          color: color,
          opacity1: opacity1,
          opacity2: opacity2,
          opacity3: opacity3,
        ),
      ),
    );
  }
}

class _WifiPainter extends CustomPainter {
  final Color color;
  final double opacity1;
  final double opacity2;
  final double opacity3;

  _WifiPainter({
    required this.color,
    required this.opacity1,
    required this.opacity2,
    required this.opacity3,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round;

    final dotPaint = Paint()
      ..style = PaintingStyle.fill;

    final centerX = size.width / 2;
    final bottomY = size.height;

    // Dot at bottom
    dotPaint.color = Colors.white.withValues(alpha: 0.9);
    canvas.drawCircle(Offset(centerX, bottomY - 2), 2.5, dotPaint);

    // Arc 1 (smallest, top)
    if (opacity1 > 0) {
      paint.color = color.withValues(alpha: opacity1);
      _drawArc(canvas, size, paint, 0.35, -0.8);
    }

    // Arc 2 (medium)
    if (opacity2 > 0) {
      paint.color = color.withValues(alpha: opacity2);
      _drawArc(canvas, size, paint, 0.55, -0.85);
    }

    // Arc 3 (largest, bottom)
    if (opacity3 > 0) {
      paint.color = color.withValues(alpha: opacity3);
      _drawArc(canvas, size, paint, 0.75, -0.9);
    }
  }

  void _drawArc(Canvas canvas, Size size, Paint paint, double radius, double angle) {
    final rect = Rect.fromCircle(
      center: Offset(size.width / 2, size.height * 0.65),
      radius: size.width * radius,
    );
    canvas.drawArc(rect, -1.8, angle, false, paint);
  }

  @override
  bool shouldRepaint(covariant _WifiPainter old) =>
      color != old.color || opacity1 != old.opacity1;
}
