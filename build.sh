#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
BREW="${BREW_PREFIX:-$(brew --prefix)}"
for header in libusb-1.0/libusb.h sane/sane.h jpeglib.h; do
    if [[ ! -f "$BREW/include/$header" ]]; then
        echo "Missing $header. Install dependencies: brew install libusb sane-backends jpeg-turbo"
        exit 1
    fi
done
if [[ "${1:-}" == "--driver" || ! -f .runtime/lib/sane/libsane-hpaio.1.so ]]; then
    bash scripts/build-driver.sh
fi
mkdir -p .runtime/bin .build/swift-cache
clang -fobjc-arc -Wall -Wextra -Werror -I"$BREW/include" src/scanner.m \
    -framework Foundation -framework ImageIO -framework CoreGraphics -o .runtime/bin/hp-scan
APP="$ROOT/dist/HP Scan.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -swift-version 5 -parse-as-library -module-cache-path .build/swift-cache \
    src/HPScanApp.swift -o "$APP/Contents/MacOS/HPScan"
cp src/Info.plist "$APP/Contents/Info.plist"
# Recreate the runtime copy so stale libraries cannot remain in a rebuilt app.
python3 - "$ROOT" "$APP" <<'PY'
from pathlib import Path
import shutil
import sys
root, app = map(Path, sys.argv[1:])
target = app / 'Contents/Resources/runtime'
if target.exists():
    shutil.rmtree(target)
shutil.copytree(root / '.runtime', target)
licenses = app / 'Contents/Resources/Licenses'
licenses.mkdir(exist_ok=True)
shutil.copy2(root / 'LICENSE', licenses / 'GPL-2.0.txt')
shutil.copy2(root / 'THIRD_PARTY.md', licenses / 'THIRD_PARTY.md')
for source in (root / '.build/hplip-3.25.8').glob('COPYING*'):
    shutil.copy2(source, licenses / source.name)
usb_license = Path('/opt/homebrew/opt/libusb/COPYING')
if usb_license.exists():
    shutil.copy2(usb_license, licenses / 'libusb-LGPL.txt')
PY
find "$APP/Contents/Resources/runtime" -type f \( -name '*.dylib' -o -name '*.so' -o -name hp-scan \) \
    -exec codesign --force --sign - {} \;
codesign --force --sign - "$APP"
echo "Ready: $APP"
