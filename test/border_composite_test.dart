import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:camera_app/services/image_service.dart';

/// The border frames are WebP (they used to be PNG, and were 87 MB of the
/// install). The composite path in ImageService is the only place that decodes
/// a frame on export, and it used `img.decodePng` — which sniffs for the PNG
/// signature only, returns null for WebP, and then silently falls through to
/// "return the photo unchanged". The saved photo would lose its border while
/// the on-screen preview still showed one.
///
/// These tests pin both halves of that: the asset really is WebP-decodable, and
/// compositing it really paints pixels.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const frameName = 'frame_19.webp'; // the 50% border, the most obvious one

  test('border frame asset is bundled and decodes with the generic decoder', () async {
    final data = await rootBundle.load('assets/frames/$frameName');
    final bytes = data.buffer.asUint8List();

    expect(bytes.length, greaterThan(1000), reason: 'frame asset missing or empty');

    final decoded = img.decodeImage(bytes);
    expect(decoded, isNotNull, reason: 'decodeImage must handle the WebP frame');
    expect(decoded!.numChannels, 4, reason: 'frames need an alpha channel');

    // Regression guard: this is exactly what the old code called.
    expect(img.decodePng(bytes), isNull,
        reason: 'a WebP frame is not a PNG — if this ever passes, the '
            'format changed back and the comment in image_service.dart is stale');
  });

  test('compositing a WebP border actually paints on the photo', () async {
    final photo = img.Image(width: 400, height: 300);
    img.fill(photo, color: img.ColorRgb8(120, 140, 160));
    final photoBytes = Uint8List.fromList(img.encodeJpg(photo, quality: 92));

    final out = await ImageService().compositeBorder(photoBytes, frameName);
    final result = img.decodeImage(out);
    expect(result, isNotNull);
    expect(result!.width, 400);
    expect(result.height, 300);

    // The source photo is a flat colour; a painted border must break that in
    // the corners (frame_19 covers 50% of the frame).
    final corner = result.getPixel(4, 4);
    final middle = result.getPixel(200, 150);
    final cornerLuma = (corner.r + corner.g + corner.b) / 3;
    final middleLuma = (middle.r + middle.g + middle.b) / 3;

    expect((cornerLuma - 140).abs(), greaterThan(20),
        reason: 'corner pixel unchanged — the border was not composited');
    expect((cornerLuma - middleLuma).abs(), greaterThan(10),
        reason: 'corner and centre look identical — border probably missing');
  });
}
