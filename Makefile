.PHONY: setup project build test clean run

LOCAL_SIGN_IDENTITY ?= Apple Development: muradoffk@gmail.com (78Y5FM94B4)

# Build, sign with the local development certificate (stable keychain identity), and launch
run: project
	xcodebuild -project FalconMail.xcodeproj -scheme FalconMail -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO build | grep -E "error:|BUILD" || true
	codesign --force --deep --options runtime --sign "$(LOCAL_SIGN_IDENTITY)" build/Build/Products/Debug/FalconMail.app
	open build/Build/Products/Debug/FalconMail.app

# One-time: install xcodegen, enable auto-regeneration hooks, generate project
setup:
	./scripts/setup.sh

# Generate FalconMail.xcodeproj from project.yml (requires: brew install xcodegen)
project:
	xcodegen generate

# Build the app (Apple Silicon only)
build: project
	xcodebuild -project FalconMail.xcodeproj -scheme FalconMail -configuration Debug -arch arm64 build

# Run FalconCore unit tests without the app
test:
	swift test

clean:
	rm -rf .build DerivedData FalconMail.xcodeproj
