#!/bin/sh
#
# Loads the five macOS signing secrets into this repository's GitHub Actions
# secret store, reading them from a local folder. Nothing is printed except the
# secret names, so the values never reach a terminal log. Run it once, then
# delete the folder.
#
#   sh scripts/set_github_secrets.sh [folder]      (default ~/Desktop/pauselet-signing)
#
# Expects in the folder:
#   cert.p12            Developer ID Application certificate, exported from
#                       Keychain Access (right-click the certificate, Export).
#   cert-password.txt   the password chosen at export, one line.
#   AuthKey_<ID>.p8     App Store Connect API key, downloaded once from
#                       appstoreconnect.apple.com → Users and Access →
#                       Integrations → App Store Connect API. Give the key the
#                       Developer role; notarization needs nothing more.
#   ids.txt             two lines: KEY_ID=<the key's ID> and ISSUER_ID=<uuid>,
#                       both shown on that same page.
#
# The workflow base64-decodes the certificate and the .p8; the other three are
# used as-is. Why all five: a signed but un-notarized Developer ID app is still
# blocked by Gatekeeper, so the release workflow insists on all five or none.
#
set -eu

D="${1:-$HOME/Desktop/pauselet-signing}"

for f in cert.p12 cert-password.txt ids.txt; do
  [ -f "$D/$f" ] || { echo "missing $D/$f" >&2; exit 1; }
done

PW="$(tr -d '\r\n' < "$D/cert-password.txt")"
KEY_ID="$(sed -n 's/^KEY_ID=//p' "$D/ids.txt" | tr -d '\r\n ')"
ISSUER="$(sed -n 's/^ISSUER_ID=//p' "$D/ids.txt" | tr -d '\r\n ')"
P8="$D/AuthKey_$KEY_ID.p8"

[ -n "$PW" ] || { echo "cert-password.txt is empty" >&2; exit 1; }
[ -n "$KEY_ID" ] && [ -n "$ISSUER" ] || { echo "ids.txt needs KEY_ID= and ISSUER_ID=" >&2; exit 1; }
[ -f "$P8" ] || { echo "missing $P8 (named after KEY_ID in ids.txt)" >&2; exit 1; }

base64 -i "$D/cert.p12" | gh secret set MACOS_CERT_P12
printf '%s' "$PW"       | gh secret set MACOS_CERT_PASSWORD
printf '%s' "$KEY_ID"   | gh secret set APPLE_API_KEY_ID
printf '%s' "$ISSUER"   | gh secret set APPLE_API_ISSUER_ID
base64 -i "$P8"         | gh secret set APPLE_API_KEY_P8

echo
gh secret list
echo
echo "All five set. Now delete the folder:  rm -rf \"$D\""
