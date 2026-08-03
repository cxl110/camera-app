import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'app_log.dart';

/// Uploads APP logs to a PC-side log receiver via HTTP POST.
///
/// The PC runs `python tools/log_receiver.py`, listening on 0.0.0.0:8080.
/// The phone must be on the same network as the PC (not the camera Wi-Fi).
///
/// The PC IP is persisted to a local json file (Documents/log_uploader.json),
/// not shared_preferences, to avoid plugin channel issues.
class LogUploader {
  static const _port = 8080;
  static const _timeout = Duration(seconds: 10);
  static const _configFileName = 'log_uploader.json';
  static const _keyPcIp = 'pc_ip';

  /// Config file path (under the Documents directory).
  static Future<File> _configFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_configFileName');
  }

  /// Get the saved PC IP address.
  static Future<String> getPcIp() async {
    try {
      final file = await _configFile();
      if (!await file.exists()) return '';
      final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return (json[_keyPcIp] as String?) ?? '';
    } catch (e) {
      AppLog.error('LogUploader', 'Failed to read PC IP', e);
      return '';
    }
  }

  /// Save the PC IP address.
  static Future<void> setPcIp(String ip) async {
    try {
      final file = await _configFile();
      await file.writeAsString(jsonEncode({_keyPcIp: ip}));
    } catch (e) {
      AppLog.error('LogUploader', 'Failed to save PC IP', e);
    }
  }

  /// Upload all logs to the PC.
  ///
  /// Returns a success message; throws an Exception on failure.
  static Future<String> uploadLogs({String? pcIp}) async {
    final ip = pcIp ?? await getPcIp();
    if (ip.isEmpty) throw Exception('Please set the PC IP address first');

    final logText = await AppLog.readAllLogs();
    if (logText.isEmpty || logText == 'No logs') throw Exception('No logs to upload');

    final bytes = utf8.encode(logText);
    final client = HttpClient();
    try {
      final request = await client
          .postUrl(Uri.parse('http://$ip:$_port/upload'))
          .timeout(_timeout);
      request.headers.set('Content-Type', 'text/plain; charset=utf-8');
      request.headers.set('Content-Length', bytes.length.toString());
      request.add(bytes);
      final response = await request.close().timeout(_timeout);

      if (response.statusCode == 200) {
        final body = await response.transform(utf8.decoder).join();
        AppLog.info('LogUploader', 'Logs uploaded: $body');
        return 'Logs uploaded to $ip ($body)';
      } else {
        final body = await response.transform(utf8.decoder).join();
        throw Exception('Server returned ${response.statusCode}: $body');
      }
    } catch (e) {
      AppLog.error('LogUploader', 'Upload failed', e);
      rethrow;
    } finally {
      client.close();
    }
  }
}
