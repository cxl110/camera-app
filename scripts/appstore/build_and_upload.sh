#!/bin/bash
# Archive, export and upload the App Store build for SQ Cam.
#
#   bash scripts/appstore/build_and_upload.sh            # archive + export + upload
#   bash scripts/appstore/build_and_upload.sh --no-upload # stop after the .ipa
#
# Must run inside the GUI login session (scripts/build_in_gui_session.sh style):
# signing needs the login keychain, which an sshd session cannot reach.
#
# Preconditions checked below, because each one silently produces a rejected or
# wrong build:
#   * no firmware assets in pubspec (a store build must not carry device firmware)
#   * Release configuration signs with the App Store profile, not Ad Hoc
#   * CFBundleShortVersionString matches the version record in App Store Connect
set -o pipefail
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
export PATH="$HOME/development/flutter/bin:/opt/homebrew/lib/ruby/gems/4.0.0/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

UPLOAD=true
[ "${1:-}" = "--no-upload" ] && UPLOAD=false

KEY_ID=C5LL8Z7QYM
ISSUER=979a8469-69a2-461d-a324-f8cece66b002

cd "$HOME/camera_app" || exit 1

echo "== preflight =="
if grep -q '^\s*- assets/firmware/' pubspec.yaml; then
  echo "ERROR: pubspec still lists assets/firmware — a store build must not bundle firmware"
  exit 1
fi
echo "  firmware assets: not bundled"

if grep -q 'PROVISIONING_PROFILE_SPECIFIER = "CameraApp AdHoc";' ios/Runner.xcodeproj/project.pbxproj; then
  echo "ERROR: Release is still pointed at the Ad Hoc profile; restore the App Store profile first"
  exit 1
fi
echo "  signing profile: $(grep -o 'PROVISIONING_PROFILE_SPECIFIER = "[^"]*"' ios/Runner.xcodeproj/project.pbxproj | head -1)"

VER=$(grep -m1 '^version:' pubspec.yaml | awk '{print $2}')
echo "  pubspec version: $VER"

echo ""
echo "== archive =="
rm -rf build/ios/archive build/ios/ipa
# `flutter build ipa` archives and then tries to export. With MANUAL signing the
# ExportOptions it generates has no provisioningProfiles mapping, so the export
# step dies with 'exportArchive "Runner.app" requires a provisioning profile'
# even though the archive itself is fine. We archive here and export ourselves.
flutter build ipa --release > /tmp/ipa_build.log 2>&1
rc=$?
ARCHIVE=build/ios/archive/Runner.xcarchive
if [ ! -d "$ARCHIVE" ]; then
  echo "archive missing (flutter exit=$rc)"
  grep -nE "error:|Failed|Provisioning" /tmp/ipa_build.log | head -n 15
  echo "RESULT=BUILD_FAILED (see /tmp/ipa_build.log)"
  exit 1
fi
echo "archive: $ARCHIVE ($(du -sh "$ARCHIVE" | cut -f1))"

echo ""
echo "== export ipa (explicit ExportOptions) =="
mkdir -p build/ios/ipa
EXPORT_PLIST=/tmp/ExportOptions.plist
cat > "$EXPORT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>signingStyle</key><string>manual</string>
  <key>teamID</key><string>J743J48L89</string>
  <key>uploadSymbols</key><true/>
  <key>destination</key><string>export</string>
  <key>provisioningProfiles</key>
  <dict>
    <key>com.zivigo.cameraapp</key>
    <string>CameraApp AppStore</string>
  </dict>
</dict>
</plist>
PLIST

xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$EXPORT_PLIST" -exportPath build/ios/ipa \
  -allowProvisioningUpdates > /tmp/ipa_export.log 2>&1
echo "exportArchive exit=$?"
if ! grep -q "EXPORT SUCCEEDED" /tmp/ipa_export.log; then
  echo "-- export log --"
  grep -nE "error:|Error|requires a provisioning|No profiles" /tmp/ipa_export.log | head -n 10
  tail -n 6 /tmp/ipa_export.log
  echo "RESULT=EXPORT_FAILED (see /tmp/ipa_export.log)"
  exit 1
fi

IPA=$(ls -t build/ios/ipa/*.ipa 2>/dev/null | head -1)
[ -n "$IPA" ] || { echo "RESULT=NO_IPA"; exit 1; }
echo "ipa: $IPA ($(du -h "$IPA" | cut -f1))"

echo ""
echo "== verify =="
TMP=$(mktemp -d)
unzip -q "$IPA" -d "$TMP"
APP=$(find "$TMP/Payload" -maxdepth 1 -name '*.app' | head -1)
plutil -p "$APP/Info.plist" | grep -E 'CFBundleDisplayName|CFBundleShortVersionString|CFBundleVersion|ITSAppUsesNonExemptEncryption'
if [ -d "$APP/Frameworks/App.framework/flutter_assets/assets/firmware" ]; then
  echo "ERROR: firmware leaked into the store build"
  exit 1
fi
echo "  firmware assets: absent (good)"
security cms -D -i "$APP/embedded.mobileprovision" > "$TMP/p.plist" 2>/dev/null
python3 - "$TMP/p.plist" <<'PY'
import plistlib, sys
p = plistlib.load(open(sys.argv[1], 'rb'))
print("  profile:", p.get('Name'))
ent = p.get('Entitlements', {})
print("  beta-reports-active:", ent.get('beta-reports-active'), "| get-task-allow:", ent.get('get-task-allow'))
PY
rm -rf "$TMP"

if [ "$UPLOAD" = false ]; then
  echo ""
  echo "RESULT=IPA_READY $IPA"
  exit 0
fi

echo ""
echo "== upload to App Store Connect =="
xcrun altool --upload-app -f "$IPA" --type ios \
  --apiKey "$KEY_ID" --apiIssuer "$ISSUER" 2>&1 | tee /tmp/ipa_upload.log | tail -n 8
if grep -qiE "UPLOAD SUCCEEDED|No errors uploading" /tmp/ipa_upload.log; then
  echo ""
  echo "RESULT=UPLOADED $IPA"
  echo "next: wait for processing, then attach the build to the version"
else
  echo "RESULT=UPLOAD_FAILED (see /tmp/ipa_upload.log)"
  exit 1
fi
