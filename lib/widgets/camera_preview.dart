import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../services/image_mirror.dart';

/// Camera live preview or disconnected placeholder.
///
/// Connected with stream: Renders MJPEG frames via StreamBuilder (only
/// rebuilds the image widget, not the parent tree).
/// Disconnected: Black background with a simple camera icon in white outline,
/// plus an optional entry into trial mode (see [onTryWithoutCamera]) so the
/// photo-editing features are reachable without the hardware.
class CameraPreview extends StatelessWidget {
  final bool isConnected;
  final Widget? liveView;
  final Stream<Uint8List>? frameStream;

  /// Shown under the "disconnected" hint. Null hides the button (e.g. while
  /// the app is still verifying the connection).
  final VoidCallback? onTryWithoutCamera;

  const CameraPreview({
    super.key,
    this.isConnected = false,
    this.liveView,
    this.frameStream,
    this.onTryWithoutCamera,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: isConnected ? Colors.black : const Color(0xFF000000),
      child: _buildContent(),
    );
  }

  Widget _buildContent() {
    if (!isConnected) {
      return _buildDisconnectedPlaceholder();
    }

    // Use injected liveView widget if provided (takes priority)
    if (liveView != null) {
      return _mirrored(liveView!);
    }

    // Use MJPEG frame stream — only rebuilds the image, not the parent
    if (frameStream != null) {
      return StreamBuilder<Uint8List>(
        stream: frameStream,
        builder: (ctx, snapshot) {
          if (snapshot.hasData && snapshot.data != null) {
            return _mirrored(Image.memory(
              snapshot.data!,
              fit: BoxFit.contain,
              gaplessPlayback: true, // smooth frame transitions
            ));
          }
          return _buildConnectedPlaceholder();
        },
      );
    }

    return _buildConnectedPlaceholder();
  }

  /// Mirror live-view frames horizontally.
  ///
  /// The sensor is mounted mirrored and firmware cannot correct it. Photos and
  /// thumbnails are flipped in software at download time (see
  /// `services/image_mirror.dart`), but the live stream runs at several frames a
  /// second — decoding and re-encoding every frame would burn the battery for
  /// nothing, so the preview is mirrored by the compositor instead. This is the
  /// only place a render-time flip is correct.
  Widget _mirrored(Widget child) {
    if (!kMirrorLiveStream) return child;
    return Transform(
      alignment: Alignment.center,
      transform: Matrix4.identity()..scale(-1.0, 1.0, 1.0),
      child: child,
    );
  }

  /// Placeholder when camera is connected but no live feed available.
  Widget _buildConnectedPlaceholder() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.camera, size: 48, color: Colors.white38),
          SizedBox(height: 8),
          Text(
            'Live View',
            style: TextStyle(color: Colors.white38, fontSize: 13),
          ),
        ],
      ),
    );
  }

  /// Camera icon when disconnected.
  Widget _buildDisconnectedPlaceholder() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CustomPaint(
            size: const Size(64, 48),
            painter: _CameraOutlinePainter(),
          ),
          const SizedBox(height: 24),
          Text(
            'Camera Disconnected',
            style: TextStyle(
              color: Colors.white.withOpacity(0.3),
              fontSize: 14,
              fontWeight: FontWeight.w300,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Connect to camera WiFi to start',
            style: TextStyle(
              color: Colors.white.withOpacity(0.15),
              fontSize: 12,
            ),
          ),
          if (onTryWithoutCamera != null) ...[
            const SizedBox(height: 32),
            OutlinedButton.icon(
              onPressed: onTryWithoutCamera,
              icon: const Icon(Icons.auto_awesome_outlined, size: 18),
              label: const Text('Try without a camera'),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFFD89A0F),
                side: const BorderSide(color: Color(0xFF4A3A10)),
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Apply film filters to any photo',
              style: TextStyle(
                color: Colors.white.withOpacity(0.2),
                fontSize: 11,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Simple camera outline icon painter.
class _CameraOutlinePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withOpacity(0.25)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    final w = size.width;
    final h = size.height;

    final bodyRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(4, h * 0.25, w * 0.85, h * 0.7),
      const Radius.circular(6),
    );
    canvas.drawRRect(bodyRect, paint);

    final lensCenter = Offset(w * 0.45, h * 0.58);
    canvas.drawCircle(lensCenter, w * 0.16, paint);
    canvas.drawCircle(lensCenter, w * 0.07, paint);

    final path = Path()
      ..moveTo(w * 0.60, h * 0.25)
      ..lineTo(w * 0.60, h * 0.1)
      ..lineTo(w * 0.78, h * 0.1)
      ..lineTo(w * 0.78, h * 0.25);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
