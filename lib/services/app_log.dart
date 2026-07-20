import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Persistent file-based logger for debugging on device.
///
/// Writes to Documents/logs/app_YYYYMMDD.log, rotating daily.
/// Use [AppLog.info] / [AppLog.error] / [AppLog.debug] to log.
///
/// Retrieve logs via [AppLog.getLogs] for sharing/sending.
class AppLog {
  static const _maxFileSize = 2 * 1024 * 1024; // 2MB per file
  static String? _logPath;
  static bool _initialized = false;

  static Future<void> init() async {
    if (_initialized) return;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final logDir = Directory('${dir.path}/logs');
      if (!await logDir.exists()) {
        await logDir.create(recursive: true);
      }
      final now = DateTime.now();
      final dateStr =
          '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
      _logPath = '${logDir.path}/app_$dateStr.log';
      _initialized = true;
      info('AppLog', 'Log started');
    } catch (_) {
      // Can't log if init fails — fallback to debugPrint
    }
  }

  static void info(String tag, String message) {
    _write('I', tag, message);
  }

  static void error(String tag, String message, [Object? error, StackTrace? stack]) {
    _write('E', tag, message);
    if (error != null) {
      _writeRaw('  error: $error');
    }
    if (stack != null) {
      _writeRaw('  stack: $stack');
    }
  }

  static void debug(String tag, String message) {
    _write('D', tag, message);
  }

  static void _write(String level, String tag, String message) {
    final line = '${_now()} $level/$tag: $message';
    _writeRaw(line);
  }

  static void _writeRaw(String line) {
    debugPrint(line);
    if (!_initialized || _logPath == null) return;

    try {
      final file = File(_logPath!);
      // Rotate if file gets too big
      if (file.existsSync()) {
        final size = file.lengthSync();
        if (size > _maxFileSize) {
          final now = DateTime.now();
          final dateStr =
              '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
          final timeStr =
              '${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}';
          _logPath = '${_logPath!.substring(0, _logPath!.lastIndexOf('/'))}/app_${dateStr}_$timeStr.log';
        }
      }
      file.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
    } catch (_) {
      // Silent — don't crash if log write fails
    }
  }

  static String _now() {
    final now = DateTime.now();
    return '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}.'
        '${now.millisecond.toString().padLeft(3, '0')}';
  }

  /// Get all log file paths for sharing.
  static Future<List<String>> getLogFiles() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final logDir = Directory('${dir.path}/logs');
      if (!await logDir.exists()) return [];
      final files = await logDir
          .list()
          .where((f) => f is File && f.path.endsWith('.log'))
          .map((f) => f.path)
          .toList();
      files.sort((a, b) => b.compareTo(a)); // newest first
      return files;
    } catch (_) {
      return [];
    }
  }

  /// Read all logs into a single string for sharing.
  static Future<String> readAllLogs() async {
    final files = await getLogFiles();
    if (files.isEmpty) return 'No logs';
    final buffer = StringBuffer();
    for (final f in files.take(5)) {
      // Last 5 files max
      try {
        buffer.writeln('=== $f ===');
        buffer.writeln(File(f).readAsStringSync());
      } catch (_) {}
    }
    return buffer.toString();
  }
}