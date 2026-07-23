#!/bin/bash
# Builds Polyhelm.app from the SwiftPM executable.
#   ./Scripts/build-app.sh            → debug build into ./build
#   ./Scripts/build-app.sh release    → optimized, and installs to /Applications
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
APP="build/Polyhelm.app"

echo "==> swift build ($CONFIG)"
swift build -c "$CONFIG" --arch arm64
BIN="$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)/Polyhelm"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Polyhelm"

# App icon (see AppIcon/make_icon.py to regenerate the artwork + .icns).
if [ -f AppIcon/Polyhelm.icns ]; then
  cp AppIcon/Polyhelm.icns "$APP/Contents/Resources/Polyhelm.icns"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Polyhelm</string>
  <key>CFBundleDisplayName</key><string>Polyhelm</string>
  <key>CFBundleIdentifier</key><string>app.polyhelm.Polyhelm</string>
  <key>CFBundleExecutable</key><string>Polyhelm</string>
  <key>CFBundleIconFile</key><string>Polyhelm</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <!-- Accessory app: lives in the notch and the menu bar, never the Dock. -->
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <!-- Terminal focus uses AppleScript against whichever emulator hosts the session. -->
  <key>NSAppleEventsUsageDescription</key>
  <string>Polyhelm focuses the terminal tab an agent session is running in.</string>
</dict>
</plist>
PLIST

# Optional logo artwork. Empty by default — see Logos/README.md, since shipping
# third-party marks in a binary you distribute is a licensing call, not a build step.
if compgen -G "Logos/*.svg" > /dev/null || compgen -G "Logos/*.png" > /dev/null \
   || compgen -G "Logos/*.pdf" > /dev/null; then
  mkdir -p "$APP/Contents/Resources/Logos"
  cp Logos/*.svg Logos/*.png Logos/*.pdf "$APP/Contents/Resources/Logos/" 2>/dev/null || true
  echo "==> bundled $(ls "$APP/Contents/Resources/Logos" | wc -l | tr -d ' ') logo file(s)"
else
  echo "==> no bundled logos (Logos/ is empty — runtime discovery + drawn fallbacks)"
fi

# Ad-hoc signature: enough for local use and for TCC to remember grants by path.
codesign --force --deep --sign - "$APP" 2>/dev/null || \
  echo "    (codesign skipped — app still runs locally)"

echo "==> built $APP"

if [ "$CONFIG" = "release" ]; then
  echo "==> installing to /Applications"
  rm -rf /Applications/Polyhelm.app
  cp -R "$APP" /Applications/
  echo "    open -a Polyhelm"
fi
