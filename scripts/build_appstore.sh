#!/bin/bash
#
# Builds Pauselet.pkg for the Mac App Store.
#
# This is the store variant of build_app.sh, and the differences are not
# cosmetic. The store requires the App Sandbox, forbids the hardened runtime,
# wants an embedded provisioning profile, and accepts a signed installer
# package rather than a zipped app. The Developer ID build in build_app.sh is
# a different channel and stays as it is: that one is notarized and keeps the
# hardened runtime, this one must not.
#
# Prerequisites, all one-time (see docs/mac-app-store-steps.md):
#   - "Apple Distribution" and "3rd Party Mac Developer Installer"
#     certificates in the login keychain.
#   - signing/Pauselet_Mac_App_Store.provisionprofile, downloaded from the
#     developer portal. It expires yearly.
#
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP="dist/Pauselet.app"
PKG="dist/Pauselet.pkg"
BUNDLE_ID="com.pauselet.pauselet"
TEAM_ID="${TEAM_ID:-4R94388LH8}"
VERSION="${VERSION:-$(tr -d '[:space:]' < VERSION)}"
PROFILE="${PROFILE:-signing/Pauselet_Mac_App_Store.provisionprofile}"

APP_IDENTITY="${APP_IDENTITY:-Apple Distribution: Christian Venter ($TEAM_ID)}"
PKG_IDENTITY="${PKG_IDENTITY:-3rd Party Mac Developer Installer: Christian Venter ($TEAM_ID)}"

# SANDBOX_TEST=1 builds the store variant with the sandbox entitlements but a
# Developer ID signature, so it will actually launch on this Mac. A real store
# build cannot: macOS refuses to run something signed for store distribution,
# which makes it impossible to find out whether the sandbox breaks the app
# until a reviewer does. This mode exists to answer that question first.
# It produces no .pkg and must never be uploaded.
SANDBOX_TEST="${SANDBOX_TEST:-0}"
if [ "$SANDBOX_TEST" = "1" ]; then
  APP_IDENTITY="${SANDBOX_TEST_IDENTITY:-Developer ID Application: Christian Venter ($TEAM_ID)}"
fi

# Spotify playback is kept in the store build. It needs a temporary exception
# because the sandbox otherwise blocks Apple events, and App Review wants that
# justified in writing; the text is in docs/mac-app-store-steps.md step 9.
# Set SPOTIFY=0 to build without it, which is the fallback if review rejects
# the entitlement.
SPOTIFY="${SPOTIFY:-1}"

echo "==> Checking prerequisites"
IDENTITIES_NEEDED="$APP_IDENTITY"
[ "$SANDBOX_TEST" = "1" ] || IDENTITIES_NEEDED="$APP_IDENTITY
$PKG_IDENTITY"
IFS='
'
for identity in $IDENTITIES_NEEDED; do
  unset IFS
  if ! security find-identity -v | grep -qF "$identity"; then
    echo "    missing certificate: $identity" >&2
    echo "    see docs/mac-app-store-steps.md step 1" >&2
    exit 1
  fi
done
unset IFS
if [ "$SANDBOX_TEST" = "1" ]; then
  echo "    SANDBOX_TEST: sandboxed, Developer ID signed, runs locally, do not upload"
fi
if [ "$SANDBOX_TEST" != "1" ] && [ ! -f "$PROFILE" ]; then
  echo "    missing provisioning profile: $PROFILE" >&2
  echo "    see docs/mac-app-store-steps.md step 3" >&2
  exit 1
fi
# A profile that has expired produces an upload rejection rather than a build
# failure, so it is worth catching here.
PROFILE_EXPIRY="$(security cms -D -i "$PROFILE" 2>/dev/null \
  | plutil -extract ExpirationDate raw - 2>/dev/null || true)"
if [ -n "$PROFILE_EXPIRY" ]; then
  echo "    profile expires $PROFILE_EXPIRY"
fi

echo "==> Building ($CONFIG, version $VERSION)"
swift build -c "$CONFIG" --product ReminderApp

echo "==> Assembling bundle"
rm -rf "$APP" "$PKG"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

BIN_PATH="$(swift build -c "$CONFIG" --product ReminderApp --show-bin-path)"
cp "$BIN_PATH/ReminderApp" "$APP/Contents/MacOS/Pauselet"

if [ -d "$BIN_PATH/Reminder_ReminderApp.bundle" ]; then
  cp -R "$BIN_PATH/Reminder_ReminderApp.bundle" "$APP/Contents/Resources/"
fi
cp Sources/ReminderApp/Resources/AppIcon.icns "$APP/Contents/Resources/" 2>/dev/null || true
cp Sources/ReminderApp/Resources/MenuBarIconTemplate*.png "$APP/Contents/Resources/" 2>/dev/null || true

# The store requires a build number higher than every earlier upload's, and
# it compares them as numbers across versions, not per version: 1.0.0 went up
# again as build 2, after which "1.1.0" was rejected as lower. So it is the
# commit count from scripts/version.sh, the same number the iOS build uses,
# which only goes up. CFBundleShortVersionString stays the marketing version.
# BUILD_NUMBER still overrides it.
if [ -z "${BUILD_NUMBER:-}" ]; then
  eval "$(sh scripts/version.sh)"
fi

