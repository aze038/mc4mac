.PHONY: project build test clean

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
