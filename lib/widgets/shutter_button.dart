import 'package:flutter/material.dart';

/// Animated shutter button inspired by classic film cameras.
///
/// Features a large outer ring with inner button, and a subtle
/// pulse animation to suggest "ready to shoot."
class ShutterButton extends StatefulWidget {
  final VoidCallback onTap;

  const ShutterButton({
    super.key,
    required this.onTap,
  });

  @override
  State<ShutterButton> createState() => _ShutterButtonState();
}

class _ShutterButtonState extends State<ShutterButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseCtrl;
  bool _isPressed = false;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _isPressed = true),
      onTapUp: (_) {
        setState(() => _isPressed = false);
        widget.onTap();
      },
      onTapCancel: () => setState(() => _isPressed = false),
      child: AnimatedBuilder(
        animation: _pulseCtrl,
        builder: (context, child) {
          final pulseScale = 1.0 + _pulseCtrl.value * 0.03;
          final currentScale = _isPressed ? 0.9 : pulseScale;

          return Transform.scale(
            scale: currentScale,
            child: Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                // Outer ring
                border: Border.all(
                  color: Colors.white.withOpacity(0.6),
                  width: 4,
                ),
                // Inner shadow for depth
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFFFF6B35).withOpacity(
                      0.15 + _pulseCtrl.value * 0.1,
                    ),
                    blurRadius: 20,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: Center(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  width: _isPressed ? 56 : 60,
                  height: _isPressed ? 56 : 60,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _isPressed
                        ? const Color(0xFFFF6B35).withOpacity(0.4)
                        : const Color(0xFFFF6B35).withOpacity(0.25),
                    border: Border.all(
                      color: _isPressed
                          ? const Color(0xFFFF6B35)
                          : Colors.white.withOpacity(0.3),
                      width: 2,
                    ),
                  ),
                  child: _isPressed
                      ? const Icon(Icons.circle, color: Colors.white, size: 12)
                      : null,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
