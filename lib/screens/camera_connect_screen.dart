import 'package:flutter/material.dart' hide ConnectionState;
import 'package:provider/provider.dart';
import '../services/camera_service.dart';

class CameraConnectScreen extends StatefulWidget {
  const CameraConnectScreen({super.key});

  @override
  State<CameraConnectScreen> createState() => _CameraConnectScreenState();
}

class _CameraConnectScreenState extends State<CameraConnectScreen> {
  final _urlController = TextEditingController();

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<CameraService>(
      builder: (context, cameraService, _) {
        return Scaffold(
          appBar: AppBar(
            title: const Text('连接相机'),
            leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () {
                cameraService.disconnect();
                Navigator.pop(context);
              },
            ),
          ),
          body: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Connection status indicator
                _buildStatusIndicator(cameraService),
                const SizedBox(height: 32),

                // Manual URL input
                if (cameraService.state != ConnectionState.transferring) ...[
                  _buildManualConnect(cameraService),
                ],

                // Transfer progress
                if (cameraService.state == ConnectionState.transferring) ...[
                  const SizedBox(height: 24),
                  _buildTransferProgress(cameraService),
                ],

                const Spacer(),

                // Help section
                _buildHelpSection(),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildStatusIndicator(CameraService service) {
    IconData icon;
    String text;
    Color color;
    String? subtitle;

    switch (service.state) {
      case ConnectionState.disconnected:
        icon = Icons.wifi_off;
        text = '未连接';
        color = Colors.white38;
        subtitle = '请连接到相机WiFi网络';
      case ConnectionState.connecting:
        icon = Icons.wifi_find;
        text = '正在连接...';
        color = Colors.amber;
        subtitle = '检测相机设备中';
      case ConnectionState.connected:
        icon = Icons.wifi;
        text = '已连接';
        color = Colors.green;
        subtitle = service.detectedBrand != CameraBrand.auto
            ? '检测到 ${service.detectedBrand.name} 相机'
            : service.cameraBaseUrl ?? '';
      case ConnectionState.transferring:
        icon = Icons.downloading;
        text = '传输中';
        color = Colors.blue;
        subtitle = '${service.transferredCount}/${service.totalCount}';
      case ConnectionState.error:
        icon = Icons.error_outline;
        text = '连接失败';
        color = Colors.red;
        subtitle = service.errorMessage ?? '未知错误';
    }

    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A2E),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        children: [
          Icon(icon, size: 48, color: color),
          const SizedBox(height: 12),
          Text(text, style: TextStyle(color: color, fontSize: 18, fontWeight: FontWeight.w600)),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(subtitle, style: const TextStyle(color: Colors.white38, fontSize: 13)),
          ],
        ],
      ),
    );
  }

  Widget _buildManualConnect(CameraService service) {
    final isConnected = service.state == ConnectionState.connected;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A2E),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            '输入相机地址',
            style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 4),
          const Text(
            '相机WiFi IP地址，如 192.168.122.1:8080',
            style: TextStyle(color: Colors.white38, fontSize: 12),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _urlController,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: 'http://192.168.122.1:8080',
              hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.2)),
              filled: true,
              fillColor: const Color(0xFF0D0D1A),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.all(16),
            ),
            keyboardType: TextInputType.url,
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: isConnected
                      ? () {
                          _urlController.clear();
                          service.disconnect();
                        }
                      : () => service.connect(ssid: '相机WiFi'),
                  icon: Icon(isConnected ? Icons.link_off : Icons.auto_mode),
                  label: Text(isConnected ? '断开连接' : '自动检测'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white60,
                    side: BorderSide(color: Colors.white.withValues(alpha: 0.2)),
                    padding: const EdgeInsets.all(14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: isConnected
                      ? null
                      : () => service.connect(baseUrl: _urlController.text.trim()),
                  icon: const Icon(Icons.wifi),
                  label: const Text('连接'),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF2D5BD8),
                    padding: const EdgeInsets.all(14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (isConnected) ...[
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () async {
                await service.listPhotos();
                if (mounted && service.photos.isNotEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('发现 ${service.photos.length} 张照片'),
                    ),
                  );
                }
              },
              icon: const Icon(Icons.photo_library),
              label: const Text('浏览相机照片'),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF8B3DC1),
                padding: const EdgeInsets.all(14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildTransferProgress(CameraService service) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A2E),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        children: [
          LinearProgressIndicator(
            value: service.transferProgress,
            backgroundColor: Colors.white10,
            color: const Color(0xFF2D5BD8),
            minHeight: 6,
            borderRadius: BorderRadius.circular(3),
          ),
          const SizedBox(height: 12),
          Text(
            '${service.transferredCount} / ${service.totalCount} 张',
            style: const TextStyle(color: Colors.white38, fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _buildHelpSection() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A2E).withOpacity(0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '💡 使用提示',
            style: TextStyle(color: Colors.white60, fontSize: 13, fontWeight: FontWeight.w500),
          ),
          SizedBox(height: 8),
          _HelpStep('1', '打开相机的WiFi功能（通常在菜单 → 无线通信 → WiFi设置）'),
          _HelpStep('2', '在手机WiFi设置中连接相机的WiFi热点'),
          _HelpStep('3', '返回APP，点击"自动检测"或手动输入相机地址'),
          _HelpStep('4', '连接成功后即可浏览和下载相机中的照片'),
        ],
      ),
    );
  }
}

class _HelpStep extends StatelessWidget {
  final String number;
  final String text;
  const _HelpStep(this.number, this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              color: Colors.white10,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Center(
              child: Text(number, style: const TextStyle(color: Colors.white38, fontSize: 11)),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: const TextStyle(color: Colors.white38, fontSize: 12)),
          ),
        ],
      ),
    );
  }
}
