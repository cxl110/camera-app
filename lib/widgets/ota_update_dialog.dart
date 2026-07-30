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

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1A1A2E),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text(
        '固件更新',
        style: const TextStyle(color: Colors.white, fontSize: 18),
      ),
      content: _updating ? _buildProgress() : _buildConfirmation(),
      actions: _updating ? null : _buildActions(),
    );
  }

  Widget _buildConfirmation() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _infoRow('新版本', widget.bundledVersion),
        const SizedBox(height: 8),
        _infoRow('当前版本', widget.cameraVersion ?? '未知'),
        const SizedBox(height: 20),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.orange.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.warning_amber, color: Colors.orange, size: 18),
                  const SizedBox(width: 6),
                  Text('注意事项',
                      style: TextStyle(
                          color: Colors.orange,
                          fontSize: 13,
                          fontWeight: FontWeight.w600)),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '• 更新期间请勿断开WiFi\n'
                '• 更新期间请勿关闭APP\n'
                '• 确保相机电量充足\n'
                '• 更新过程约需1分钟',
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
      OtaStatus.uploading => '正在更新固件...',
      OtaStatus.flashing => '固件刷写中...',
      OtaStatus.rebooting => '设备正在重启，请等待...',
      OtaStatus.done => '更新成功！',
      OtaStatus.failed => '更新失败',
      OtaStatus.idle => '准备中...',
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
            '⚠️ 请勿关闭APP或断开WiFi',
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
                  child: const Text('重试',
                      style: TextStyle(color: Color(0xFF4CAF50))),
                ),
              TextButton(
                onPressed: () => Navigator.pop(context, isDone),
                child: Text(
                  isDone ? '完成' : '关闭',
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
        child: const Text('取消', style: TextStyle(color: Colors.white54)),
      ),
      TextButton(
        onPressed: _startUpdate,
        child: const Text('立即更新',
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

      // Upload and monitor progress
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
