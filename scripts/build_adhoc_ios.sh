#!/bin/bash
# Builds an installable iOS IPA with the Ad Hoc profile (both test devices).
#
#   bash scripts/build_adhoc_ios.sh               # store-like build, no dev UI
#   bash scripts/build_adhoc_ios.sh --ota         # field service: firmware update button only
#   bash scripts/build_adhoc_ios.sh --log         # debug: log upload/export buttons only
#   bash scripts/build_adhoc_ios.sh --dev-tools   # both
#
# OTA and log switches are separate on purpose: a field unit needs to flash the
# camera, but must not show a bug-report icon to whoever is holding it.
#
# Signing needs the login keychain, which an sshd session cannot reach
# (errSecInternalComponent). Run it through scripts/build_in_gui_session.sh to
# execute inside the GUI session.
#
# Why Ad Hoc instead of devicectl:
#   * iOS 16 devices (iPhone X) are unsupported by devicectl/CoreDevice;
#   * an ad-hoc profile pins the device UDIDs, so installs cannot fail with
#     "device not in provisioning profile";
#   * ad-hoc apps need no "trust this developer" step on the phone.
set -o pipefail
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
export PATH="$HOME/development/flutter/bin:/opt/homebrew/lib/ruby/gems/4.0.0/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

OTA_TOOLS=false
LOG_TOOLS=false
NO_MIRROR=false
for arg in "$@"; do
  case "$arg" in
    --ota)       OTA_TOOLS=true ;;
    --log)       LOG_TOOLS=true ;;
    --dev-tools) OTA_TOOLS=true; LOG_TOOLS=true ;;
    --no-mirror) NO_MIRROR=true ;;
    *) echo "unknown argument: $arg"; exit 2 ;;
  esac
done

cd "$HOME/camera_app" || exit 1
PBX=ios/Runner.xcodeproj/project.pbxproj
BAK=/tmp/pbxproj.adhoc.bak

# The provisioning profile must be scoped to the Runner target only. Passing it on
# the xcodebuild command line applies it to every target, and the CocoaPods
# frameworks (gal, share_plus, image_picker_ios, Pods-Runner) do not support
# provisioning profiles at all — the build dies with
# "gal does not support provisioning profiles".
cp -f "$PBX" "$BAK" || exit 1
cp -f pubspec.yaml /tmp/pubspec.build.bak || exit 1
trap 'cp -f "$BAK" "$PBX"; cp -f /tmp/pubspec.build.bak pubspec.yaml; echo "== pbxproj + pubspec restored =="' EXIT

# Firmware assets are NOT in pubspec by default (a store build must not carry
# device firmware). Field-service builds mount them for the duration of the build
# only, and fail loudly if the artifacts are missing.
if [ "$OTA_TOOLS" = true ]; then
  for f in assets/firmware/manifest.json assets/firmware/boot.img assets/firmware/rootfs.img; do
    [ -f "$f" ] || { echo "ERROR: $f is missing — run scripts/prepare_firmware_bundle.ps1 first"; exit 1; }
  done
  python3 - <<'PY'
path = 'pubspec.yaml'
src = open(path, encoding='utf-8').read()
marker = '    - assets/film_presets/\n'
if '    - assets/firmware/\n' not in src:
    src = src.replace(marker, marker + '    - assets/firmware/\n', 1)
    open(path, 'w', encoding='utf-8').write(src)
    print('pubspec: firmware assets mounted (field build)')
else:
    print('pubspec: firmware assets already mounted')
PY
fi

python3 - "$PBX" <<'PY'
import sys
path = sys.argv[1]
src = open(path, encoding='utf-8').read()
old = 'PROVISIONING_PROFILE_SPECIFIER = "CameraApp AppStore";'
new = 'PROVISIONING_PROFILE_SPECIFIER = "CameraApp AdHoc";'
if old not in src:
    raise SystemExit("could not find the App Store profile marker; aborting")
open(path, 'w', encoding='utf-8').write(src.replace(old, new, 1))
print("Release provisioning profile -> CameraApp AdHoc")
PY

