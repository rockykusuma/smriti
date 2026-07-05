#!/usr/bin/env bash
#
# Build Smriti's menu bar as a proper .app bundle.
#
# Why this exists: on recent macOS, Microphone and Speech Recognition are
# granted to *bundled apps*, but a bare command-line binary that requests them
# is aborted by TCC (__TCC_CRASHING_DUE_TO_PRIVACY_VIOLATION__) even when it is
# signed and carries an embedded Info.plist. So anything that needs those
# permissions -- meeting recording and voice notes -- must run from this bundle.
# The CLI at /usr/local/bin/smriti stays as-is for the MCP server and terminal
# commands (it does not need mic/speech).
#
# Usage:
#   Scripts/build-app.sh                 # builds ./build/Smriti.app
#   Scripts/build-app.sh /Applications   # builds + installs to /Applications
#
# Signing identity defaults to the self-signed "Smriti Dev Signing" cert (so
# TCC grants survive rebuilds); override with SMRITI_SIGN_ID.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CERT="${SMRITI_SIGN_ID:-Smriti Dev Signing}"
INSTALL_DIR="${1:-}"
APP="${ROOT}/build/Smriti.app"

echo "Building release binary..."
swift build -c release --package-path "${ROOT}"
BIN="${ROOT}/.build/release/smriti"

echo "Assembling ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN}" "${APP}/Contents/MacOS/Smriti"

# App icon (shows as the app icon and the in-app sidebar wordmark).
ICON="${ROOT}/packaging/AppIcon.icns"
if [ -f "${ICON}" ]; then
    cp "${ICON}" "${APP}/Contents/Resources/AppIcon.icns"
else
    echo "warning: ${ICON} not found - bundle will use a generic icon"
fi

cat > "${APP}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Smriti</string>
    <key>CFBundleDisplayName</key><string>Smriti</string>
    <key>CFBundleIdentifier</key><string>com.smriti.app</string>
    <key>CFBundleExecutable</key><string>Smriti</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.8.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Smriti records voice notes, and meetings only after you approve each one; audio stays on this Mac.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Smriti transcribes your recordings on-device; nothing is uploaded.</string>
</dict>
</plist>
PLIST

echo "Signing with '${CERT}'..."
# Sign the inner executable first, then seal the bundle.
codesign --force --sign "${CERT}" "${APP}/Contents/MacOS/Smriti"
codesign --force --sign "${CERT}" "${APP}"

echo "Built ${APP}"

if [ -n "${INSTALL_DIR}" ]; then
    DEST="${INSTALL_DIR}/Smriti.app"
    echo "Installing to ${DEST} (fresh inode)..."
    rm -rf "${DEST}"
    cp -R "${APP}" "${DEST}"
    echo "Installed ${DEST}"
    echo
    echo "Run it:  open \"${DEST}\""
    echo "(Approve Microphone + Speech Recognition when prompted on first use.)"
else
    echo
    echo "Run it:  open \"${APP}\""
    echo "(Approve Microphone + Speech Recognition when prompted on first use.)"
fi
