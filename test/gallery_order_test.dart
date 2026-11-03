import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:camera_app/services/camera_protocol.dart';
import 'package:camera_app/services/http_camera_protocol.dart';

/// Requirement: the album must ALWAYS open on the newest shot, first.
///
/// The device's `/list` is not guaranteed newest-first — the protocol spec's own
/// example is ascending (oldest first). The old code paged with
/// `offset = photos.length`, which against an ascending server walked from the
/// oldest photo forwards: the grid opened on the oldest picture.
///
/// These tests run a mock camera that answers `/list` in ASCENDING order and
/// gives every file the SAME mtime, then check that:
///  - the first page is the newest window, newest-first;
///  - the second page continues with older photos (no overlap, no duplicates);
///  - ordering works even though mtime carries no information at all.
void main() {
  /// 45 files, oldest first: IMG_20260717_100000 .. IMG_20260717_104400
  final List<String> ascendingNames = List.generate(45, (i) {
    final t = DateTime(2026, 7, 17, 10).add(Duration(minutes: i));
    String two(int v) => v.toString().padLeft(2, '0');
    return 'IMG_20260717_${two(t.hour)}${two(t.minute)}00';
  });

  HttpCameraProtocol buildProtocol() {
    final client = MockClient((request) async {
      final path = request.url.path;
      if (request.url.pathSegments.isNotEmpty && path.startsWith('/thumb/')) {
        return http.Response.bytes(const [0xFF, 0xD8, 0xFF, 0xD9], 200);
      }
      if (path == '/list') {
        final offset = int.parse(request.url.queryParameters['offset'] ?? '0');
        final limit = int.parse(request.url.queryParameters['limit'] ?? '20');
        final page = ascendingNames.skip(offset).take(limit).map((name) => {
              'name': name,
              'type': 'photo',
              'size': 1024,
              // Deliberately identical for every file: mtime must not be used
              // for ordering (v1.8 shifts it around).
              'mtime': 1793000000,
            }).toList();
        return http.Response(
          jsonEncode({
            'total': ascendingNames.length,
            'offset': offset,
            'limit': limit,
            'timestamp': 1793000000,
            'boot_id': 'boot-A',
            'clock_synced': true,
            'clock_source': 'flash',
            'files': page,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('not found', 404);
    });
    return HttpCameraProtocol(baseUrl: 'http://camera.test', client: client);
  }

  test('first page is the newest window even when the device lists oldest-first',
      () async {
    final protocol = buildProtocol();
    final page = await protocol.listPhotos(limit: 20);

    expect(page.total, 45);
    expect(page.photos.length, 20);
    // Newest of all 45 is the last one the device reports.
    expect(page.photos.first.name, ascendingNames.last);
    // ...and the window keeps running backwards.
    expect(page.photos[1].name, ascendingNames[ascendingNames.length - 2]);
    expect(page.photos.last.name, ascendingNames[25]);
  });

  test('second page continues with older photos, no overlap', () async {
    final protocol = buildProtocol();
    final first = await protocol.listPhotos(limit: 20);
    final second = await protocol.listPhotos(offset: 20, limit: 20);

    expect(second.photos.length, 20);
    expect(second.photos.first.name, ascendingNames[24]);
    expect(second.photos.last.name, ascendingNames[5]);

    final firstNames = first.photos.map((p) => p.name).toSet();
    final overlap = second.photos.where((p) => firstNames.contains(p.name));
    expect(overlap, isEmpty, reason: 'paging must not repeat photos');
  });

  test('final partial page returns only what is left', () async {
    final protocol = buildProtocol();
    final last = await protocol.listPhotos(offset: 40, limit: 20);

    expect(last.photos.length, 5, reason: '45 files - 40 already shown = 5');
    expect(last.photos.first.name, ascendingNames[4]);
    expect(last.photos.last.name, ascendingNames[0]);
  });

  test('photos and videos interleave chronologically', () {
    final photos = [
      CameraPhoto(id: 'a', name: 'VID_20260717_100200', sizeBytes: 1, timestamp: DateTime(2026)),
      CameraPhoto(id: 'b', name: 'IMG_20260717_100100', sizeBytes: 1, timestamp: DateTime(2026)),
      CameraPhoto(id: 'c', name: 'IMG_20260717_100300', sizeBytes: 1, timestamp: DateTime(2026)),
    ];
    sortPhotosNewestFirst(photos);
    expect(photos.map((p) => p.name).toList(), [
      'IMG_20260717_100300',
      'VID_20260717_100200',
      'IMG_20260717_100100',
    ]);
  });
}
