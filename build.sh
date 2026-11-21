#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
app="build/Сетеметр.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Info.plist "$app/Contents/Info.plist"
cp Setemeter.icns "$app/Contents/Resources/"
for arch in arm64 x86_64; do
    xcrun swiftc -O -parse-as-library -target "${arch}-apple-macos13.0" \
        Setemeter.swift Diagnostics.swift Updater.swift -o "build/Setemeter-${arch}"
done
xcrun lipo -create build/Setemeter-arm64 build/Setemeter-x86_64 -output "$app/Contents/MacOS/Setemeter"
codesign --force --sign - "$app"
