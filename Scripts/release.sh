#!/bin/bash
# Cuts a Polyhelm release and keeps both install paths in sync:
#
#   ./Scripts/release.sh 1.0.1
#
# Steps: build + package (signs/notarizes when a Developer ID and notarytool
# profile exist, otherwise ad-hoc), publish a GitHub Release with the zip
# (this is what `install.sh` and the Homebrew cask download), then rewrite the
# cask's version + sha256 and push the tap.
#
# The tap is a separate repo checked out next to this one, or wherever
# POLYHELM_TAP points. Clone it once with:
#   git clone https://github.com/miracseref/homebrew-polyhelm ../homebrew-polyhelm
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: Scripts/release.sh <version>   e.g. 1.0.1}"
TAG="v$VERSION"
REPO="miracseref/Polyhelm"
TAP_DIR="${POLYHELM_TAP:-../homebrew-polyhelm}"
ZIP="build/dist/Polyhelm.zip"

echo "==> building + packaging $VERSION"
POLYHELM_VERSION="$VERSION" ./Scripts/package.sh
[ -f "$ZIP" ] || { echo "no zip produced at $ZIP"; exit 1; }

SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
echo "==> sha256: $SHA"

echo "==> publishing GitHub release $TAG"
if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
  gh release upload "$TAG" "$ZIP" -R "$REPO" --clobber
else
  gh release create "$TAG" "$ZIP" -R "$REPO" \
    --title "Polyhelm $VERSION" \
    --notes "Install: \`brew install --cask miracseref/polyhelm/polyhelm\` — or run the one-line installer in the README."
fi

CASK="$TAP_DIR/Casks/polyhelm.rb"
if [ -f "$CASK" ]; then
  echo "==> updating cask $CASK"
  # macOS sed needs the empty-string backup arg to edit in place.
  sed -i '' -E "s/^  version \".*\"/  version \"$VERSION\"/" "$CASK"
  sed -i '' -E "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$CASK"
  if git -C "$TAP_DIR" rev-parse >/dev/null 2>&1; then
    git -C "$TAP_DIR" add Casks/polyhelm.rb
    git -C "$TAP_DIR" commit -m "polyhelm $VERSION" >/dev/null
    git -C "$TAP_DIR" push
    echo "==> tap pushed"
  fi
else
  echo "==> tap not found at $TAP_DIR — skipping cask bump"
  echo "    (clone it, then rerun, or edit Casks/polyhelm.rb by hand:"
  echo "     version \"$VERSION\", sha256 \"$SHA\")"
fi

echo
echo "==> released $VERSION"
echo "    brew:   brew install --cask miracseref/polyhelm/polyhelm"
echo "    script: curl -fsSL https://raw.githubusercontent.com/$REPO/main/install.sh | bash"
