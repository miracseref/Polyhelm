#!/bin/bash
# Packages Polyhelm for other people's Macs.
#
#   ./Scripts/package.sh
#
# Signs with a Developer ID certificate and notarizes when both are available,
# and says plainly what is missing when they are not. It never pretends an
# unsigned build is distributable.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Polyhelm.app"
DIST="build/dist"
ZIP="$DIST/Polyhelm.zip"
ENTITLEMENTS="Scripts/polyhelm.entitlements"
PROFILE="${NOTARY_PROFILE:-notarytool}"

echo "==> building release"
./Scripts/build-app.sh release > /dev/null
rm -rf "$DIST"; mkdir -p "$DIST"

# A "Developer ID Application" cert is the only kind Gatekeeper accepts from
# outside the App Store. "Apple Development" certs validate only on machines
# registered to the developer account, so they are no better than ad-hoc here.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
            | grep "Developer ID Application" | head -1 \
            | sed -E 's/.*"(.*)"/\1/' || true)"

if [ -n "$IDENTITY" ]; then
  echo "==> signing as: $IDENTITY"
  # --options runtime is the hardened runtime, mandatory for notarization.
  codesign --force --deep --timestamp --options runtime \
           --entitlements "$ENTITLEMENTS" \
           --sign "$IDENTITY" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
else
  echo "==> NO Developer ID Application certificate found"
  echo "    Signing ad-hoc. Gatekeeper will reject this on other Macs."
  codesign --force --deep --sign - "$APP"
fi

# ditto preserves the bundle's symlinks and metadata; plain `zip` corrupts
# signed .app bundles.
echo "==> zipping"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

if [ -n "$IDENTITY" ]; then
  if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    echo "==> notarizing (this takes a few minutes)"
    xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
    # Stapling the ticket to the app lets it launch offline on a first run.
    xcrun stapler staple "$APP"
    rm -f "$ZIP"
    /usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
    echo "==> notarized and stapled"
  else
    echo "==> notarytool profile '$PROFILE' not found — skipping notarization"
    echo "    xcrun notarytool store-credentials $PROFILE \\"
    echo "      --apple-id <your-apple-id> --team-id <TEAMID> --password <app-specific-password>"
  fi
fi

cp Scripts/RECIPIENT-README.md "$DIST/README.md" 2>/dev/null || true

echo
echo "==> $ZIP"
echo -n "==> gatekeeper: "
if spctl -a -vv "$APP" 2>&1 | grep -q accepted; then
  echo "accepted — this will open normally on any Mac"
else
  echo "REJECTED — recipients must right-click > Open, or strip quarantine:"
  echo "    xattr -dr com.apple.quarantine /Applications/Polyhelm.app"
fi
