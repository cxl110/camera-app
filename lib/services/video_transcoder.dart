import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:image_gallery_saver/image_gallery_saver.dart';
import 'app_log.dart';

/// Bridge to the native iOS VideoTranscoder plugin.
///
/// Transcodes AVI (MJPEG) → MP4 (H.264 VideoToolbox) via platform channel.
class VideoTranscoder {
  static const _channel = MethodChannel('com.cameraapp/video');

  /// Transcode an AVI file to MP4 and save to the system photo library.
  ///
  /// [aviBytes] — raw AVI file bytes downloaded from the camera.
  /// [name] — original filename (e.g. "VID_20260717_150510.avi").
  ///
  /// Returns the saved MP4 file path, or null on failure.
  static Future<String?> transcodeAndSave({
    required Uint8List aviBytes,
    required String name,
  }) async {
    try {
      // 1. Write AVI bytes to a temp file (native side reads from path).
      final tempDir = await getTemporaryDirectory();
      final aviFile = File('${tempDir.path}/$name');
      await aviFile.writeAsBytes(aviBytes, flush: true);
      AppLog.info('VideoTranscoder', 'AVI written to ${aviFile.path} (${aviBytes.length} bytes)');

      // 2. Call native transcoder.
      final result = await _channel.invokeMethod<Map>('transcodeAviToMp4', {
        'inputPath': aviFile.path,
        'outputName': name,
      });

      if (result == null) {
        AppLog.error('VideoTranscoder', 'Native transcode returned null');
        return null;
      }

      final mp4Path = result['path'] as String?;
      if (mp4Path == null) {
        AppLog.error('VideoTranscoder', 'No MP4 path in result');
        return null;
      }

      AppLog.info('VideoTranscoder',
          'Transcoded: ${result['width']}x${result['height']}, '
          '${result['frameCount']} frames, ${result['fps']} fps');

      // 3. Save MP4 to system photo library.
      final saveResult = await ImageGallerySaver.saveFile(mp4Path);
      AppLog.info('VideoTranscoder', 'Save result: $saveResult');

      // 4. Clean up temp files.
      try {
        await aviFile.delete();
        final mp4File = File(mp4Path);
        if (await mp4File.exists()) await mp4File.delete();
      } catch (_) {}

      return mp4Path;
    } on PlatformException catch (e) {
      AppLog.error('VideoTranscoder', 'Platform error: ${e.code} — ${e.message}');
      return null;
    } catch (e) {
      AppLog.error('VideoTranscoder', 'Transcode error', e);
      return null;
    }
  }
}
