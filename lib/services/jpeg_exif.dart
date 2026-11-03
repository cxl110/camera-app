import 'dart:typed_data';

/// Minimal JPEG EXIF date writer.
///
/// API v1.8 §时间模型: `/list` returns the **capture** time in `mtime`, and the
/// app must write that time into the exported file — file mtime *and* EXIF
/// `DateTimeOriginal` — or every photo lands on the same day in the system photo
/// library.
///
/// Editing a photo (filters, borders, upscale) re-encodes the JPEG and therefore
/// drops its metadata, so the exported bytes have no EXIF at all. This class
/// builds the smallest valid APP1/Exif segment that carries the three date tags
/// iOS Photos and Android MediaStore look at:
///
/// - `0x0132` `DateTime` (IFD0)
/// - `0x9003` `DateTimeOriginal` (Exif SubIFD)
/// - `0x9004` `DateTimeDigitized` (Exif SubIFD)
///
/// Deliberately conservative: only ever *injects* a segment when the JPEG has no
/// Exif APP1 yet, never rewrites an existing one, and returns the input untouched
/// on any unexpected structure. A photo must never fail to save because of this.
class JpegExif {
  JpegExif._();

  static const int _tagDateTime = 0x0132;
  static const int _tagExifIfd = 0x8769;
  static const int _tagDateTimeOriginal = 0x9003;
  static const int _tagDateTimeDigitized = 0x9004;

  /// Whether [bytes] is a JPEG carrying an Exif APP1 segment (we then leave the
  /// file's own capture date alone — it came from the camera).
  static bool hasExif(Uint8List bytes) {
    final segs = _segments(bytes);
    if (segs == null) return false;
    for (final s in segs) {
      if (s.marker == 0xE1 && s.isExif) return true;
    }
    return false;
  }

  /// Format a local time as the EXIF/ASCII date: `YYYY:MM:DD HH:MM:SS`.
  static String formatExifDate(DateTime t) {
    final l = t.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${l.year.toString().padLeft(4, '0')}:${two(l.month)}:${two(l.day)} '
        '${two(l.hour)}:${two(l.minute)}:${two(l.second)}';
  }

  /// Return [jpeg] with the capture date embedded, or [jpeg] itself when that is
  /// not possible (not a JPEG, already has EXIF, malformed).
  static Uint8List ensureDateTimeOriginal(Uint8List jpeg, DateTime capturedAt) {
    if (jpeg.length < 4) return jpeg;
    // SOI
    if (jpeg[0] != 0xFF || jpeg[1] != 0xD8) return jpeg;
    if (hasExif(jpeg)) return jpeg;

    try {
      final app1 = _buildApp1(capturedAt);
      final out = BytesBuilder(copy: false)
        ..add(Uint8List.fromList([0xFF, 0xD8]))
        ..add(app1)
        // Skip the original SOI and keep everything else byte-for-byte.
        ..add(Uint8List.sublistView(jpeg, 2));
      return out.toBytes();
    } catch (_) {
      return jpeg;
    }
  }

  // ── APP1 construction ──

