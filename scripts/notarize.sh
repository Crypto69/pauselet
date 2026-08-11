#!/bin/bash
#
# Signs, notarizes and staples Reminder.app.
#
# Notarization matters for more than Gatekeeper warnings: macOS refuses to grant
# notification authorization to an app it does not fully trust, so without this
# the Normal and Important tiers fall back to the app's own card instead of
# posting real system notifications.
#
# One-time setup — store an app-specific password (create one at
# https://appleid.apple.com under "App-Specific Passwords"):
#
#   xcrun notarytool store-credentials "reminder-notary" \
#     --apple-id "you@example.com" \
#     --team-id "4R94388LH8" \
#     --password "xxxx-xxxx-xxxx-xxxx"
#
# Then:  ./scripts/notarize.sh
#
set -euo pipefail

cd "$(dirname "$0")/.."

PROFILE="${NOTARY_PROFILE:-reminder-notary}"
TEAM_ID="${TEAM_ID:-4R94388LH8}"
IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Christian Venter ($TEAM_ID)}"
APP="dist/Reminder.app"
ZIP="dist/Reminder.zip"

echo "==> Building and signing with a hardened runtime"
SIGN_IDENTITY="$IDENTITY" ./scripts/build_app.sh

echo "==> Zipping for submission"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Submitting to Apple (this usually takes a few minutes)"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

echo "==> Stapling the ticket to the app"
xcrun stapler staple "$APP"

echo "==> Verifying"
xcrun stapler validate "$APP"
spctl -a -vv "$APP"

echo
echo "Done. Install with:"
echo "  rm -rf /Applications/Reminder.app && cp -R $APP /Applications/"
