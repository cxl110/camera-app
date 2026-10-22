import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';

/// Capture control buttons below the viewfinder.
///
/// Layout: [Thumbnail] ── [Shutter ○] ── [Timer 🕐 | Sound 🔊]
///
/// - Left: Last captured photo thumbnail
/// - Center: White circle shutter button
/// - Right: Timer shutter button (5s countdown, slightly smaller) and the
///   camera capture-sound switch (API v1.6 `/sound`)
class CaptureControls extends StatefulWidget {
  final Uint8List? lastPhoto;
  final VoidCallback onShutter;
  final bool enabled;

  /// Capture-sound switch state on the camera: `null` = unknown / unsupported
  /// (button shown dimmed and disabled).
  final bool? soundEnabled;

  /// A sound request is in flight — show a spinner and ignore taps.
  final bool soundBusy;

  /// Called when the user taps the sound button.
  final VoidCallback? onToggleSound;

  /// Whether the camera is reachable — used only to explain a disabled sound
  /// button (disconnected vs. old firmware).
  final bool cameraConnected;

  /// The camera refused our access token (HTTP 403) — a third reason the
  /// button can be dead, and the one the user can actually act on.
  final bool authRejected;

  const CaptureControls({
    super.key,
    this.lastPhoto,
    required this.onShutter,
    this.enabled = true,
    this.soundEnabled,
    this.soundBusy = false,
    this.onToggleSound,
    this.cameraConnected = false,
    this.authRejected = false,
  });

  @override
  State<CaptureControls> createState() => _CaptureControlsState();
}

class _CaptureControlsState extends State<CaptureControls> {
  int? _countdown; // null = not counting, 5..1 = counting down
  Timer? _timer;

  /// Fixed width of the leading/trailing groups, so the shutter stays centered
  /// even though the trailing group holds two buttons (timer + sound).
  static const double _sideWidth = 72;

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
      // 24 (not 32) so the trailing timer + sound pair still fits on narrow
      // phones (e.g. iPhone SE, 320pt wide).
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: const BoxDecoration(
        color: Color(0xFF0A0A0A),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // ── Left: Thumbnail ──
          SizedBox(
            width: _sideWidth,
            child: Align(
              alignment: Alignment.centerLeft,
              child: _ThumbnailButton(image: widget.lastPhoto),
            ),
          ),

          // ── Center: Shutter ──
          _ShutterButton(onTap: widget.onShutter, enabled: widget.enabled),

          // ── Right: Timer shutter + sound switch ──
          SizedBox(
            width: _sideWidth,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                _TimerButton(
                  onTap: _startTimer,
                  onCancel: _cancelTimer,
                  countdown: _countdown,
                  enabled: widget.enabled,
                ),
                const SizedBox(width: 12),
                _SoundButton(
                  enabled: widget.soundEnabled,
                  busy: widget.soundBusy,
                  onTap: widget.onToggleSound,
                  cameraConnected: widget.cameraConnected,
                  authRejected: widget.authRejected,
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

/// Timer shutter button — 5s countdown then captures.
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

/// Camera capture-sound switch (API v1.6 `GET/POST /sound`).
///
/// Small circular button next to the timer button. Speaker glyph = sound on,
/// muted speaker = sound off; a small amber dot marks the "on" state. Keep it
/// visually lighter than the timer button so it doesn't compete with it.
class _SoundButton extends StatefulWidget {
  /// null = state unknown / unsupported by this firmware → disabled.
  final bool? enabled;
  final bool busy;
  final VoidCallback? onTap;
  final bool cameraConnected;
  final bool authRejected;

  const _SoundButton({
    this.enabled,
    this.busy = false,
    this.onTap,
    this.cameraConnected = false,
    this.authRejected = false,
  });

  @override
  State<_SoundButton> createState() => _SoundButtonState();
}

class _SoundButtonState extends State<_SoundButton> {
  bool _pressed = false;

  /// Tapping the dimmed button explains why nothing happened instead of
  /// silently ignoring the user.
  void _explainUnavailable() {
    final String msg;
    if (widget.authRejected) {
      msg = 'Camera rejected the access token — recovering, or check the phone date & time';
    } else if (!widget.cameraConnected) {
      msg = 'Connect to the camera to change its capture sound';
    } else {
      msg = 'This camera firmware has no sound switch — update firmware';
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: const Color(0xFFD89A0F),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.only(bottom: 160),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.enabled;
    final known = state != null;
    final on = state ?? false;
    final canTap = known && !widget.busy && widget.onTap != null;

    final Color iconColor;
    if (!known) {
      iconColor = const Color(0xFF555555);
    } else if (on) {
      iconColor = const Color(0xFFD89A0F);
    } else {
      iconColor = const Color(0xFF8A8A8A);
    }

    final Color bgColor = !known
        ? const Color(0xFF2A2A2A)
        : (on
            ? const Color(0xFFD89A0F).withOpacity(0.16)
            : Colors.white.withOpacity(0.06));

    return Tooltip(
      message: !known
          ? (widget.authRejected
              ? 'Capture sound unavailable (token rejected)'
              : (widget.cameraConnected
                  ? 'Capture sound unavailable (old firmware)'
                  : 'Capture sound (camera offline)'))
          : (on ? 'Capture sound: ON' : 'Capture sound: OFF'),
      child: GestureDetector(
        onTapDown: canTap ? (_) => setState(() => _pressed = true) : null,
        onTapUp: canTap
            ? (_) {
                setState(() => _pressed = false);
                widget.onTap!();
              }
            : null,
        onTapCancel: () => setState(() => _pressed = false),
        onTap: canTap
            ? widget.onTap
            : (!widget.busy ? _explainUnavailable : null),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: bgColor,
            border: Border.all(
              color: on
                  ? const Color(0xFFD89A0F).withOpacity(0.6)
                  : Colors.white.withOpacity(known ? 0.14 : 0.06),
            ),
            boxShadow: _pressed
                ? []
                : [
                    BoxShadow(
                      color: Colors.white.withOpacity(known ? 0.06 : 0.02),
                      blurRadius: 6,
                      spreadRadius: 0.5,
                    ),
                  ],
          ),
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              if (widget.busy)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Color(0xFFD89A0F),
                  ),
                )
              else
                Icon(
                  on ? Icons.volume_up : Icons.volume_off,
                  size: 21,
                  color: iconColor,
                ),
              // Amber dot = sound on, mirroring the "active" indicator style
              // used elsewhere (e.g. the OTA badge in the top bar).
              if (on && !widget.busy)
                Positioned(
                  right: 9,
                  top: 9,
                  child: Container(
                    width: 6,
                    height: 6,
                    decoration: const BoxDecoration(
                      color: Color(0xFFD89A0F),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
