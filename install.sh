#!/bin/bash
# Polyhelm one-line installer.
#
#   curl -fsSL https://raw.githubusercontent.com/miracseref/Polyhelm/main/install.sh | bash
#
# Downloads the latest release, installs to /Applications, and — because the
# build is not yet Developer ID notarized — strips the quarantine flag so
# Gatekeeper opens it without a prompt. Once the app is notarized, the
# de-quarantine step below becomes a harmless no-op and can be removed.
set -euo pipefail

REPO="miracseref/Polyhelm"
APP="Polyhelm.app"
DEST="/Applications"
URL="https://github.com/$REPO/releases/latest/download/Polyhelm.zip"

[ "$(uname)" = "Darwin" ]  || { echo "Polyhelm is macOS only."; exit 1; }
[ "$(uname -m)" = "arm64" ] || { echo "Polyhelm requires Apple Silicon (arm64)."; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "==> downloading the latest Polyhelm release"
if ! curl -fsSL "$URL" -o "$tmp/Polyhelm.zip"; then
  echo "    could not download $URL"
  echo "    (there may be no published release yet — see the repo's Releases page)"
  exit 1
fi

echo "==> unpacking"
/usr/bin/ditto -x -k "$tmp/Polyhelm.zip" "$tmp"
[ -d "$tmp/$APP" ] || { echo "    archive did not contain $APP"; exit 1; }

# Writing to /Applications needs sudo unless the user owns it.
SUDO=""
[ -w "$DEST" ] || SUDO="sudo"
[ -n "$SUDO" ] && echo "==> installing to $DEST (needs your password)"

# Quit a running copy so the replace doesn't fight a live process.
osascript -e 'quit app "Polyhelm"' >/dev/null 2>&1 || true

$SUDO rm -rf "$DEST/$APP"
$SUDO /usr/bin/ditto "$tmp/$APP" "$DEST/$APP"
$SUDO xattr -dr com.apple.quarantine "$DEST/$APP" 2>/dev/null || true

echo "==> launching"
open -a Polyhelm

echo
echo "Polyhelm is installed and running — look at your notch / menu bar."
echo "It needs Automation permission to jump to terminal tabs; grant it when asked."
