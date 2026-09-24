#!/bin/sh
# Puts the Google OAuth client into the app's Info.plist for a CI or release build, from the
# GOOGLE_OAUTH_CLIENT_ID and GOOGLE_OAUTH_CLIENT_SECRET environment variables.
#
# The Google sign-in URL scheme is added beside the URL types the plist already declares, such
# as mailto, which makes FalconMail a choice for the default mail app; it never takes their
# place. Run twice on the same plist, it adds the scheme once.
#
# Usage: scripts/embed-google-client.sh [path/to/Info.plist]
set -eu

PLIST="${1:-App/FalconMail/Info.plist}"

if [ -z "${GOOGLE_OAUTH_CLIENT_ID:-}" ]; then
  echo "::warning::GOOGLE_OAUTH_CLIENT_ID secret is not set; this build has no Google sign-in"
  exit 0
fi

plutil -replace FalconGoogleClientID -string "$GOOGLE_OAUTH_CLIENT_ID" "$PLIST"
plutil -replace FalconGoogleClientSecret -string "${GOOGLE_OAUTH_CLIENT_SECRET:-}" "$PLIST"

PREFIX="${GOOGLE_OAUTH_CLIENT_ID%.apps.googleusercontent.com}"
SCHEME="com.googleusercontent.apps.$PREFIX"

if ! plutil -extract CFBundleURLTypes raw "$PLIST" >/dev/null 2>&1; then
  plutil -insert CFBundleURLTypes -array "$PLIST"
fi
if plutil -extract CFBundleURLTypes json -o - "$PLIST" | grep -q "\"$SCHEME\""; then
  echo "Google sign-in URL scheme $SCHEME was already there"
else
  plutil -insert CFBundleURLTypes -json "{\"CFBundleURLName\":\"Google Sign-In\",\"CFBundleURLSchemes\":[\"$SCHEME\"]}" -append "$PLIST"
  echo "Google sign-in embedded with URL scheme $SCHEME"
fi
