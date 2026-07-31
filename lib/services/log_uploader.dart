import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'app_log.dart';

/// Uploads APP logs to a PC-side log receiver via HTTP POST.
///
/// PC 端运行 `python tools/log_receiver.py`，监听 0.0.0.0:8080。
/// 手机必须和 PC 在同一网络（不是相机 WiFi）。
///
/// PC IP 持久化到一个本地 json 文件（Documents/log_uploader.json），
/// 不依赖 shared_preferences，避免插件 channel 问题。
class LogUploader {
  static const _port = 8080;
  static const _timeout = Duration(seconds: 10);
  static const _configFileName = 'log_uploader.json';
  static const _keyPcIp = 'pc_ip';

  /// 配置文件路径（Documents 目录下）。
  static Future<File> _configFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_configFileName');
  }

  /// 获取保存的 PC IP 地址。
  static Future<String> getPcIp() async {
    try {
      final file = await _configFile();
      if (!await file.exists()) return '';
      final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return (json[_keyPcIp] as String?) ?? '';
    } catch (e) {
      AppLog.error('LogUploader', '读取 PC IP 失败', e);
      return '';
    }
  }

  /// 保存 PC IP 地址。
  static Future<void> setPcIp(String ip) async {
    try {
      final file = await _configFile();
      await file.writeAsString(jsonEncode({_keyPcIp: ip}));
    } catch (e) {
      AppLog.error('LogUploader', '保存 PC IP 失败', e);
    }
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
