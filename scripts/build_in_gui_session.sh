#!/bin/bash
# Runs an iOS build inside the GUI login session.
#
#   bash scripts/build_in_gui_session.sh --dev-tools      # field-service build
#   bash scripts/build_in_gui_session.sh                  # store-style build
#
# Why this exists
# ---------------
# `codesign` from an sshd session cannot use the login keychain:
#
#   Failed to codesign .../Flutter.framework/Flutter: errSecInternalComponent
#
# macOS isolates sshd sessions from the GUI security session, so the private keys
# in login.keychain-db are unreachable no matter that the keychain is unlocked in
# the GUI. The usual workaround is "run it yourself in Terminal", which defeats
# the point of driving the build remotely.
#
# Instead, this registers a LaunchAgent in the `gui/<uid>` domain and kickstarts
# it. A job started there belongs to the logged-in GUI session, so codesign works
# exactly as it does in Terminal — no password, no manual step.
set -euo pipefail
export LANG=en_US.UTF-8

REPO="$(cd "$(dirname "$0")/.." && pwd)"
LABEL="com.zivigo.buildagent"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG=/tmp/gui_build.log
ARGS=("$@")

mkdir -p "$HOME/Library/LaunchAgents"

# Write the runner with the arguments baked in: a LaunchAgent cannot receive
# arguments from whoever kickstarts it.
RUNNER=/tmp/zivigo_gui_build.sh
{
  echo '#!/bin/bash'
  echo 'export LANG=en_US.UTF-8'
  echo 'export LC_ALL=en_US.UTF-8'
  echo 'export PATH="'"$HOME"'/development/flutter/bin:/opt/homebrew/lib/ruby/gems/4.0.0/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"'
  echo "cd '$REPO' || exit 1"
  echo "echo \"=== gui build start \$(date) ===\""
  printf 'bash scripts/build_adhoc_ios.sh'
  for a in "${ARGS[@]}"; do printf ' %q' "$a"; done
  echo
  echo 'echo "=== gui build end $(date) ==="'
} > "$RUNNER"
chmod +x "$RUNNER"

cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$RUNNER</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>StandardOutPath</key><string>$LOG</string>
    <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
PLIST_EOF

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
rm -f "$LOG"
launchctl kickstart -p "gui/$(id -u)/$LABEL"

echo "build started in the GUI session; log: $LOG"
echo "follow with: tail -f $LOG"
