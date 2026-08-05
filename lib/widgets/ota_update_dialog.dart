import 'dart:async';
import 'package:flutter/material.dart';
import '../services/camera_protocol.dart';
import '../services/firmware_service.dart';
import '../services/http_camera_protocol.dart';
import '../services/app_log.dart';

/// Dialog for OTA firmware update.
///
/// Shows two states:
/// 1. **Confirmation** — version info + safety warnings + update button
/// 2. **Progress** — single progress bar + status text
///
/// Usage:
/// ```dart
/// final result = await OtaUpdateDialog.show(context,
///   cameraVersion: 'V0.5-20260729',
///   bundledVersion: 'V0.5-20260730',
///   protocol: protocol,
///   firmwareService: firmwareService,
/// );
/// ```
class OtaUpdateDialog extends StatefulWidget {
  final String? cameraVersion;
  final String bundledVersion;
  final HttpCameraProtocol protocol;
  final FirmwareService firmwareService;

  const OtaUpdateDialog({
    super.key,
    required this.cameraVersion,
    required this.bundledVersion,
    required this.protocol,
    required this.firmwareService,
  });

  /// Show the OTA update dialog. Returns true if update succeeded.
  static Future<bool?> show(
    BuildContext context, {
    required String? cameraVersion,
    required String bundledVersion,
    required HttpCameraProtocol protocol,
    required FirmwareService firmwareService,
  }) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => OtaUpdateDialog(
        cameraVersion: cameraVersion,
        bundledVersion: bundledVersion,
        protocol: protocol,
        firmwareService: firmwareService,
      ),
    );
  }

  @override
  State<OtaUpdateDialog> createState() => _OtaUpdateDialogState();
}

class _OtaUpdateDialogState extends State<OtaUpdateDialog> {
  OtaStatus _status = OtaStatus.idle;
  double _percent = 0.0;
  String? _error;
  bool _updating = false;
  // True once the upload finished and the device began rebooting (WiFi dropped).
  // In this state the dialog shows a "wait & reconnect" screen instead of the
  // progress bar, and the caller is told the update is mid-reboot (not done).
  bool _rebooting = false;
  Timer? _autoCloseTimer;

