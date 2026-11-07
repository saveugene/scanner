#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BREW="${BREW_PREFIX:-$(brew --prefix)}"
PREFIX="$ROOT/.runtime"
VERSION=3.25.8
ARCHIVE="$ROOT/.build/hplip-$VERSION.tar.gz"
SOURCE="$ROOT/.build/hplip-$VERSION"
mkdir -p "$ROOT/.build" "$PREFIX"
if [[ ! -f "$ARCHIVE" ]]; then
    curl --fail --location --retry 2 --output "$ARCHIVE.part" \
        "https://downloads.sourceforge.net/project/hplip/hplip/$VERSION/hplip-$VERSION.tar.gz"
    mv "$ARCHIVE.part" "$ARCHIVE"
fi
printf '%s  %s\n' 1cf6d6c28735435c8eb6646e83bcfb721e51c4b1f0e8cf9105a6faf96dc9ad25 "$ARCHIVE" | shasum -a 256 -c -
if [[ ! -d "$SOURCE" ]]; then
    tar -xzf "$ARCHIVE" -C "$ROOT/.build"
fi
python3 "$ROOT/scripts/patch_hplip.py" "$SOURCE" "$ROOT/vendor/hp-scan-macos-main"
cd "$SOURCE"
export PKG_CONFIG_PATH="$BREW/lib/pkgconfig"
export CFLAGS="-I$BREW/include -I$BREW/include/libusb-1.0 -I$BREW/include/sane -D_DARWIN_C_SOURCE -Wno-error -Wno-implicit-function-declaration -fcommon"
export CPPFLAGS="-I$BREW/include -I$BREW/include/libusb-1.0 -I$BREW/include/sane"
export LDFLAGS="-L$BREW/lib"
echo 'Configuring HPLIP (log: .build/configure.log)…'
if ! ./configure --prefix="$PREFIX" \
    --enable-lite-build --disable-network-build --disable-fax-build \
    --disable-gui-build --disable-doc-build --disable-dbus-build \
    --disable-pp-build --disable-policykit --disable-imageProcessor-build \
    --enable-scan-build --disable-cups-drv-install --disable-foomatic-drv-install \
    --disable-foomatic-ppd-install --disable-cups-ppd-install \
    > "$ROOT/.build/configure.log" 2>&1; then
    tail -60 "$ROOT/.build/configure.log"
    exit 1
fi
python3 - "$PREFIX" <<'PY'
from pathlib import Path
import re
import sys
path = Path('Makefile')
text = path.read_text().replace('hplip_confdir = /etc/hp', f'hplip_confdir = {sys.argv[1]}/etc/hp')
for var in ('libsane_hpaio_la_DEPENDENCIES', 'libsane_hpaio_la_LIBADD'):
    pattern = rf'({var} = .*?)(?=\n[^\t])'
    text, count = re.subn(pattern, lambda m: m[0].replace('libhpipp.la', ''), text, flags=re.S)
    assert count == 1, var
path.write_text(text)
PY
echo 'Compiling hpaio (log: .build/driver-build.log)…'
if ! python3 "$ROOT/scripts/link_driver.py" "$ROOT" "$PREFIX" "$BREW" > "$ROOT/.build/driver-build.log" 2>&1; then
    tail -70 "$ROOT/.build/driver-build.log"
    exit 1
fi
mkdir -p "$PREFIX/lib/sane" "$PREFIX/etc/hp" "$PREFIX/share/hplip/data/models/unreleased"
cp hplip.conf "$PREFIX/etc/hp/"
cp data/models/models.dat "$PREFIX/share/hplip/data/models/"
touch "$PREFIX/share/hplip/data/models/unreleased/unreleased.dat"
echo "Driver ready: $PREFIX/lib/sane/libsane-hpaio.1.so"
