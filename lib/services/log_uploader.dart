import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import 'app_log.dart';

/// Uploads APP logs to a PC-side log receiver via HTTP POST.
///
/// PC 端运行 `python tools/log_receiver.py`，监听 0.0.0.0:8080。
/// 手机必须和 PC 在同一网络（不是相机 WiFi）。
class LogUploader {
  static const _keyPcIp = 'log_uploader_pc_ip';
  static const _port = 8080;
  static const _timeout = Duration(seconds: 10);

  /// 获取保存的 PC IP 地址。
  static Future<String> getPcIp() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyPcIp) ?? '';
  }

  /// 保存 PC IP 地址。
  static Future<void> setPcIp(String ip) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyPcIp, ip);
  }

  /// 上传所有日志到 PC。
  ///
  /// 返回成功消息；失败时 throw Exception。
  static Future<String> uploadLogs({String? pcIp}) async {
    final ip = pcIp ?? await getPcIp();
    if (ip.isEmpty) throw Exception('请先设置 PC 的 IP 地址');

    final logText = await AppLog.readAllLogs();
    if (logText.isEmpty || logText == 'No logs') throw Exception('没有日志');

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
        AppLog.info('LogUploader', '日志上传成功: $body');
        return '日志已上传到 $ip ($body)';
      } else {
        final body = await response.transform(utf8.decoder).join();
        throw Exception('服务器返回 ${response.statusCode}: $body');
      }
    } catch (e) {
      AppLog.error('LogUploader', '上传失败', e);
      rethrow;
    } finally {
      client.close();
    }
  }
}