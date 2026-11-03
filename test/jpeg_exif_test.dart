import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:camera_app/services/jpeg_exif.dart';

/// API v1.8 §时间模型: the exported file must carry the *capture* time, not the
/// export time. Edited photos are re-encoded and lose their metadata, so the app
/// re-attaches EXIF DateTimeOriginal.
void main() {
  Uint8List sampleJpeg() {
    final image = img.Image(width: 8, height: 8);
    img.fill(image, color: img.ColorRgb8(120, 140, 160));
    return Uint8List.fromList(img.encodeJpg(image));
  }

  test('formats the EXIF ASCII date the way camera makers do', () {
    expect(
      JpegExif.formatExifDate(DateTime(2026, 7, 17, 14, 30, 22)),
      '2026:07:17 14:30:22',
    );
    // Single digits are zero padded.
    expect(
      JpegExif.formatExifDate(DateTime(2026, 1, 2, 3, 4, 5)),
      '2026:01:02 03:04:05',
    );
  });

  test('a freshly encoded JPEG has no EXIF', () {
    expect(JpegExif.hasExif(sampleJpeg()), isFalse);
  });

  test('injects an Exif segment carrying the capture date', () {
    final original = sampleJpeg();
    final dated = JpegExif.ensureDateTimeOriginal(original, DateTime(2026, 7, 17, 14, 30, 22));

    expect(JpegExif.hasExif(dated), isTrue);
    // Still a JPEG, and bigger by exactly the new segment.
    expect(dated.sublist(0, 2), [0xFF, 0xD8]);
    expect(dated.length, greaterThan(original.length));
    // Image data after SOI is preserved byte-for-byte.
    expect(dated.sublist(dated.length - (original.length - 2)),
        original.sublist(2));

    // The date string is present, ASCII, NUL terminated.
    final ascii = String.fromCharCodes(dated);
    expect(ascii.contains('2026:07:17 14:30:22'), isTrue);
  });

  test('written structure is a valid EXIF SubIFD and the JPEG still decodes', () {
    final dated = JpegExif.ensureDateTimeOriginal(sampleJpeg(), DateTime(2026, 7, 17, 14, 30, 22));

    // A corrupted segment would break decoding for every JPEG consumer.
    expect(img.decodeJpg(dated), isNotNull,
        reason: 'injected segment must not break the image data');

    final tags = _readExifTags(dated);
    expect(tags['DateTimeOriginal'], '2026:07:17 14:30:22',
        reason: 'Photos/iOS reads tag 0x9003 from the Exif SubIFD');
    expect(tags['DateTimeDigitized'], '2026:07:17 14:30:22');
    expect(tags['DateTime'], '2026:07:17 14:30:22');
  });

  test('is idempotent — never double-injects', () {
    final first = JpegExif.ensureDateTimeOriginal(sampleJpeg(), DateTime(2026, 7, 17, 14, 30, 22));
    final second = JpegExif.ensureDateTimeOriginal(first, DateTime(2020, 1, 1, 0, 0, 0));

    expect(identical(first, second) || second.length == first.length, isTrue);
    // The original capture date is kept: the camera's own EXIF always wins.
    expect(String.fromCharCodes(second).contains('2026:07:17 14:30:22'), isTrue);
  });

  test('leaves non-JPEG data untouched', () {
    final png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4]);
    expect(JpegExif.ensureDateTimeOriginal(png, DateTime(2026, 1, 1)), same(png));
  });
}

/// Minimal EXIF reader used only by the tests: walks the APP1 segment, IFD0 and
/// the Exif SubIFD and returns the ASCII tags we care about.
Map<String, String> _readExifTags(Uint8List jpeg) {
  final bd = ByteData.sublistView(jpeg);
  var i = 2;
  int? tiff;
  while (i + 4 <= jpeg.length && jpeg[i] == 0xFF) {
    final marker = jpeg[i + 1];
    if (marker == 0xD8 || marker == 0x01) {
      i += 2;
      continue;
    }
    if (marker == 0xDA || marker == 0xD9) break;
    final len = bd.getUint16(i + 2, Endian.big);
    // NB: Dart has no `\0` string escape, so compare against explicit bytes.
    const exifHeader = [0x45, 0x78, 0x69, 0x66, 0x00, 0x00]; // "Exif\0\0"
    if (marker == 0xE1 &&
        _bytesEqual(jpeg.sublist(i + 4, i + 10), exifHeader)) {
      tiff = i + 10;
      break;
    }
    i += 2 + len;
  }
  final result = <String, String>{};
  if (tiff == null) return result;
  final base = tiff;

  final ifd0 = base + bd.getUint32(base + 4, Endian.little);
  final count0 = bd.getUint16(ifd0, Endian.little);
  int? exifIfd;
  for (var e = 0; e < count0; e++) {
    final at = ifd0 + 2 + e * 12;
    final tag = bd.getUint16(at, Endian.little);
    final value = bd.getUint32(at + 8, Endian.little);
    if (tag == 0x8769) exifIfd = base + value;
    if (tag == 0x0132) result['DateTime'] = _ascii(jpeg, base + value);
  }
  if (exifIfd != null) {
    final count = bd.getUint16(exifIfd, Endian.little);
    for (var e = 0; e < count; e++) {
      final at = exifIfd + 2 + e * 12;
      final tag = bd.getUint16(at, Endian.little);
      final value = bd.getUint32(at + 8, Endian.little);
      if (tag == 0x9003) result['DateTimeOriginal'] = _ascii(jpeg, base + value);
      if (tag == 0x9004) result['DateTimeDigitized'] = _ascii(jpeg, base + value);
    }
  }
  return result;
}

String _ascii(Uint8List b, int at) {
  var end = at;
  while (end < b.length && b[end] != 0) {
    end++;
  }
  return String.fromCharCodes(b.sublist(at, end));
}

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
