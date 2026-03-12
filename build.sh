#!/bin/bash
# Build and bundle Overline as a proper macOS .app
#
# Usage:
#   ./build.sh [debug|release] [OPTIONS]
#     --sign "Developer ID Application: ..."   Code sign for distribution
#     --notarize                                 Notarize (requires --sign)
#     --dmg                                      Create DMG

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
APP_NAME="Overline"
BUNDLE_ID="com.overline.app"
BUNDLE_DIR="${BUILD_DIR}/${APP_NAME}.app"
CONTENTS="${BUNDLE_DIR}/Contents"
MACOS="${CONTENTS}/MacOS"
RESOURCES="${CONTENTS}/Resources"
DMG_PATH="${BUILD_DIR}/${APP_NAME}.dmg"

# Parse arguments
CONFIG="release"
SIGN_IDENTITY=""
DO_NOTARIZE=false
DO_DMG=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        debug)   CONFIG="debug"; shift ;;
        release) CONFIG="release"; shift ;;
        --sign)  SIGN_IDENTITY="$2"; shift 2 ;;
        --notarize) DO_NOTARIZE=true; shift ;;
        --dmg)   DO_DMG=true; shift ;;
        *)       shift ;;
    esac
done

echo "Building Swift ($CONFIG)..."
cd "${SCRIPT_DIR}"
swift build -c "$CONFIG" 2>&1 | tail -5

BINARY=".build/${CONFIG}/Overline"
if [ ! -f "$BINARY" ]; then
    # Try architecture-specific path
    BINARY=".build/arm64-apple-macosx/${CONFIG}/Overline"
fi

echo "Creating app bundle..."
mkdir -p "${MACOS}" "${RESOURCES}"

cp -f "$BINARY" "${MACOS}/Overline"

# Copy icon if it exists
if [ -f "Resources/AppIcon.icns" ]; then
    cp -f "Resources/AppIcon.icns" "${RESOURCES}/AppIcon.icns"
fi

# Entitlements
ENTITLEMENTS="Resources/Overline.entitlements"

# Info.plist
cat > "${CONTENTS}/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSAccessibilityUsageDescription</key>
    <string>Overline needs Accessibility access to read window positions and detect sessions.</string>
</dict>
</plist>
PLIST

# Clear quarantine
xattr -cr "${BUNDLE_DIR}" 2>/dev/null || true

# Code signing
if [ -n "$SIGN_IDENTITY" ]; then
    echo "Signing with: ${SIGN_IDENTITY}"
    SIGN_ARGS=(--force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" --options runtime)
    if [ -f "$ENTITLEMENTS" ]; then
        SIGN_ARGS+=(--entitlements "$ENTITLEMENTS")
    fi
    codesign "${SIGN_ARGS[@]}" "${BUNDLE_DIR}"
else
    # Ad-hoc signing for local development
    codesign --force --sign - --identifier "$BUNDLE_ID" "${BUNDLE_DIR}"
fi

echo "Built: ${BUNDLE_DIR}"

# Notarization
if $DO_NOTARIZE; then
    if [ -z "$SIGN_IDENTITY" ]; then
        echo "ERROR: --notarize requires --sign"
        exit 1
    fi

    echo "Notarizing..."
    NOTARIZE_ZIP=$(mktemp -d)/${APP_NAME}.zip
    ditto -c -k --keepParent "${BUNDLE_DIR}" "$NOTARIZE_ZIP"

    xcrun notarytool submit "$NOTARIZE_ZIP" \
        --keychain-profile "notarytool" \
        --wait 2>&1 | tail -10

    xcrun stapler staple "${BUNDLE_DIR}"
    rm -f "$NOTARIZE_ZIP"
    echo "Notarization complete"
fi

# Create DMG
if $DO_DMG; then
    echo "Creating DMG..."
    rm -f "${DMG_PATH}"

    if command -v create-dmg &>/dev/null; then
        DMG_ARGS=(
            --volname "${APP_NAME}"
            --window-pos 200 120
            --window-size 600 400
            --icon-size 128
            --icon "${APP_NAME}.app" 150 185
            --app-drop-link 450 185
            --no-internet-enable
        )
        if [ -f "${RESOURCES}/AppIcon.icns" ]; then
            DMG_ARGS+=(--volicon "${RESOURCES}/AppIcon.icns")
        fi
        if [ -f "Resources/dmg-background.tiff" ]; then
            DMG_ARGS+=(--background "Resources/dmg-background.tiff")
        fi
        create-dmg "${DMG_ARGS[@]}" "${DMG_PATH}" "${BUNDLE_DIR}" 2>&1 | tail -5
    else
        # Fallback: hdiutil
        STAGING=$(mktemp -d)
        cp -R "${BUNDLE_DIR}" "${STAGING}/"
        ln -s /Applications "${STAGING}/Applications"
        hdiutil create -volname "${APP_NAME}" -srcfolder "${STAGING}" \
            -ov -format UDZO "${DMG_PATH}" 2>&1 | tail -3
        rm -rf "${STAGING}"
    fi

    echo "DMG: ${DMG_PATH}"
fi

# Kill existing instance before relaunch
pkill -f "${BUNDLE_DIR}/Contents/MacOS/${APP_NAME}" 2>/dev/null && sleep 0.5 || true

echo "Opening app..."
open "${BUNDLE_DIR}"
