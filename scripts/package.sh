#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="$(cat version.txt)"
APP="dist/HP Scan.app"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
if [[ "$APP_VERSION" != "$VERSION" ]]; then
    echo "App version $APP_VERSION does not match version.txt ($VERSION); rebuild the app." >&2
    exit 1
fi
ZIP="HP-Scan-$VERSION-macos-arm64.zip"
SOURCES="HP-Scan-$VERSION-sources.tar.gz"

# Keep executable permissions and the app bundle intact inside the artifact.
ditto -c -k --sequesterRsrc --keepParent "$APP" "dist/$ZIP"

# Supply the upstream driver and USB library sources alongside our build scripts.
# Homebrew verifies the libusb source archive against its formula's checksum.
brew fetch --build-from-source libusb
USB_SOURCE="$(brew --cache --build-from-source libusb)"
STAGING="$(mktemp -d "$ROOT/.build/package.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
mkdir "$STAGING/release-sources"
cp -L "$USB_SOURCE" "$STAGING/release-sources/$(basename "$USB_SOURCE")"
cp "$(brew --prefix libusb)/.brew/libusb.rb" "$STAGING/release-sources/libusb.rb"
COPYFILE_DISABLE=1 tar --exclude='.DS_Store' --exclude='__pycache__' --exclude='*.pyc' \
    -czf "dist/$SOURCES" \
    LICENSE THIRD_PARTY.md README.md build.sh scan version.txt src scripts tests vendor \
    .github release-please-config.json release-please-manifest.json \
    .build/hplip-3.25.8.tar.gz -C "$STAGING" release-sources
(
    cd dist
    shasum -a 256 "$ZIP" "$SOURCES" > SHA256SUMS
)
echo "Ready: dist/$ZIP and dist/$SOURCES"
