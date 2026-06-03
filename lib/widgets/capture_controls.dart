import 'dart:typed_data';
import 'package:flutter/material.dart';

/// Three capture control buttons below the viewfinder.
///
/// Layout: [Thumbnail] ── [Shutter ○] ── [Record ●]
///
/// - Left: Last captured photo thumbnail (small square)
/// - Center: White circle shutter button
/// - Right: Red circle record button
class CaptureControls extends StatelessWidget {
  final Uint8List? lastPhoto;
  final VoidCallback onShutter;
  final VoidCallback onRecord;
  final bool isRecording;

  const CaptureControls({
    super.key,
    this.lastPhoto,
    required this.onShutter,
    required this.onRecord,
    this.isRecording = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 80,
      padding: const EdgeInsets.symmetric(horizontal: 32),
      decoration: const BoxDecoration(
        color: Color(0xFF0A0A0A),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // ── Left: Thumbnail ──
          _ThumbnailButton(image: lastPhoto),

          // ── Center: Shutter ──
          _ShutterButton(onTap: onShutter),

          // ── Right: Record ──
          _RecordButton(
            onTap: onRecord,
            isRecording: isRecording,
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
        border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
        color: Colors.white.withValues(alpha: 0.05),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(5),
        child: image != null
            ? Image.memory(image!, fit: BoxFit.cover)
            : Icon(
                Icons.photo_outlined,
                size: 20,
                color: Colors.white.withValues(alpha: 0.2),
              ),
      ),
    );
  }
}

/// White circular shutter button.
class _ShutterButton extends StatefulWidget {
  final VoidCallback onTap;

  const _ShutterButton({required this.onTap});

  @override
  State<_ShutterButton> createState() => _ShutterButtonState();
}

class _ShutterButtonState extends State<_ShutterButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) {
        setState(() => _pressed = false);
        widget.onTap();
      },
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 100),
        width: 64,
        height: 64,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white,
          boxShadow: _pressed
              ? []
              : [
                  BoxShadow(
                    color: Colors.white.withValues(alpha: 0.3),
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
                color: const Color(0xFF333333),
                width: 3,
              ),
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}

/// Red circular record button.
class _RecordButton extends StatefulWidget {
  final VoidCallback onTap;
  final bool isRecording;

  const _RecordButton({
    required this.onTap,
    this.isRecording = false,
  });

  @override
  State<_RecordButton> createState() => _RecordButtonState();
}

class _RecordButtonState extends State<_RecordButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final bool active = widget.isRecording || _pressed;

    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) {
        setState(() => _pressed = false);
        widget.onTap();
      },
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 100),
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: active
              ? const Color(0xFFD32F2F)
              : const Color(0xFFC62828),
          boxShadow: active
              ? [
                  BoxShadow(
                    color: const Color(0xFFC62828).withValues(alpha: 0.5),
                    blurRadius: 8,
                  )
                ]
              : [],
        ),
        child: Center(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: widget.isRecording ? 18 : 40,
            height: widget.isRecording ? 18 : 40,
            decoration: BoxDecoration(
              shape: widget.isRecording ? BoxShape.rectangle : BoxShape.circle,
              borderRadius: widget.isRecording
                  ? BorderRadius.circular(3)
                  : null,
              border: Border.all(color: Colors.white, width: 2),
              color: widget.isRecording
                  ? Colors.white
                  : Colors.transparent,
            ),
          ),
        ),
      ),
    );
  }
}
