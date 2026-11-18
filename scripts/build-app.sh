#!/bin/sh
# Builds "build/nocheat.app" (ad-hoc signed) from the Swift package.
set -e
cd "$(dirname "$0")/.."
swift build -c release
APP="build/nocheat.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Nocheat "$APP/Contents/MacOS/Nocheat"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Built $APP"
