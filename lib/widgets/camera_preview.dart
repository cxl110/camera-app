import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';

/// Camera live preview or disconnected placeholder.
///
/// Connected with stream: Renders MJPEG frames via StreamBuilder (only
/// rebuilds the image widget, not the parent tree).
/// Disconnected: Black background with a simple camera icon in white outline.
class CameraPreview extends StatelessWidget {
  final bool isConnected;
  final Widget? liveView;
  final Stream<Uint8List>? frameStream;

  const CameraPreview({
    super.key,
    this.isConnected = false,
    this.liveView,
    this.frameStream,
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
      return liveView!;
    }

    // Use MJPEG frame stream — only rebuilds the image, not the parent
    if (frameStream != null) {
      return StreamBuilder<Uint8List>(
        stream: frameStream,
        builder: (ctx, snapshot) {
          if (snapshot.hasData && snapshot.data != null) {
            return Image.memory(
              snapshot.data!,
              fit: BoxFit.contain,
              gaplessPlayback: true, // smooth frame transitions
            );
          }
          return _buildConnectedPlaceholder();
        },
      );
    }

    return _buildConnectedPlaceholder();
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
            '实时取景',
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
            '相机未连接',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.3),
              fontSize: 14,
              fontWeight: FontWeight.w300,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '请连接相机WiFi开始拍摄',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.15),
              fontSize: 12,
            ),
          ),
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
      ..color = Colors.white.withValues(alpha: 0.25)
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