  static Uint8List _buildApp1(DateTime capturedAt) {
    final date = formatExifDate(capturedAt); // 19 chars

    // TIFF layout (little endian, "II"):
    //   0  header        8 bytes
    //   8  IFD0         30 bytes (2 entries + next pointer)
    //  38  date1        20 bytes
    //  58  ExifIFD      30 bytes (2 entries + next pointer)
    //  88  date2        20 bytes
    // 108  date3        20 bytes
    const ifd0 = 8;
    const date1 = 38;
    const exifIfd = 58;
    const date2 = 88;
    const date3 = 108;
    const tiffLen = 128;

    final tiff = ByteData(tiffLen);

    // Header
    tiff.setUint8(0, 0x49); // 'I'
    tiff.setUint8(1, 0x49);
    tiff.setUint16(2, 42, Endian.little);
    tiff.setUint32(4, ifd0, Endian.little);

    // IFD0: ExifIFD pointer + DateTime
    tiff.setUint16(ifd0, 2, Endian.little);
    _entry(tiff, ifd0 + 2, _tagExifIfd, 4 /*LONG*/, 1, exifIfd);
    _entry(tiff, ifd0 + 14, _tagDateTime, 2 /*ASCII*/, 20, date1);
    tiff.setUint32(ifd0 + 26, 0, Endian.little); // no next IFD

    _writeAscii(tiff, date1, date);

    // Exif SubIFD
    tiff.setUint16(exifIfd, 2, Endian.little);
    _entry(tiff, exifIfd + 2, _tagDateTimeOriginal, 2, 20, date2);
    _entry(tiff, exifIfd + 14, _tagDateTimeDigitized, 2, 20, date3);
    tiff.setUint32(exifIfd + 26, 0, Endian.little);

    _writeAscii(tiff, date2, date);
    _writeAscii(tiff, date3, date);

    final payloadLen = 6 + tiffLen;
    final segmentLen = payloadLen + 2; // length field includes itself
    if (segmentLen > 0xFFFF) return Uint8List(0);

    final out = Uint8List(2 + 2 + payloadLen);
    out[0] = 0xFF;
    out[1] = 0xE1;
    out[2] = (segmentLen >> 8) & 0xFF;
    out[3] = segmentLen & 0xFF;
    out[4] = 0x45; // 'E'
    out[5] = 0x78; // 'x'
    out[6] = 0x69; // 'i'
    out[7] = 0x66; // 'f'
    out[8] = 0x00;
    out[9] = 0x00;
    out.setRange(10, 10 + tiffLen, tiff.buffer.asUint8List());
    return out;
  }

  static void _entry(ByteData d, int at, int tag, int type, int count, int valueOffset) {
    d.setUint16(at, tag, Endian.little);
    d.setUint16(at + 2, type, Endian.little);
    d.setUint32(at + 4, count, Endian.little);
    d.setUint32(at + 8, valueOffset, Endian.little);
  }

  static void _writeAscii(ByteData d, int at, String value) {
    final bytes = value.codeUnits; // ASCII only
    d.buffer.asUint8List().setRange(at, at + bytes.length, bytes);
    d.setUint8(at + bytes.length, 0); // NUL terminator
  }

  // ── JPEG segment walking ──

  /// Walk the marker segments between SOI and SOS. Returns null when the data
  /// does not look like a JPEG we understand.
  static List<_Segment>? _segments(Uint8List b) {
    if (b.length < 4 || b[0] != 0xFF || b[1] != 0xD8) return null;
    final out = <_Segment>[];
    var i = 2;
    while (i + 4 <= b.length) {
      if (b[i] != 0xFF) return null;
      var marker = b[i + 1];
      // Fill bytes (0xFF) are allowed before a marker.
      while (marker == 0xFF && i + 3 < b.length) {
        i++;
        marker = b[i + 1];
      }
      // Standalone markers without a length field.
      if (marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
        i += 2;
        continue;
      }
      if (marker == 0xDA || marker == 0xD9) break; // start of scan / end
      if (i + 3 >= b.length) return null;
      final len = (b[i + 2] << 8) | b[i + 3];
      if (len < 2 || i + 2 + len > b.length) return null;
      final start = i + 4;
      final end = i + 2 + len;
      final isExif = marker == 0xE1 &&
          end - start >= 6 &&
          b[start] == 0x45 &&
          b[start + 1] == 0x78 &&
          b[start + 2] == 0x69 &&
          b[start + 3] == 0x66 &&
          b[start + 4] == 0x00 &&
          b[start + 5] == 0x00;
      out.add(_Segment(marker, isExif));
      i = end;
    }
    return out;
  }
}

class _Segment {
  final int marker;
  final bool isExif;
  const _Segment(this.marker, this.isExif);
}
