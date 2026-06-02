import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'app.dart';
import 'services/filter_service.dart';
import 'services/image_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Lock to portrait for camera use (mobile only)
  if (!kIsWeb) {
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
    ]);
  }

  // Dark status bar
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Color(0xFF08080A),
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  // Initialize services (graceful on web)
  final filterService = FilterService();
  await filterService.initialize();

  ImageService? imageService;
  if (!kIsWeb) {
    imageService = ImageService();
    await imageService.initialize();
  }

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<FilterService>.value(value: filterService),
        if (imageService != null)
          ChangeNotifierProvider<ImageService>.value(value: imageService),
      ],
      child: const CameraApp(),
    ),
  );
}
