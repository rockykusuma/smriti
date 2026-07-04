#!/bin/bash
# Assemble and ad-hoc sign Smriti.app from a release build.
set -e
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"

VERSION="0.8.0"
BUNDLE_ID="com.rakeshkusuma.smriti"
APP="Smriti.app"

echo "→ building release binary…"
( cd "$ROOT" && /usr/bin/env swift build -c release >/dev/null )
BIN="$ROOT/.build/release/smriti"
[ -x "$BIN" ] || { echo "release binary missing"; exit 1; }

echo "→ assembling $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Smriti"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>Smriti</string>
    <key>CFBundleDisplayName</key>     <string>Smriti</string>
    <key>CFBundleIdentifier</key>      <string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key>      <string>Smriti</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>${VERSION}</string>
    <key>CFBundleVersion</key>         <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSHumanReadableCopyright</key><string>A local memory for your Mac. No cloud, no telemetry.</string>
    <key>NSMicrophoneUsageDescription</key><string>Smriti records meeting audio you approve so it can transcribe it locally.</string>
    <key>NSSpeechRecognitionUsageDescription</key><string>Smriti transcribes recorded meetings on this Mac.</string>
</dict>
</plist>
PLIST

echo "→ signing (ad-hoc)…"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1

echo "→ done: $(pwd)/$APP"
codesign -dv "$APP" 2>&1 | grep -E 'Identifier|Signature' || true
