#!/bin/sh
#
# Notarizes the signed Pauselet.app: sends the zip to Apple, waits for the
# verdict, staples the ticket onto the .app so Gatekeeper trusts it offline,
# then rebuilds the zip.
#
# Notarization matters for more than Gatekeeper warnings: macOS refuses to grant
# notification authorization to an app it does not fully trust, so without this
# the Normal and Important tiers fall back to the app's own card instead of
# posting real system notifications.
#
# Takes the app and the zip to submit, so the build is a separate step and this
# works the same on a laptop and on a CI runner:
#
#   ./scripts/build_app.sh                       # or with SIGN_IDENTITY set
#   ditto -c -k --keepParent dist/Pauselet.app dist/Pauselet-1.0.0.zip
#   ./scripts/notarize.sh dist/Pauselet.app dist/Pauselet-1.0.0.zip
#
# Two ways to authenticate, chosen by what is set in the environment:
#
#   Locally — a stored keychain profile. One-time setup (create an
#   app-specific password at https://appleid.apple.com):
#
#     xcrun notarytool store-credentials "reminder-notary" \
#       --apple-id "you@example.com" \
#       --team-id "4R94388LH8" \
#       --password "xxxx-xxxx-xxxx-xxxx"
#
#   In CI — an App Store Connect API key, from the five GitHub secrets that
#   scripts/set_github_secrets.sh uploads:
#
#     APPLE_API_KEY_PATH=.../AuthKey.p8 APPLE_API_KEY_ID=... \
#       APPLE_API_ISSUER_ID=... ./scripts/notarize.sh <app> <zip>
#
# On rejection, prints Apple's log — it names the offending file — and fails.
#
set -eu

cd "$(dirname "$0")/.."

APP="${1:-dist/Pauselet.app}"
ZIP="${2:-dist/Pauselet.zip}"

[ -d "$APP" ] || { echo "notarize.sh: no app bundle at $APP" >&2; exit 1; }
[ -f "$ZIP" ] || { echo "notarize.sh: no zip at $ZIP" >&2; exit 1; }

if [ -n "${APPLE_API_KEY_PATH:-}" ]; then
  : "${APPLE_API_KEY_ID:?APPLE_API_KEY_PATH is set, so APPLE_API_KEY_ID must be too}"
  : "${APPLE_API_ISSUER_ID:?APPLE_API_KEY_PATH is set, so APPLE_API_ISSUER_ID must be too}"
  AUTH="--key $APPLE_API_KEY_PATH --key-id $APPLE_API_KEY_ID --issuer $APPLE_API_ISSUER_ID"
  echo "==> Authenticating with an App Store Connect API key"
else
  AUTH="--keychain-profile ${NOTARY_PROFILE:-reminder-notary}"
  echo "==> Authenticating with the ${NOTARY_PROFILE:-reminder-notary} keychain profile"
fi

echo "==> Submitting to Apple (this usually takes a few minutes)"
# Capture the exit status separately: under `set -e` a failing command
# substitution in a plain assignment would abort here, before Apple's output
# (the whole point of capturing it) had a chance to be printed.
rc=0
out="$(xcrun notarytool submit "$ZIP" $AUTH --wait --timeout 30m 2>&1)" || rc=$?
echo "$out"
id="$(echo "$out" | sed -n 's/^ *id: //p' | head -1)"
if [ "$rc" -ne 0 ] || ! echo "$out" | grep -q '^ *status: Accepted'; then
  [ -n "$id" ] && { xcrun notarytool log "$id" $AUTH || true; }
  echo "notarize.sh: Apple did not accept the app (notarytool exit $rc)" >&2
  exit 1
fi

echo "==> Stapling the ticket to the app"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

# Stapling changes the bundle, so the zip that was submitted no longer matches
# what ships. Rebuild it from the stapled app. ditto has to run from the app's
# parent for --keepParent to record the bundle at the top of the archive, so
# resolve the zip to an absolute path first rather than assuming it sits in the
# same directory as the app.
echo "==> Re-zipping the stapled app"
ZIP_DIR="$(cd "$(dirname "$ZIP")" && pwd)"
ZIP_ABS="$ZIP_DIR/$(basename "$ZIP")"
rm -f "$ZIP_ABS"
( cd "$(dirname "$APP")" && ditto -c -k --keepParent "$(basename "$APP")" "$ZIP_ABS" )

echo "==> Verifying"
spctl -a -vv "$APP"

echo
echo "notarize.sh: notarized, stapled and re-zipped $ZIP"
