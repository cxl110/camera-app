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
            title: const Text('Connect Camera'),
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
        text = 'Not connected';
        color = Colors.white38;
        subtitle = 'Please connect to the camera Wi-Fi network';
      case ConnectionState.connecting:
        icon = Icons.wifi_find;
        text = 'Connecting...';
        color = Colors.amber;
        subtitle = 'Detecting camera device';
      case ConnectionState.connected:
        icon = Icons.wifi;
        text = 'Connected';
        color = Colors.green;
        subtitle = service.detectedBrand != CameraBrand.auto
            ? '${service.detectedBrand.name} camera detected'
            : service.cameraBaseUrl ?? '';
      case ConnectionState.transferring:
        icon = Icons.downloading;
        text = 'Transferring';
        color = Colors.blue;
        subtitle = '${service.transferredCount}/${service.totalCount}';
      case ConnectionState.error:
        icon = Icons.error_outline;
        text = 'Connection failed';
        color = Colors.red;
        subtitle = service.errorMessage ?? 'Unknown error';
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
            'Enter camera address',
            style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 4),
          const Text(
            'Camera Wi-Fi IP address, e.g. 192.168.122.1:8080',
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
                      : () => service.connect(ssid: 'Camera Wi-Fi'),
                  icon: Icon(isConnected ? Icons.link_off : Icons.auto_mode),
                  label: Text(isConnected ? 'Disconnect' : 'Auto detect'),
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
                  label: const Text('Connect'),
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
                      content: Text('${service.photos.length} photos found'),
                    ),
                  );
                }
              },
              icon: const Icon(Icons.photo_library),
              label: const Text('Browse camera photos'),
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
            '${service.transferredCount} / ${service.totalCount} photos',
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
            '💡 Quick guide',
            style: TextStyle(color: Colors.white60, fontSize: 13, fontWeight: FontWeight.w500),
          ),
          SizedBox(height: 8),
          _HelpStep('1', 'Turn on the camera Wi-Fi (usually Menu → Wireless → Wi-Fi settings)'),
          _HelpStep('2', 'Connect to the camera Wi-Fi hotspot in your phone Wi-Fi settings'),
          _HelpStep('3', 'Return to the app and tap "Auto detect" or enter the camera address'),
          _HelpStep('4', 'Once connected you can browse and download photos from the camera'),
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
