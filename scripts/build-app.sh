#!/bin/sh
# Builds "build/Human or AI.app" (ad-hoc signed) from the Swift package.
set -e
cd "$(dirname "$0")/.."
swift build -c release
APP="build/Human or AI.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Anticheating "$APP/Contents/MacOS/Anticheating"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Built $APP"
