#!/bin/sh
# One-time developer setup: installs XcodeGen, enables git hooks that keep the
# Xcode project in sync, and generates the project.
set -e
cd "$(dirname "$0")/.."
command -v brew >/dev/null 2>&1 || { echo "Homebrew is required: https://brew.sh"; exit 1; }
command -v xcodegen >/dev/null 2>&1 || brew install xcodegen
git config core.hooksPath .githooks
xcodegen generate
echo "Done. Open FalconMail.xcodeproj. The project regenerates itself after every pull."
