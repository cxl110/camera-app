import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:gal/gal.dart';
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

      // Audio diagnostics (the native parser reports whether the AVI has an
      // audio stream and its format). PCM audio is now written into the MP4;
      // non-PCM codecs are skipped.
      final audio = result['audio'] as Map<dynamic, dynamic>?;
      if (audio == null || audio['hasAudio'] != true) {
        AppLog.info('VideoTranscoder', 'Audio: none (AVI has no audio stream)');
      } else {
        final tag = audio['formatTag'];
        final ch = audio['channels'];
        final rate = audio['sampleRate'];
        final bits = audio['bitsPerSample'];
        final bytes = audio['bytes'];
        final codec = tag == 1
            ? 'PCM'
            : (tag == 2 ? 'ADPCM' : 'tag=$tag');
        AppLog.info('VideoTranscoder',
            'Audio: $codec, ch=$ch, rate=$rate, bits=$bits, ${bytes} bytes'
            '${tag == 1 ? ' (written to MP4)' : ' (skipped — unsupported codec)'}');
      }

      // 3. Save MP4 to system photo library.
      await Gal.putVideo(mp4Path);
      AppLog.info('VideoTranscoder', 'Saved to gallery');

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
