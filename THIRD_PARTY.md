# Open source components

- **HPLIP 3.25.8**, HP Development Company, LP: https://developers.hp.com/hp-linux-imaging-and-printing
  Source: https://downloads.sourceforge.net/project/hplip/hplip/3.25.8/hplip-3.25.8.tar.gz
  SHA-256: `1cf6d6c28735435c8eb6646e83bcfb721e51c4b1f0e8cf9105a6faf96dc9ad25`.
  The source archive and complete modified source remain in `.build/` locally.
  HPLIP includes GPL, BSD/MIT and other licensed components; see its `COPYING*` files
  bundled with the app and individual source headers. Used scanner and transport
  libraries are built from source by `scripts/build-driver.sh`.
- **hp-scan-macos**, https://github.com/nricaurte/hp-scan-macos, GPL-2.0:
  the orblite stubs and Darwin header fixes informed this port. A source snapshot
  with its license is kept in `vendor/hp-scan-macos-main`. The LEDM device-ID
  emulation patch is deliberately not applied to the PSC 1410.
- **libusb 1.0**, https://libusb.info/, LGPL-2.1-or-later: the Homebrew dylib
  is copied into the app. Its license is included in Resources/Licenses.
  Source: https://github.com/libusb/libusb/releases.
- **SANE** headers from Homebrew `sane-backends`: https://sane-project.org/.
  This frontend calls hpaio directly and does not require a system SANE backend
  registration. Apple's Foundation, SwiftUI, ImageIO and CoreGraphics are system
  frameworks.

Local changes to HPLIP are recorded in `scripts/patch_hplip.py`: Darwin headers,
orblite stubs, safe discovery cleanup, and a relocatable model-database path.
It also handles SCL image-read timeouts that the original loop could ignore.
`scripts/link_driver.py` bypasses the old libtool Darwin linker pipeline.

The new frontend and app source are GPL-2.0-or-later (see LICENSE).
If distributing compiled binaries, also supply their corresponding source,
patches, build scripts, and the applicable upstream source/license files.
