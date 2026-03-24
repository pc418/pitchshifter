#!/bin/bash
set -e

cd "$(dirname "$0")"

echo "Building retune..."
swift build -c release 2>&1

APP_DIR="retune.app/Contents"
mkdir -p "$APP_DIR/MacOS"
mkdir -p "$APP_DIR/Resources"

# Copy binary
cp .build/release/retune "$APP_DIR/MacOS/retune"

# Copy Info.plist
cp Info.plist "$APP_DIR/Info.plist"

# Sign with ad-hoc signature (needed for ScreenCaptureKit on newer macOS)
codesign --force --sign - --entitlements retune.entitlements "$APP_DIR/MacOS/retune" 2>/dev/null || true

echo ""
echo "✓ Built retune.app"
echo "  To run:  open retune.app"
echo "  Or:      ./retune.app/Contents/MacOS/retune"
