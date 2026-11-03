import 'package:flutter_test/flutter_test.dart';

import 'package:camera_app/services/http_camera_protocol.dart';

/// Firmware version comparison.
///
/// A real bug lived here: the camera reported `fw_version = "dev"` (firmware built
/// without a version stamp), the parser returned null, and the old fallback
/// compared the raw strings. "dev" sorts after "V0.5-…" (0x64 > 0x56), so the app
/// concluded the camera was NEWER and never offered the update — a field unit
/// missing a fix would sit there forever with no prompt.
void main() {
  const bundled = 'V0.5-20261031';

  group('needsFirmwareUpdate', () {
    test('offers the update when the camera version is unknown ("dev")', () {
      expect(HttpCameraProtocol.needsFirmwareUpdate('dev', bundled), isTrue,
          reason: 'an unparseable version must not be treated as up to date');
    });

    test('offers the update when the camera reports nothing', () {
      expect(HttpCameraProtocol.needsFirmwareUpdate(null, bundled), isTrue);
      expect(HttpCameraProtocol.needsFirmwareUpdate('', bundled), isTrue);
    });

    test('no update when the versions match', () {
      expect(HttpCameraProtocol.needsFirmwareUpdate(bundled, bundled), isFalse);
    });

    test('older date -> update', () {
      expect(
        HttpCameraProtocol.needsFirmwareUpdate('V0.5-20260729', bundled),
        isTrue,
      );
    });

    test('newer date -> no update', () {
      expect(
        HttpCameraProtocol.needsFirmwareUpdate('V0.5-20261231', bundled),
        isFalse,
      );
    });

    test('minor bump wins over date', () {
      expect(
        HttpCameraProtocol.needsFirmwareUpdate('V0.4-20261231', bundled),
        isTrue,
      );
      expect(
        HttpCameraProtocol.needsFirmwareUpdate('V0.6-20260101', bundled),
        isFalse,
      );
    });

    test('major bump wins over minor', () {
      expect(
        HttpCameraProtocol.needsFirmwareUpdate('V1.0-20260101', bundled),
        isFalse,
      );
    });

    test('an unparseable bundled version never nags', () {
      expect(
        HttpCameraProtocol.needsFirmwareUpdate('V0.5-20260729', 'garbage'),
        isFalse,
      );
    });
  });
}
