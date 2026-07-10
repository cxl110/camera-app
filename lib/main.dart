import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'app.dart';
import 'services/filter_service.dart';
import 'services/camera_protocol.dart';
import 'services/mock_camera_protocol.dart';
import 'services/neural_filter_client.dart';
import 'services/filter_processor.dart';
import 'services/image_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (!kIsWeb) {
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
    ]);
  }

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Color(0xFF08080A),
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  // Initialize services safely
  final filterService = FilterService();
  try {
    await filterService.initialize();
  } catch (_) {}

  final cameraProtocol = MockCameraProtocol();
  FilterProcessor.setNeuralBackend(NeuralFilterClient());

  final imageService = ImageService();
  try {
    await imageService.initialize();
  } catch (_) {}

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<FilterService>.value(value: filterService),
        ChangeNotifierProvider<ImageService>.value(value: imageService),
        Provider<CameraProtocol>.value(value: cameraProtocol),
      ],
      child: const CameraApp(),
    ),
  );
}
