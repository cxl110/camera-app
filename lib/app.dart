import 'package:flutter/material.dart';
import 'screens/home_screen.dart';

class CameraApp extends StatelessWidget {
  const CameraApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '相机伴侣',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFFF6B35),
          brightness: Brightness.dark,
          surface: const Color(0xFF08080A),
        ),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF08080A),
        fontFamily: 'monospace',
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
          centerTitle: true,
        ),
        snackBarTheme: SnackBarThemeData(
          backgroundColor: const Color(0xFF1A1A2E),
          contentTextStyle: const TextStyle(color: Colors.white),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          behavior: SnackBarBehavior.floating,
        ),
      ),
      home: const HomeScreen(),
    );
  }
}