SPOTIFY_USAGE=""
if [ "$SPOTIFY" = "1" ]; then
  SPOTIFY_USAGE='  <key>NSAppleEventsUsageDescription</key>
  <string>Pauselet uses this to start your chosen Spotify playlist when a reminder fires.</string>'
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Pauselet</string>
  <key>CFBundleDisplayName</key><string>Pauselet</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleExecutable</key><string>Pauselet</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.healthcare-fitness</string>
  <!-- Menu bar only: no Dock icon, no app switcher entry. -->
  <key>LSUIElement</key><true/>
$SPOTIFY_USAGE
  <key>NSHumanReadableCopyright</key><string>2026 Chris Venter</string>
  <!-- Declared false so no export compliance question is asked per upload. -->
  <key>ITSAppUsesNonExemptEncryption</key><false/>
</dict>
</plist>
PLIST

if [ "$SANDBOX_TEST" = "1" ]; then
  echo "==> Skipping provisioning profile (test build)"
else
  echo "==> Embedding provisioning profile"
  cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
fi

# Apple rejects an upload if any file in the package carries an extended
# attribute, and a profile downloaded through a browser arrives tagged with
# com.apple.quarantine plus provenance and where-from metadata. `cp` copies
# those across, so strip the whole bundle rather than just the profile:
# resources dragged in from a download are just as capable of carrying them.
# This must happen before signing, since changing attributes afterwards
# invalidates the signature.
echo "==> Stripping extended attributes"
xattr -cr "$APP"
if find "$APP" -exec sh -c 'xattr "$1" 2>/dev/null | grep -q .' _ {} \; -print 2>/dev/null | grep -q .; then
  echo "    extended attributes remain; the upload would be rejected (91109)" >&2
  find "$APP" -exec sh -c 'xattr "$1" 2>/dev/null | grep -q . && echo "      $1"' _ {} \; >&2
  exit 1
fi

echo "==> Signing app"
# The sandbox is mandatory for the store. The application-identifier and
# team-identifier keys must match the provisioning profile exactly, and a
# missing application-identifier is the most common upload rejection.
#
# No --options runtime: the hardened runtime and the store are mutually
# exclusive. No --deep either; it is deprecated and signs nested code with the
# wrong entitlements.
ENTITLEMENTS="$(mktemp -t pauselet-store-entitlements)"
trap 'rm -f "$ENTITLEMENTS"' EXIT

{
  cat <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.app-sandbox</key><true/>
ENT
  if [ "$SANDBOX_TEST" != "1" ]; then
    # A Developer ID signature cannot claim these: they have to match a
    # provisioning profile, and the test build has none.
    cat <<ENT
  <key>com.apple.application-identifier</key><string>$TEAM_ID.$BUNDLE_ID</string>
  <key>com.apple.developer.team-identifier</key><string>$TEAM_ID</string>
ENT
  fi
  if [ "$SPOTIFY" = "1" ]; then
    cat <<'ENT'
  <!-- Spotify declares no scripting access groups, so scripting-targets
       cannot be used and this exception is the only route. Justified to App
       Review in docs/mac-app-store-steps.md step 9. -->
  <key>com.apple.security.temporary-exception.apple-events</key>
  <array><string>com.spotify.client</string></array>
ENT
  fi
  cat <<'ENT'
</dict>
</plist>
ENT
} > "$ENTITLEMENTS"

if [ "$SANDBOX_TEST" = "1" ]; then
  # The hardened runtime is what a Developer ID build normally carries, and
  # keeping it here makes the test closer to the shipping direct download.
  codesign --force --timestamp --options runtime \
    --entitlements "$ENTITLEMENTS" --sign "$APP_IDENTITY" "$APP"
else
  codesign --force --timestamp --entitlements "$ENTITLEMENTS" \
    --sign "$APP_IDENTITY" "$APP"
fi

echo "==> Verifying signature"
codesign --verify --strict --verbose=2 "$APP"
if [ "$SANDBOX_TEST" != "1" ] && ! codesign -d --entitlements - --xml "$APP" 2>/dev/null \
    | plutil -convert xml1 -o - - | grep -q 'com.apple.application-identifier'; then
  echo "    application-identifier entitlement missing; upload would be rejected" >&2
  exit 1
fi

if [ "$SANDBOX_TEST" = "1" ]; then
  cat <<DONE

Built $APP sandboxed and Developer ID signed.

Launch it and exercise the app: add a reminder, let one fire, open Settings,
check the data file. Watch for sandbox denials with:

  log stream --predicate 'sender == "Sandbox"' --style compact

Its data lives in the container, not Application Support:
  ~/Library/Containers/$BUNDLE_ID/Data/Library/Application Support/Pauselet/

Do not upload this build. Run without SANDBOX_TEST for the real package.
DONE
  exit 0
fi

echo "==> Building installer package"
productbuild --component "$APP" /Applications \
  --sign "$PKG_IDENTITY" \
  "$PKG"

echo "==> Verifying package"
pkgutil --check-signature "$PKG" | head -3

cat <<DONE

Built $PKG  (version $VERSION, build $BUILD_NUMBER)

Next: open Transporter, sign in, drag in $PKG, press Verify, then Deliver.
Xcode's Organizer cannot upload this because the app is built by SwiftPM
rather than from an Xcode project. See docs/mac-app-store-steps.md step 8.
DONE
