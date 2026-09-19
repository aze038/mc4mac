#!/bin/sh
# Regenerates the Xcode project when XcodeGen is installed. Safe to run any time.
cd "$(git rev-parse --show-toplevel)" || exit 0
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "FalconMail: xcodegen not installed, skipping project generation (brew install xcodegen)"
  exit 0
fi
xcodegen generate --quiet >/dev/null 2>&1 && echo "FalconMail: Xcode project regenerated"
