#!/bin/bash
# Builds app/build/Flatline.app, universal (Apple silicon and Intel).
# Needs the Xcode Command Line Tools: xcode-select --install
# SIGN_ID="Developer ID Application: ..." signs for notarization; otherwise the app is signed ad hoc.
set -euo pipefail
cd "$(dirname "$0")"
VERSION=$(sed -n 's/^VERSION = "\(.*\)"$/\1/p' ../agent/flatline)  # one version for the agent and the app
APP=build/Flatline.app
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Fonts"
for arch in ${ARCHS:-arm64 x86_64}; do
  swiftc -O -parse-as-library -target "$arch-apple-macos14" Flatline.swift -o "build/Flatline-$arch"
done
lipo -create build/Flatline-* -output "$APP/Contents/MacOS/Flatline"
cp Fonts/*.ttf Fonts/OFL-*.txt "$APP/Contents/Resources/Fonts/"
cp Flatline.icns "$APP/Contents/Resources/"
cp ../agent/flatline "$APP/Contents/Resources/flatline"  # run once over SSH when a server has no agent
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Flatline</string>
  <key>CFBundleIdentifier</key><string>dev.flatline.app</string>
  <key>CFBundleExecutable</key><string>Flatline</string>
  <key>CFBundleIconFile</key><string>Flatline</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>ATSApplicationFontsPath</key><string>Fonts</string>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict></plist>
EOF
codesign --force --sign "${SIGN_ID:--}" ${SIGN_ID:+--options runtime --timestamp} "$APP"
echo "Built $(pwd)/$APP ($VERSION, $(lipo -archs "$APP/Contents/MacOS/Flatline"))"
