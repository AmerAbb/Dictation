#!/bin/bash
set -e

APP_NAME="Dictation"
BUILD_DIR=".build/release"
APP_BUNDLE="$APP_NAME.app"

echo "Building release..."
swift build -c release

echo "Creating app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp Info.plist "$APP_BUNDLE/Contents/"

# Generate minimal PkgInfo
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# Code sign with developer identity so Accessibility permission persists
echo "Code signing..."
codesign --force --sign "Apple Development: amer.abboud19@gmail.com (3R792YL69C)" "$APP_BUNDLE"

echo "Created $APP_BUNDLE"
echo ""
echo "To install:  cp -r $APP_BUNDLE /Applications/"
echo "To launch:   open $APP_BUNDLE"
echo "To auto-start: add to System Settings → General → Login Items"
