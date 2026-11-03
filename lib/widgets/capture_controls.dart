import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';

/// Capture control buttons below the viewfinder.
///
/// Layout: [Thumbnail] 鈹€鈹€ [Shutter 鈼媇 鈹€鈹€ [Timer 馃晲]
///
/// - Left: last captured photo thumbnail
/// - Center: white circle shutter button
/// - Right: timer shutter button (5s countdown)
///
/// The camera's capture-sound switch lives in the top bar (see
/// [SoundToggleIcon]) 鈥?it used to sit here, where a fixed 72pt side slot could
/// not hold both it and the timer and the button was pushed off screen.
///
/// Both sides are [Expanded] so they always get the same width and the shutter
/// stays optically centred.
class CaptureControls extends StatefulWidget {
  final Uint8List? lastPhoto;
  final VoidCallback onShutter;
  final bool enabled;

  const CaptureControls({
    super.key,
    this.lastPhoto,
    required this.onShutter,
    this.enabled = true,
  });

  @override
  State<CaptureControls> createState() => _CaptureControlsState();
}

class _CaptureControlsState extends State<CaptureControls> {
  int? _countdown; // null = not counting, 5..1 = counting down
  Timer? _timer;

  void _startTimer() {
    if (!widget.enabled || _countdown != null) return;
    setState(() => _countdown = 5);
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      if (_countdown! > 1) {
        setState(() => _countdown = _countdown! - 1);
      } else {
        t.cancel();
        setState(() => _countdown = null);
        widget.onShutter();
      }
    });
  }

  void _cancelTimer() {
    _timer?.cancel();
    _timer = null;
    if (_countdown != null) {
      setState(() => _countdown = null);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 80,
      // 24pt side padding: on a 320pt-wide phone the two Expanded side slots
      // get ~108pt each, which comfortably holds thumbnail (44) + gap + sound
      // switch (50) on the left and the timer (54 while counting) on the right.
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: const BoxDecoration(
        color: Color(0xFF0A0A0A),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // 鈹€鈹€ Left: Thumbnail 鈹€鈹€
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.start,
              children: [
                _ThumbnailButton(image: widget.lastPhoto),
              ],
            ),
          ),

          // 鈹€鈹€ Center: Shutter 鈹€鈹€
          _ShutterButton(onTap: widget.onShutter, enabled: widget.enabled),

          // 鈹€鈹€ Right: Timer shutter 鈹€鈹€
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                _TimerButton(
                  onTap: _startTimer,
                  onCancel: _cancelTimer,
                  countdown: _countdown,
                  enabled: widget.enabled,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Last captured photo thumbnail.
class _ThumbnailButton extends StatelessWidget {
  final Uint8List? image;

  const _ThumbnailButton({this.image});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.white.withOpacity(0.2)),
        color: Colors.white.withOpacity(0.05),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(5),
        child: image != null
            ? Image.memory(image!, fit: BoxFit.cover)
            : Icon(
                Icons.photo_outlined,
                size: 20,
                color: Colors.white.withOpacity(0.2),
              ),
      ),
    );
  }
}

/// White circular shutter button.
class _ShutterButton extends StatefulWidget {
  final VoidCallback onTap;
  final bool enabled;

  const _ShutterButton({required this.onTap, this.enabled = true});

  @override
  State<_ShutterButton> createState() => _ShutterButtonState();
}

class _ShutterButtonState extends State<_ShutterButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled;
    return GestureDetector(
      onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
      onTapUp: enabled
          ? (_) {
              setState(() => _pressed = false);
              widget.onTap();
            }
          : null,
      onTapCancel: enabled ? () => setState(() => _pressed = false) : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 100),
        width: 64,
        height: 64,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: enabled ? Colors.white : const Color(0xFF555555),
          boxShadow: _pressed
              ? []
              : [
                  BoxShadow(
                    color: Colors.white.withOpacity(enabled ? 0.3 : 0.05),
                    blurRadius: 12,
                    spreadRadius: 1,
                  ),
                ],
        ),
        child: Center(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            width: _pressed ? 52 : 56,
            height: _pressed ? 52 : 56,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: enabled ? const Color(0xFF333333) : const Color(0xFF666666),
                width: 3,
              ),
              color: enabled ? Colors.white : const Color(0xFF555555),
            ),
          ),
        ),
      ),
    );
  }
}

/// Timer shutter button 鈥?5s countdown then captures.
///
/// Slightly smaller than the main shutter. Shows countdown number when active.
/// Long press during countdown to cancel.
class _TimerButton extends StatefulWidget {
  final VoidCallback onTap;
  final VoidCallback onCancel;
  final int? countdown;
  final bool enabled;

  const _TimerButton({
    required this.onTap,
    required this.onCancel,
    this.countdown,
    this.enabled = true,
  });

  @override
  State<_TimerButton> createState() => _TimerButtonState();
}

class _TimerButtonState extends State<_TimerButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled;
    final counting = widget.countdown != null;

    return GestureDetector(
      onTapDown: (enabled && !counting)
          ? (_) => setState(() => _pressed = true)
          : null,
      onTapUp: (enabled && !counting)
          ? (_) {
              setState(() => _pressed = false);
              widget.onTap();
            }
          : null,
      onTapCancel: () => setState(() => _pressed = false),
      // Tap during countdown to cancel
      onTap: counting ? widget.onCancel : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: counting ? 54 : 50,
        height: counting ? 54 : 50,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: counting
              ? const Color(0xFFD89A0F)
              : (enabled
                  ? Colors.white.withOpacity(0.85)
                  : const Color(0xFF444444)),
          boxShadow: _pressed
              ? []
              : [
                  BoxShadow(
                    color: (counting
                            ? const Color(0xFFD89A0F)
                            : Colors.white)
                        .withOpacity(enabled ? 0.2 : 0.03),
                    blurRadius: 8,
                    spreadRadius: 0.5,
                  ),
                ],
        ),
        child: Center(
          child: counting
              ? Text(
                  '${widget.countdown}',
                  style: const TextStyle(
                    color: Colors.black,
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                  ),
                )
              : Icon(
                  Icons.timer,
                  size: 22,
                  color: enabled
                      ? const Color(0xFF333333)
                      : const Color(0xFF666666),
                ),
        ),
      ),
    );
  }
}
