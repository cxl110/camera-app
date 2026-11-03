import 'package:flutter/foundation.dart';

/// Build-level switches for developer / field-service UI.
///
/// Two separate concerns, deliberately not one flag:
///
/// * **OTA tools** — the firmware-update button. Needed for factory / field
///   service builds, where flashing the camera from the app is the whole point.
/// * **Log tools** — uploading the on-device log to a PC, and dumping it to a
///   file. Never wanted outside development: it is a data-collection feature that
///   would have to be declared in App Privacy, for no user value.
///
/// Merging them (the original [kDevTools]) meant every field build also showed a
/// bug icon in the UI, which is not something to hand to a customer or a tester.
///
/// Enable per build:
///   --dart-define=OTA_TOOLS=true    firmware update UI
///   --dart-define=LOG_TOOLS=true    log upload / export UI
///   --dart-define=DEV_TOOLS=true    both (legacy, still honoured)
///
/// All operands are compile-time constants, so a store build tree-shakes these
/// branches out of the binary entirely — the widgets cannot be reachable at all.
const bool _devToolsEnv = bool.fromEnvironment('DEV_TOOLS');

/// Firmware-update UI (OTA). Enabled in debug, or with OTA_TOOLS/DEV_TOOLS.
const bool kOtaTools = kDebugMode || _devToolsEnv || bool.fromEnvironment('OTA_TOOLS');

/// Log upload / export UI. Enabled in debug, or with LOG_TOOLS/DEV_TOOLS.
const bool kLogTools = kDebugMode || _devToolsEnv || bool.fromEnvironment('LOG_TOOLS');

/// Anything developer-facing at all.
const bool kDevTools = kOtaTools || kLogTools;
