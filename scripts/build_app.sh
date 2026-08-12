#!/bin/bash
#
# Builds Pauselet.app from the SwiftPM executable.
#
# SwiftPM produces a bare binary, but a menu bar app needs a real bundle: an
# Info.plist (for LSUIElement, notification permissions, and the icon) and a
# code signature (so macOS will grant it notification access persistently).
#
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP="dist/Pauselet.app"
BUNDLE_ID="com.pauselet.pauselet"
VERSION="1.2.0"

# Your Apple Team ID. Used when signing with a Developer ID certificate;
# ignored for the default ad-hoc signature.
TEAM_ID="${TEAM_ID:-4R94388LH8}"

echo "==> Building ($CONFIG)"
swift build -c "$CONFIG" --product ReminderApp

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

BIN_PATH="$(swift build -c "$CONFIG" --product ReminderApp --show-bin-path)"
cp "$BIN_PATH/ReminderApp" "$APP/Contents/MacOS/Pauselet"

# The SwiftPM resource bundle carries the icons.
if [ -d "$BIN_PATH/Reminder_ReminderApp.bundle" ]; then
  cp -R "$BIN_PATH/Reminder_ReminderApp.bundle" "$APP/Contents/Resources/"
fi

# Icons also go at the top level of Resources, where NSImage(named:) and the
# Finder look for them.
cp Sources/ReminderApp/Resources/AppIcon.icns "$APP/Contents/Resources/" 2>/dev/null || true
cp Sources/ReminderApp/Resources/MenuBarIconTemplate*.png "$APP/Contents/Resources/" 2>/dev/null || true

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Pauselet</string>
  <key>CFBundleDisplayName</key><string>Pauselet</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleExecutable</key><string>Pauselet</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <!-- Menu bar only: no Dock icon, no app switcher entry. -->
  <key>LSUIElement</key><true/>
  <!-- Shown in the macOS consent prompt when a reminder first drives Spotify.
       Without this key a hardened-runtime app is killed on its first Apple
       event instead of being allowed to ask. Together with the automation
       entitlement below, this is all that gates Apple events on macOS. -->
  <key>NSAppleEventsUsageDescription</key>
  <string>Pauselet uses this to start your chosen Spotify playlist when a reminder fires.</string>
  <key>NSHumanReadableCopyright</key><string>Local-only reminder app.</string>
</dict>
</plist>
PLIST

echo "==> Signing"
# The hardened runtime blocks Apple events unless the app carries this
# entitlement, which is what lets a reminder drive Spotify on a notarized build.
# Use the path mktemp created; appending a suffix would write to a file it
# never made and leak the empty one it did.
ENTITLEMENTS="$(mktemp -t pauselet-entitlements)"
cat > "$ENTITLEMENTS" <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.automation.apple-events</key><true/>
</dict>
</plist>
ENT
trap 'rm -f "$ENTITLEMENTS"' EXIT

# Default to an ad-hoc signature so the app runs locally with no certificate.
# Set SIGN_IDENTITY to a "Developer ID Application: ..." identity to sign for
# distribution to other machines.
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
if [ "$SIGN_IDENTITY" = "-" ]; then
  codesign --force --deep --entitlements "$ENTITLEMENTS" --sign - "$APP"
  echo "    ad-hoc signed (local use only)"
else
  codesign --force --deep --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$APP"
  echo "    signed with: $SIGN_IDENTITY (team $TEAM_ID)"
fi

echo "==> Built $APP"
