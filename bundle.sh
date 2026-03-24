#!/bin/bash
set -e

APP_NAME="Dictation"

echo "Generating Xcode project..."
xcodegen generate

echo "Building release archive..."
xcodebuild archive \
  -project "$APP_NAME.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration Release \
  -archivePath "build/$APP_NAME.xcarchive"

echo "Exporting app bundle..."
xcodebuild -exportArchive \
  -archivePath "build/$APP_NAME.xcarchive" \
  -exportPath "build/export" \
  -exportOptionsPlist ExportOptions.plist

cp -r "build/export/$APP_NAME.app" "$APP_NAME.app"
rm -rf build

echo "Created $APP_NAME.app"
echo ""
echo "To install:  cp -r $APP_NAME.app /Applications/"
echo "To launch:   open $APP_NAME.app"
echo "To auto-start: add to System Settings → General → Login Items"
