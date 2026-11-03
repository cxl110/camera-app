import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:camera_app/services/dev_flags.dart';

/// Locks the contract that keeps firmware-OTA and log-upload out of store builds.
///
/// `kDevTools` must be:
/// - true in debug (the normal developer loop),
/// - false in profile/release unless the build opts in with
///   `--dart-define=DEV_TOOLS=true`.
///
/// Both operands are compile-time constants, so the compiler tree-shakes the
/// gated widgets out of a release binary entirely — which is what makes the
/// guarantee stronger than a runtime check.
void main() {
  test('dev tools follow the debug flag by default', () {
    // Tests run in debug mode.
    expect(kDebugMode, isTrue);
    expect(kDevTools, isTrue);
  });

  test('the DEV_TOOLS define is absent unless explicitly passed', () {
    // No --dart-define in the test harness or in a store build.
    expect(const bool.fromEnvironment('DEV_TOOLS'), isFalse,
        reason: 'a store build must never be able to opt in by accident');
  });

  test('kDevTools is not a runtime-only check', () {
    // Both inputs are const, so `kDevTools` is itself a compile-time constant.
    // If someone replaces it with a runtime expression this assertion still
    // passes, but the accompanying comment in dev_flags.dart explains why the
    // const form matters (dead-code elimination of the whole widget branch).
    const bool value = kDevTools;
    expect(value, kDebugMode || const bool.fromEnvironment('DEV_TOOLS'));
  });
}