  @override
  void dispose() {
    _autoCloseTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1A1A2E),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text(
        _rebooting ? 'Rebooting' : 'Firmware Update',
        style: const TextStyle(color: Colors.white, fontSize: 18),
      ),
      content: _rebooting
          ? _buildRebooting()
          : (_updating ? _buildProgress() : _buildConfirmation()),
      actions: _rebooting
          ? _buildRebootingActions()
          : (_updating ? null : _buildActions()),
    );
  }

  /// "Device is rebooting" screen — shown after the upload succeeds and the
  /// camera drops its WiFi connection to restart. We don't block here waiting
  /// for it to come back (a reboot takes ~3 minutes); instead we tell the user
  /// to wait and reconnect, then dismiss the dialog so the rest of the app is
  /// usable.
  Widget _buildRebooting() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.restart_alt, color: Colors.lightBlue, size: 48),
        const SizedBox(height: 16),
        const Text(
          'Firmware uploaded. The camera is now restarting.',
          style: TextStyle(color: Colors.white, fontSize: 14),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 12),
        Text(
          'This takes about 2–3 minutes. Please wait for the camera to '
          'finish restarting, then reconnect to its WiFi and open the app '
          'again to verify the new firmware version.',
          style: TextStyle(color: Colors.white70, fontSize: 12, height: 1.6),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.orange.withOpacity(0.1),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.orange.withOpacity(0.3)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.warning_amber, color: Colors.orange, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Do not power off the camera while it is restarting.',
                  style: TextStyle(color: Colors.orange.shade200, fontSize: 12, height: 1.5),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  List<Widget> _buildRebootingActions() {
    return [
      TextButton(
        // Pops with null = mid-reboot (neither success nor failure yet).
        onPressed: () => Navigator.pop(context, null),
        child: const Text('OK', style: TextStyle(color: Color(0xFF4CAF50))),
      ),
    ];
  }

  Widget _buildConfirmation() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _infoRow('New version', widget.bundledVersion),
        const SizedBox(height: 8),
        _infoRow('Current version', widget.cameraVersion ?? 'Unknown'),
        const SizedBox(height: 20),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.orange.withOpacity(0.1),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.orange.withOpacity(0.3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.warning_amber, color: Colors.orange, size: 18),
                  const SizedBox(width: 6),
                  Text('Please note',
                      style: TextStyle(
                          color: Colors.orange,
                          fontSize: 13,
                          fontWeight: FontWeight.w600)),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '• Do not disconnect Wi-Fi during the update\n'
                '• Do not close the app during the update\n'
                '• Ensure the camera has sufficient battery\n'
                '• The update takes about 1 minute',
                style: TextStyle(color: Colors.orange.shade200, fontSize: 12, height: 1.6),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildProgress() {
    final statusText = switch (_status) {
      OtaStatus.uploading => 'Updating firmware...',
      OtaStatus.flashing => 'Flashing firmware...',
      OtaStatus.rebooting => 'Device is rebooting, please wait...',
      OtaStatus.done => 'Update successful!',
      OtaStatus.failed => 'Update failed',
      OtaStatus.idle => 'Preparing...',
    };

    final isDone = _status == OtaStatus.done;
    final isFailed = _status == OtaStatus.failed;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Progress bar
        if (!isDone && !isFailed) ...[
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: _percent,
              minHeight: 8,
              backgroundColor: Colors.white10,
              valueColor: AlwaysStoppedAnimation<Color>(
                _status == OtaStatus.rebooting
                    ? Colors.lightBlue
                    : const Color(0xFF4CAF50),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '${(_percent * 100).toInt()}%',
            style: const TextStyle(
                color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
          ),
        ],

        // Status text
        const SizedBox(height: 8),
        Text(
          statusText,
          style: TextStyle(
            color: isDone
                ? const Color(0xFF4CAF50)
                : isFailed
                    ? const Color(0xFFF44336)
                    : Colors.white70,
            fontSize: 14,
          ),
          textAlign: TextAlign.center,
        ),

        // Error detail
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(
            _error!,
            style: TextStyle(color: Colors.red.shade300, fontSize: 12),
            textAlign: TextAlign.center,
          ),
        ],

        // Warning during update
        if (!isDone && !isFailed) ...[
          const SizedBox(height: 16),
          Text(
            '⚠️ Do not close the app or disconnect Wi-Fi',
            style: TextStyle(color: Colors.orange.shade300, fontSize: 12),
          ),
        ],

        // Done / Failed actions
        if (isDone || isFailed) ...[
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (isFailed)
                TextButton(
                  onPressed: _startUpdate,
                  child: const Text('Retry',
                      style: TextStyle(color: Color(0xFF4CAF50))),
                ),
              TextButton(
                onPressed: () => Navigator.pop(context, isDone),
                child: Text(
                  isDone ? 'Done' : 'Close',
                  style: TextStyle(
                      color: isDone
                          ? const Color(0xFF4CAF50)
                          : Colors.white54),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  List<Widget> _buildActions() {
    return [
      TextButton(
        onPressed: () => Navigator.pop(context, false),
        child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
      ),
      TextButton(
        onPressed: _startUpdate,
        child: const Text('Update now',
            style: TextStyle(color: Color(0xFF4CAF50))),
      ),
    ];
  }

  Widget _infoRow(String label, String value) {
    return Row(
      children: [
        SizedBox(
          width: 72,
          child: Text(label,
              style: const TextStyle(color: Colors.white54, fontSize: 13)),
        ),
        Expanded(
          child: Text(value,
              style: const TextStyle(color: Colors.white, fontSize: 13)),
        ),
      ],
    );
  }

  Future<void> _startUpdate() async {
    setState(() {
      _updating = true;
      _status = OtaStatus.uploading;
      _percent = 0.0;
      _error = null;
    });

    try {
      // Load firmware images from assets
      final bootBytes = await widget.firmwareService.loadBootImage();
      final rootfsBytes = await widget.firmwareService.loadRootfsImage();

      AppLog.info('OTA', 'Starting firmware update: '
          'boot=${bootBytes.length} bytes, rootfs=${rootfsBytes.length} bytes');

      // Upload and monitor progress. The stream ends with OtaStatus.rebooting
      // once the device finishes flashing and drops the WiFi connection — it
      // does NOT wait for the device to come back online.
      await for (final progress in widget.protocol.uploadFirmware(
        bootBytes: bootBytes,
        rootfsBytes: rootfsBytes,
      )) {
        if (!mounted) return;
        setState(() {
          _status = progress.status;
          _percent = progress.percent;
          _error = progress.error;
        });
      }

      // Stream ended. If we reached the rebooting phase, the upload succeeded
      // and the device is now restarting: switch to the "wait & reconnect"
      // screen and auto-close shortly so the user isn't stuck on this dialog.
      if (_status == OtaStatus.rebooting && _error == null) {
        setState(() => _rebooting = true);
        AppLog.info('OTA', 'Firmware uploaded; device rebooting — '
            'showing wait screen, dialog will auto-close');
        _autoCloseTimer = Timer(const Duration(seconds: 5), () {
          if (mounted) Navigator.pop(context, null); // null = mid-reboot
        });
        return;
      }

      // Any other terminal state (done/failed) is handled by _buildProgress.
    } catch (e) {
      if (!mounted) return;
      AppLog.error('OTA', 'Firmware update failed', e);
      setState(() {
        _status = OtaStatus.failed;
        _error = e.toString();
      });
    }
  }
}
