import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'app.dart';
import 'services/filter_service.dart';
import 'services/image_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Lock to portrait for camera use
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);

  // Dark status bar with transparent background
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Color(0xFF08080A),
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  // Initialize services
  final filterService = FilterService();
  await filterService.initialize();

  final imageService = ImageService();
  await imageService.initialize();

  runApp(
    MultiProvider(
      providers: [
        Provider<FilterService>.value(value: filterService),
        Provider<ImageService>.value(value: imageService),
      ],
      child: const CameraApp(),
    ),
  );
}
