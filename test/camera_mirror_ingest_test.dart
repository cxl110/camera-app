import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;

import 'package:camera_app/services/http_camera_protocol.dart';

/// Regression guard: the protocol must hand back camera bytes **unchanged**.
///
/// An earlier build flipped every camera image at ingest (a mistaken belief that
/// the sensor was mounted mirrored), which made the gallery, the editor and the
/// exported photos all appear mirrored. The camera is fine; only its own LCD
/// needs mirroring, and the firmware does that itself.
void main() {
  Uint8List stripedPng() {
    final image = img.Image(width: 3, height: 1);
    image.setPixelRgb(0, 0, 255, 0, 0);
    image.setPixelRgb(1, 0, 0, 255, 0);
    image.setPixelRgb(2, 0, 0, 0, 255);
    return Uint8List.fromList(img.encodePng(image));
  }

  String rowColors(Uint8List bytes) {
    final decoded = img.decodeImage(bytes)!;
    return List.generate(decoded.width, (x) {
      final p = decoded.getPixel(x, 0);
      return '${p.r.toInt()},${p.g.toInt()},${p.b.toInt()}';
    }).join(' | ');
  }

  test('downloadPhotoBytes returns the bytes as delivered', () async {
    final payload = stripedPng();
    final client = MockClient((request) async {
      if (request.url.path.startsWith('/file/')) {
        return http.Response.bytes(payload, 200);
      }
      return http.Response('not found', 404);
    });
    final protocol = HttpCameraProtocol(baseUrl: 'http://camera.test', client: client);

    final bytes = await protocol.downloadPhotoBytes('IMG_20260101_000000.jpg');

    expect(bytes, isNotNull);
    expect(rowColors(bytes!), '255,0,0 | 0,255,0 | 0,0,255',
        reason: 'camera output is already correctly oriented');
  });

  test('listPhotos returns thumbnails as delivered', () async {
    final payload = stripedPng();
    final client = MockClient((request) async {
      final path = request.url.path;
      if (path == '/list') {
        return http.Response(
          jsonEncode({
            'total': 1,
            'offset': 0,
            'limit': 20,
            'timestamp': 1793000000,
            'boot_id': 'boot-A',
            'clock_synced': true,
            'clock_source': 'flash',
            'files': [
              {'name': 'IMG_20260101_000000.jpg', 'type': 'photo', 'size': 100, 'mtime': 1793000000}
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (path.startsWith('/thumb/')) {
        return http.Response.bytes(payload, 200);
      }
      return http.Response('not found', 404);
    });
    final protocol = HttpCameraProtocol(baseUrl: 'http://camera.test', client: client);

    final page = await protocol.listPhotos(limit: 20);

    expect(page.photos, hasLength(1));
    final thumb = page.photos.first.thumbnail;
    expect(thumb, isNotNull);
    expect(rowColors(thumb!), '255,0,0 | 0,255,0 | 0,0,255');
  });
}
