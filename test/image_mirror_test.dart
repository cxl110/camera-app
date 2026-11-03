import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:camera_app/services/image_mirror.dart';

/// Mirroring is OFF by default and must stay that way.
///
/// The camera's MJPEG stream and photo files are already correctly oriented; only
/// the camera's own LCD is mirrored by the firmware. An earlier build flipped
/// every image in the app, which made the preview and all photos look mirrored
/// ("flip twice = still mirrored"), so these tests pin both facts:
///   * [flipHorizontally] actually flips;
///   * [mirrorCameraImage] is a no-op in a normal build.
void main() {
  Uint8List stripedPng() {
    final image = img.Image(width: 3, height: 2);
    for (var y = 0; y < 2; y++) {
      image.setPixelRgb(0, y, 255, 0, 0);
      image.setPixelRgb(1, y, 0, 255, 0);
      image.setPixelRgb(2, y, 0, 0, 255);
    }
    return Uint8List.fromList(img.encodePng(image));
  }

  String columnColors(Uint8List bytes) {
    final decoded = img.decodeImage(bytes)!;
    return List.generate(decoded.width, (x) {
      final p = decoded.getPixel(x, 0);
      return '${p.r.toInt()},${p.g.toInt()},${p.b.toInt()}';
    }).join(' | ');
  }

  group('flipHorizontally', () {
    test('reverses columns', () {
      expect(columnColors(flipHorizontally(stripedPng())),
          '0,0,255 | 0,255,0 | 255,0,0');
    });

    test('keeps dimensions and rows', () {
      final source = stripedPng();
      final flipped = flipHorizontally(source);
      final a = img.decodeImage(source)!;
      final b = img.decodeImage(flipped)!;
      expect(b.width, a.width);
      expect(b.height, a.height);
      expect(b.getPixel(0, 0).r.toInt(), b.getPixel(0, 1).r.toInt());
    });

    test('JPEG input comes back as a decodable JPEG', () {
      final jpeg = Uint8List.fromList(img.encodeJpg(img.Image(width: 8, height: 8)));
      final flipped = flipHorizontally(jpeg);
      expect(isDecodableImage(flipped), isTrue);
      expect(flipped[0], 0xFF);
      expect(flipped[1], 0xD8);
    });

    test('garbage and empty input are returned untouched', () {
      final junk = Uint8List.fromList([1, 2, 3, 4, 5]);
      expect(flipHorizontally(junk), same(junk));
      final empty = Uint8List(0);
      expect(flipHorizontally(empty), same(empty));
    });
  });

  group('mirrorCameraImage', () {
    test('is a no-op unless the build opts in', () {
      expect(kMirrorCameraImages, isFalse,
          reason: 'store and field builds must not flip camera images');
      final source = stripedPng();
      expect(mirrorCameraImage(source), same(source));
    });

    test('the live-stream switch is off too', () {
      expect(kMirrorLiveStream, isFalse);
    });
  });
}
