import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../services/camera_protocol.dart';
import '../services/http_camera_protocol.dart';
import '../services/firmware_service.dart';
import '../services/image_service.dart';
import '../services/app_log.dart';
import '../services/log_uploader.dart';
import '../widgets/wifi_indicator.dart';
import '../widgets/camera_preview.dart';
import '../widgets/capture_controls.dart';
import '../widgets/bottom_tabs.dart';
import '../widgets/ota_update_dialog.dart';
import 'effects_screen.dart';
import 'borders_screen.dart';
import 'gallery_screen.dart';

/// Main camera screen.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  bool _isConnected = false;
  bool _isVerifying = true;
  String _activeTab = 'CAMERA';
  String? _cameraModel;

  // OTA firmware update state
  String? _cameraFwVersion;
  bool _otaSupported = false;
  bool _firmwareUpdateAvailable = false;
  final FirmwareService _firmwareService = FirmwareService();

  StreamSubscription<ConnectionStatus>? _connectionSub;
  Stream<Uint8List>? _liveViewStream;

  // Reconnect watchdog: when disconnected, poll /info every few seconds so the
  // app recovers automatically when the camera comes back (no need for the
  // user to foreground the app).
  Timer? _reconnectWatchdog;

  CameraProtocol get _protocol => context.read<CameraProtocol>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initConnection();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _connectionSub?.cancel();
    _reconnectWatchdog?.cancel();
    _stopLiveView();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // App back to foreground. Re-check connection; if still connected, make
      // sure live view is running (it may have been stopped on pause).
      _retryConnection().then((_) {
        if (mounted && _isConnected && !_liveViewActive) {
          _startLiveView();
        }
      });
    } else if (state == AppLifecycleState.paused) {
      _stopLiveView();
    }
  }

  // ── Connection State Machine ──

  Future<void> _initConnection() async {
    // Listen for connection status changes
    _connectionSub = _protocol.connectionStream.listen((status) {
      if (!mounted) return;
      setState(() {
        _isConnected = status.connected;
        _cameraModel = status.cameraBrand;
        _cameraFwVersion = status.fwVersion;
        _otaSupported = status.otaSupported ?? false;
        if (_isConnected) {
          AppLog.info('Home', 'Camera connected: $_cameraModel fw=$_cameraFwVersion ota=$_otaSupported');
          _isVerifying = false;
          // Fresh connection → reset the live-view retry budget.
          _liveViewRetryCount = 0;
          // (Re)start live view whenever the camera (re)connects — the
          // stream from a previous session is stale/closed.
          _startLiveView();
          // Check for firmware update
          if (_otaSupported) _checkFirmwareUpdate();
        } else {
          AppLog.info('Home', 'Camera disconnected');
          _stopLiveView();
          _firmwareUpdateAvailable = false;
        }
      });

      // Manage the reconnect watchdog: run it only while disconnected.
      if (status.connected) {
        _reconnectWatchdog?.cancel();
        _reconnectWatchdog = null;
      } else {
        _ensureReconnectWatchdog();
      }
    });

    // Initial check — retry a few times before showing WiFi guide.
    var attempts = 0;
    while (!_isConnected && attempts < 3) {
      await _retryConnection();
      attempts++;
      if (!_isConnected && attempts < 3) {
        await Future.delayed(const Duration(seconds: 2));
      }
    }
    if (!mounted) return;
    if (!_isConnected) {
      _showWiFiGuide();
      _ensureReconnectWatchdog();
    }
  }

  /// Start (or keep running) the periodic reconnect poll while disconnected.
  void _ensureReconnectWatchdog() {
    if (_reconnectWatchdog != null && _reconnectWatchdog!.isActive) return;
    _reconnectWatchdog = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!_isConnected) _retryConnection();
    });
  }

  Future<void> _retryConnection() async {
    try {
      final status = await _protocol.getConnectionStatus();
      if (!mounted) return;
      // Only act on a transition into connected here; the connectionStream
      // listener handles live-view start/stop and watchdog management.
      // (getConnectionStatus emits status changes internally.)
      if (status.connected) {
        setState(() {
          _isConnected = status.connected;
          _cameraModel = status.cameraBrand;
          _cameraFwVersion = status.fwVersion;
          _otaSupported = status.otaSupported ?? false;
          _isVerifying = false;
        });
        if (_otaSupported) _checkFirmwareUpdate();
        // Live view start is handled by the connectionStream listener, but
        // guard against the no-op emit case (already connected → no event).
        if (!_liveViewActive) {
          _liveViewRetryCount = 0;
          _startLiveView();
        }
      }
    } catch (_) {
      // Silent retry — don't change connection state on transient failures.
      // The connectionStream listener will handle genuine disconnects.
    }
  }

  // RTC sync is now handled internally by HttpCameraProtocol
  // (auto-syncs on connection + every 3 minutes)

  // ── Firmware Update ──

  Future<void> _checkFirmwareUpdate() async {
    final hasFw = await _firmwareService.hasFirmware();
    if (!hasFw || !mounted) return;

    final manifest = _firmwareService.manifest;
    if (manifest == null) return;

    final needsUpdate = _firmwareService.needsUpdate(_cameraFwVersion);
    AppLog.info('Home', 'Firmware check: camera=$_cameraFwVersion '
        'bundled=${manifest.version} needsUpdate=$needsUpdate');

    if (needsUpdate && mounted) {
      setState(() => _firmwareUpdateAvailable = true);
    }
  }

  void _onFirmwareUpdate() async {
    final manifest = _firmwareService.manifest;
    if (manifest == null) return;

    final protocol = _protocol;
    if (protocol is! HttpCameraProtocol) return;

    final result = await OtaUpdateDialog.show(
      context,
      cameraVersion: _cameraFwVersion,
      bundledVersion: manifest.version,
      protocol: protocol,
      firmwareService: _firmwareService,
    );

    if (!mounted) return;

    if (result == true) {
      // Update fully succeeded — re-check connection to get new fw_version.
      setState(() => _firmwareUpdateAvailable = false);
      await _retryConnection();
    } else if (result == null) {
      // Firmware was uploaded and the device is rebooting (WiFi dropped). We
      // don't know the outcome yet — the camera takes ~2-3 min to restart.
      // Hide the update button and ask the user to wait & reconnect.
      setState(() => _firmwareUpdateAvailable = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'Camera is restarting. Wait ~2-3 minutes, reconnect to its '
              'WiFi, then reopen the app to confirm the update.'),
          duration: Duration(seconds: 8),
        ),
      );
    }
    // result == false: user cancelled before updating — keep the button.
  }

  void _showWiFiGuide() {
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title: const Row(
          children: [
            Icon(Icons.wifi_find, color: Color(0xFFD89A0F), size: 24),
            SizedBox(width: 10),
            Text('Connect to Camera WiFi', style: TextStyle(color: Colors.white, fontSize: 16)),
          ],
        ),
        content: const Text(
          'Please connect to the camera WiFi hotspot:\n\n'
          'SSID: ZIVIGo\nPassword: zivi2025\n\n'
          'Return to the app after connecting.',
          style: TextStyle(color: Colors.white60, fontSize: 14, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              try {
                const MethodChannel('com.cameraapp/system')
                    .invokeMethod('openWiFiSettings');
              } catch (_) {}
            },
            child: const Text('Settings', style: TextStyle(color: Color(0xFFD89A0F))),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              _retryConnection();
            },
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF2D5BD8),
            ),
            child: const Text('Re-check'),
          ),
        ],
      ),
    );
  }

  // ── Live View ──

  // Debounce: if already started within last 500ms, skip.
  Timer? _startLiveViewTimer;
  bool _liveViewActive = false;
  int _liveViewRetryCount = 0;
  static const _maxLiveViewRetries = 3;

  void _startLiveView() {
    _startLiveViewTimer?.cancel();
    _startLiveViewTimer = Timer(const Duration(milliseconds: 100), () {
      _doStartLiveView();
    });
  }

  void _doStartLiveView() {
    if (_liveViewActive) return;
    // Only attempt if we believe the camera is connected.
    if (!_isConnected) {
      AppLog.info('Home', 'Skipping live view start — not connected');
      return;
    }
    // Stop any previous stream cleanly, then start a new one.
    _liveViewActive = false;
    _liveViewStream = null;
    try { _protocol.stopLiveView(); } catch (_) {}

    _liveViewActive = true;
    AppLog.info('Home', 'Starting live view...');

    try {
      _liveViewStream = _protocol.startLiveView();
      // MUST call setState so CameraPreview gets the new stream reference.
      // Without this, the widget tree still holds the old (closed) stream
      // and the preview stays blank.
      setState(() {});

      _liveViewStream!.listen(
        null,
        onError: (e) {
          debugPrint('[HomeScreen] live view error: $e');
          _liveViewActive = false;
          // Camera unreachable — stop hammering. The connection state machine
          // (heartbeat / /info watchdog) will restart live view once the
          // camera is back. Only do a few bounded retries for transient blips
          // while still connected.
          if (!_isConnected) return;
          _liveViewRetryCount++;
          if (_liveViewRetryCount <= _maxLiveViewRetries && mounted) {
            final delay = Duration(seconds: 2 * _liveViewRetryCount);
            AppLog.info('Home', 'Live view error, retry $_liveViewRetryCount in ${delay.inSeconds}s');
            Future.delayed(delay, () {
              if (mounted && _isConnected && !_liveViewActive) _startLiveView();
            });
          } else {
            AppLog.info('Home', 'Live view retries exhausted — waiting for reconnect');
          }
        },
        onDone: () {
          debugPrint('[HomeScreen] live view ended');
          _liveViewActive = false;
          // Only restart if we still believe the camera is connected AND we
          // haven't exhausted retries. Previously this restarted unconditionally,
          // which caused a 1/sec retry storm against a dead camera for minutes.
          if (!mounted || !_isConnected) return;
          _liveViewRetryCount++;
          if (_liveViewRetryCount <= _maxLiveViewRetries) {
            AppLog.info('Home', 'Live view stream ended, restarting (retry $_liveViewRetryCount)...');
            _startLiveView();
          } else {
            AppLog.info('Home', 'Live view ended, retries exhausted — waiting for reconnect');
          }
        },
      );
    } catch (e) {
      _liveViewActive = false;
      debugPrint('[HomeScreen] failed to start live view: $e');
      _liveViewRetryCount++;
      if (_liveViewRetryCount <= _maxLiveViewRetries && mounted && _isConnected) {
        final delay = Duration(seconds: 2 * _liveViewRetryCount);
        Future.delayed(delay, () {
          if (mounted && _isConnected && !_liveViewActive) _startLiveView();
        });
      }
    }
  }

  void _stopLiveView() {
    _startLiveViewTimer?.cancel();
    if (_liveViewActive) {
      AppLog.info('Home', 'Stopping live view (was active)');
    }
    _liveViewActive = false;
    _liveViewStream = null;
    try {
      _protocol.stopLiveView();
    } catch (_) {}
  }

  // ── UI ──

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      body: SafeArea(
        child: Column(
          children: [
            _buildTopBar(),
            Expanded(
              child: CameraPreview(
                isConnected: _isConnected,
                frameStream: _liveViewStream,
              ),
            ),
            Selector<ImageService, Uint8List?>(
              selector: (_, service) => service.currentPhoto,
              builder: (_, currentPhoto, __) => CaptureControls(
                lastPhoto: currentPhoto,
                onShutter: _onShutterPressed,
                enabled: _isConnected,
              ),
            ),
            const SizedBox(height: 24),
            BottomTabs(
              activeTab: _activeTab,
              onTabChanged: _onTabChanged,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(color: Color(0xFF0A0A0A)),
      child: Row(
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              if (_isConnected) {
                final fwInfo = _cameraFwVersion != null ? ' fw=$_cameraFwVersion' : '';
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Connected $_cameraModel$fwInfo'),
                    backgroundColor: const Color(0xFF1A1A2E),
                    duration: const Duration(seconds: 1),
                  ),
                );
              } else if (_isVerifying) {
                _retryConnection();
              } else {
                _showWiFiGuide();
              }
            },
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                WifiIndicator(isConnected: _isConnected),
                const SizedBox(width: 6),
                Text(
                  _isConnected ? 'Connected' : (_isVerifying ? 'Checking...' : 'Disconnected'),
                  style: TextStyle(
                    color: _isConnected
                        ? const Color(0xFF4CAF50)
                        : const Color(0xFFF44336),
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          const Spacer(),
          // Firmware update button
          if (_firmwareUpdateAvailable)
            IconButton(
              onPressed: _onFirmwareUpdate,
              icon: Stack(
                clipBehavior: Clip.none,
                children: [
                  const Icon(Icons.system_update, color: Color(0xFFD89A0F), size: 20),
                  // Red dot badge
                  Positioned(
                    right: -2,
                    top: -2,
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                        color: Color(0xFFF44336),
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                ],
              ),
              tooltip: 'Firmware update',
            ),
          // Upload logs button
          IconButton(
            onPressed: _onUploadLogs,
            icon: const Icon(Icons.bug_report_outlined, color: Colors.white54, size: 20),
            tooltip: 'Upload Logs',
          ),
          IconButton(
            onPressed: _isConnected ? _onOpenGallery : null,
            icon: Icon(
              Icons.folder_outlined,
              color: Colors.white.withValues(alpha: _isConnected ? 0.7 : 0.2),
              size: 22,
            ),
            tooltip: 'Camera Photos',
          ),
        ],
      ),
    );
  }

  void _onOpenGallery() async {
    if (!_isConnected) return;
    _stopLiveView();
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const GalleryScreen()),
    );
    if (_isConnected) _startLiveView();
  }

  void _onUploadLogs() async {
    try {
      // 1. Show current PC IP or prompt to set it.
      final currentIp = await LogUploader.getPcIp();

      if (!mounted) return;
      final ip = await showDialog<String>(
        context: context,
        builder: (ctx) => _IpInputDialog(currentIp: currentIp),
      );

      if (ip == null || ip.isEmpty || !mounted) return; // cancelled

      // 2. Save IP for next time.
      await LogUploader.setPcIp(ip);

      // 3. Show uploading indicator.
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Uploading logs...'),
          backgroundColor: Color(0xFF1A1A2E),
          duration: Duration(seconds: 1),
        ),
      );

      // 4. Upload.
      try {
        final msg = await LogUploader.uploadLogs(pcIp: ip);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg), backgroundColor: const Color(0xFF2E7D32)),
        );
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Upload failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      // e.g. SharedPreferences not initialized
      if (!mounted) return;
      AppLog.error('Home', 'Upload logs failed to start', e);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not open log upload: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  DateTime _lastCaptureTime = DateTime(2000);

  void _onShutterPressed() async {
    if (!_isConnected) return;

    // 1-second cooldown to prevent burst capture
    final now = DateTime.now();
    if (now.difference(_lastCaptureTime).inMilliseconds < 1000) return;
    _lastCaptureTime = now;
    try {
      final result = await _protocol.capturePhoto();
      if (!mounted) return;

      // Use fullImage (12MP) as the shared photo. Thumbnail is too small.
      final bytes = result.fullImage ?? result.thumbnail;
      if (bytes != null) {
        context.read<ImageService>().loadPhoto(bytes, name: result.name);
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('📸 ${result.name}'),
          backgroundColor: const Color(0xFF1A1A2E),
          duration: const Duration(milliseconds: 600),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.only(bottom: 160),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Capture failed: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  void _onTabChanged(String tab) {
    if (tab == 'EFFECTS') {
      _stopLiveView();
      _navigateTo(EffectsScreen(wifiConnected: _isConnected)).then((_) {
        // Always try to restart — connection events will keep it alive if connected.
        _startLiveView();
      });
      return;
    }
    if (tab == 'BORDERS') {
      _stopLiveView();
      _navigateTo(BordersScreen(wifiConnected: _isConnected)).then((_) {
        _startLiveView();
      });
      return;
    }
    setState(() => _activeTab = tab);
  }

  Future<void> _navigateTo(Widget page) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => page),
    );
  }
}

