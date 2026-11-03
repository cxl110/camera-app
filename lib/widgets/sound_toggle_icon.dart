import 'package:flutter/material.dart';

/// Camera capture-sound switch (API v1.6 `GET/POST /sound`), as a bare glyph.
///
/// Lives in the home screen's top bar, immediately left of the camera-photos
/// folder icon. Deliberately has no circular background: a filled circle next to
/// the flat folder glyph looked heavy and competed with the shutter controls.
///
/// States:
/// - `enabled == null` — camera has no `/sound` endpoint, or we have not read the
///   state yet: drawn dim and tapping explains why.
/// - `enabled == true/false` — sound on/off; amber glyph when on.
/// - [busy] — a request is in flight: spinner instead of the glyph.
class SoundToggleIcon extends StatelessWidget {
  /// null = unknown / unsupported by this firmware.
  final bool? enabled;
  final bool busy;
  final bool cameraConnected;
  final bool authRejected;
  final VoidCallback? onTap;

  const SoundToggleIcon({
    super.key,
    this.enabled,
    this.busy = false,
    this.cameraConnected = false,
    this.authRejected = false,
    this.onTap,
  });

  bool get _known => enabled != null;
  bool get _on => enabled ?? false;
  bool get _canTap => _known && !busy && onTap != null;

  /// Tapping the dim glyph explains why nothing happened instead of silently
  /// ignoring the user.
  void _explain(BuildContext context) {
    final String msg;
    if (authRejected) {
      msg = 'Camera rejected the access token — recovering, or check the phone date & time';
    } else if (!cameraConnected) {
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
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 96),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final String tooltip;
    if (!_known) {
      tooltip = authRejected
          ? 'Capture sound unavailable (token rejected)'
          : (cameraConnected
              ? 'Capture sound unavailable (old firmware)'
              : 'Capture sound (camera offline)');
    } else {
      tooltip = _on ? 'Capture sound: ON' : 'Capture sound: OFF';
    }

    return Tooltip(
      message: tooltip,
      child: InkResponse(
        onTap: () {
          if (busy) return;
          if (_canTap) {
            onTap!();
          } else {
            _explain(context);
          }
        },
        radius: 22,
        containedInkWell: false,
        child: SizedBox(
          width: 40,
          height: 44,
          child: Center(
            child: busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Color(0xFFD89A0F),
                    ),
                  )
                : Icon(
                    _on ? Icons.volume_up : Icons.volume_off,
                    size: 20,
                    color: !_known
                        ? Colors.white24
                        : (_on ? const Color(0xFFD89A0F) : Colors.white54),
                  ),
          ),
        ),
      ),
    );
  }
}
