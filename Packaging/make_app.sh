#!/bin/bash
# Builds dist/DockClickMinimize.app from the SwiftPM release binary.
# Bump the version in Packaging/Info.plist before releasing.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP=dist/DockClickMinimize.app
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/DockClickMinimize "$APP/Contents/MacOS/"
cp Packaging/Info.plist "$APP/Contents/"
cp Packaging/AppIcon.icns "$APP/Contents/Resources/"

# Prefer the stable Apple Development certificate so macOS permission grants
# survive rebuilds; fall back to ad-hoc signing if it's missing.
SIGN_ID=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)
if [ -z "$SIGN_ID" ]; then
  echo "WARNING: no Apple Development certificate found; using ad-hoc signing (permissions will reset on each rebuild)"
  SIGN_ID="-"
fi

codesign --force --sign "$SIGN_ID" "$APP"
codesign --verify --verbose "$APP"

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
echo "Built $APP (version $VERSION)"