/// Simple dialog to enter PC IP address for log upload.
class _IpInputDialog extends StatefulWidget {
  final String currentIp;
  const _IpInputDialog({required this.currentIp});

  @override
  State<_IpInputDialog> createState() => _IpInputDialogState();
}

class _IpInputDialogState extends State<_IpInputDialog> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.currentIp);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1A1A2E),
      title: const Row(
        children: [
          Icon(Icons.bug_report, color: Color(0xFFD89A0F), size: 22),
          SizedBox(width: 10),
          Text('Upload Logs to PC',
              style: TextStyle(color: Colors.white, fontSize: 16)),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Make sure log_receiver.py is running on PC.\n'
            'Phone and PC must be on the same network.',
            style: TextStyle(color: Colors.white60, fontSize: 13, height: 1.5),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _ctrl,
            style: const TextStyle(color: Colors.white, fontSize: 15),
            decoration: InputDecoration(
              labelText: 'PC IP Address',
              hintText: 'e.g. 192.168.1.114',
              labelStyle: const TextStyle(color: Colors.white38),
              hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.2)),
              enabledBorder: const OutlineInputBorder(
                borderSide: BorderSide(color: Colors.white24),
              ),
              focusedBorder: const OutlineInputBorder(
                borderSide: BorderSide(color: Color(0xFFD89A0F)),
              ),
            ),
            keyboardType: TextInputType.url,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel', style: TextStyle(color: Colors.white38)),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _ctrl.text.trim()),
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF2D5BD8),
          ),
          child: const Text('Upload'),
        ),
      ],
    );
  }
}