DART_ARGS=()
PACK_SUFFIX=""
if [ "$OTA_TOOLS" = true ]; then
  DART_ARGS+=("--dart-define=OTA_TOOLS=true")
  PACK_SUFFIX="${PACK_SUFFIX}_ota"
  echo "== OTA tools enabled (firmware update button) =="
fi
if [ "$NO_MIRROR" = true ]; then
  DART_ARGS+=("--dart-define=MIRROR_CAMERA=false")
  PACK_SUFFIX="${PACK_SUFFIX}_nomirror"
  echo "== app-side mirroring DISABLED (camera corrects the picture itself) =="
fi
if [ "$LOG_TOOLS" = true ]; then
  DART_ARGS+=("--dart-define=LOG_TOOLS=true")
  PACK_SUFFIX="${PACK_SUFFIX}_log"
  echo "== log tools enabled (upload / export buttons) =="
fi

echo ""
echo "== generating release config =="
# --dart-define lands in ios/Flutter/Generated.xcconfig and the Flutter build
# phase reads DART_DEFINES from there. Do NOT pass DART_DEFINES on the xcodebuild
# command line: it must be a comma-separated list of base64 chunks, and
# hand-encoding it silently produces a build where the define is ignored.
flutter build ios --config-only --release "${DART_ARGS[@]}" > /tmp/cfg_adhoc.log 2>&1
echo "config-only=$?"
VER=$(grep FLUTTER_BUILD_NAME ios/Flutter/Generated.xcconfig | cut -d= -f2)
BUILD=$(grep FLUTTER_BUILD_NUMBER ios/Flutter/Generated.xcconfig | cut -d= -f2)
echo "version: $VER ($BUILD)"

echo ""
echo "== building =="
rm -rf /tmp/dd_adhoc
xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner -configuration Release \
  -destination "generic/platform=iOS" -derivedDataPath /tmp/dd_adhoc \
  build > /tmp/adhoc_build.log 2>&1
echo "xcodebuild exit=$?"
grep -nE "error:" /tmp/adhoc_build.log | head -n 5
tail -n 3 /tmp/adhoc_build.log

APP=/tmp/dd_adhoc/Build/Products/Release-iphoneos/Runner.app
# Check the product, not just the directory: a failed build leaves a partial .app
# behind, which previously produced an 8 KB "IPA" reported as success.
if [ ! -x "$APP/Runner" ] || [ ! -f "$APP/Info.plist" ]; then
  echo "RESULT=BUILD_FAILED (no complete Runner.app — see /tmp/adhoc_build.log)"
  exit 1
fi

echo ""
echo "== verify =="
plutil -p "$APP/Info.plist" | grep -E 'CFBundleDisplayName|CFBundleShortVersionString|CFBundleVersion'
codesign -dv "$APP" 2>&1 | grep -iE "Authority" | head -n 2
security cms -D -i "$APP/embedded.mobileprovision" > /tmp/adhoc.plist 2>/dev/null
python3 - <<'PY'
import plistlib
p = plistlib.load(open('/tmp/adhoc.plist', 'rb'))
print("profile:", p.get('Name'))
for d in p.get('ProvisionedDevices', []):
    print("  device:", d)
PY
ASSETS="$APP/Frameworks/App.framework/flutter_assets/assets/firmware"
echo "firmware assets: $(ls "$ASSETS" 2>/dev/null | tr '\n' ' ')"
echo "OTA strings in binary: $(strings "$APP/Frameworks/App.framework/App" 2>/dev/null | grep -c 'Firmware update')"

echo ""
echo "== packaging =="
OUT="/tmp/ipa_adhoc/CameraApp_adhoc_v${BUILD}${PACK_SUFFIX}.ipa"
rm -rf /tmp/ipa_adhoc && mkdir -p /tmp/ipa_adhoc/Payload
cp -R "$APP" /tmp/ipa_adhoc/Payload/
( cd /tmp/ipa_adhoc && zip -qry "$(basename "$OUT")" Payload )
ls -lh "$OUT"
echo ""
echo "RESULT=IPA_READY $OUT"
