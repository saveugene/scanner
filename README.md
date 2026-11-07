# HP PSC 1410 scanning on macOS

A native **HP Scan.app** and command-line utility for the HP PSC 1410.
The HPLIP/hpaio scanner driver is built from source for Apple Silicon and
bundled inside the application.

USB scanning has been verified with an **HP PSC 1410 / PSC 1400 series**
(`03f0:4d11`) on **macOS 27.0.1, arm64**.

## Getting started

1. Turn on the printer and connect it to your Mac by USB.
2. Place the original face down on the scanner glass and close the lid.
3. Open `dist/HP Scan.app`.
4. Choose the resolution, color mode, scan area, and file format.
5. Click **Scan…** and choose where to save the file. The result opens automatically.

Supported resolutions: **75, 100, 150, 200, 300, 600 DPI**.
Color modes: **Color** and **Grayscale**.
Output formats: **PDF, PNG, JPEG, TIFF**. Use 300 DPI for most documents.

Each scan produces one page. The app includes cancellation and prevents two
instances from using the scanner at the same time. The A4 area is limited to
the physical glass dimensions (210 × 296.926 mm). **Full glass** uses a width
of up to 215.9 mm.

The interface, messages, and default filenames are in English. The application
contains its driver libraries and model database; it does not need Homebrew
or Python at runtime. You can move the finished `.app` into Applications.
The build targets this Mac. Rebuild on the destination computer for a different
architecture or macOS version.

## If the printer displays E

During setup, the printer reported **HP 1009 — out of paper**. A pending job
prevented it from granting access to the scanner, so the driver reported
“Scanner busy.” Pressing the orange **X / Cancel** button cleared the error,
and scanning completed successfully.

If the yellow paper indicator is on, first cancel the pending job on the printer.
If the error remains, check for a paper jam or feed problem, load paper, and press
the top **On/Resume** button. Flatbed scanning itself does not consume paper.
The application reads the hardware status and displays an explanation before
starting a scan.

See [HP's indicator troubleshooting guide](https://support.hp.com/in-en/document/c00476152).

## Command line

Run these commands from the project directory:

```bash
./scan list
./scan status
./scan options
./scan scan --output scans/document.pdf --dpi 300 --mode Gray
./scan scan --output scans/photo.png --dpi 600 --mode Color
```

The destination directory must exist. The CLI never replaces an existing file
unless you pass `--overwrite`; the app uses the standard macOS save dialog to
confirm replacement. An image is published only after a complete frame has
been received.

`list`, `status`, `options`, and successful scans return JSON on stdout.
Progress and errors go to stderr. Call `./scan` directly for automation.

A restricted sandbox can block USB access. Launching the app normally or
using Terminal does not require `sudo`.

## Building

Requirements: Apple Command Line Tools, Homebrew, Python 3, and these dependencies:

```bash
brew install libusb sane-backends jpeg-turbo pkgconf
./build.sh
```

Use `./build.sh --driver` to rebuild the driver. A normal build reuses the
compiled libraries in `.runtime`. HPLIP source is downloaded from SourceForge
and checked against a pinned SHA-256 hash. Downloading requires internet access.
The archive and modified source remain in `.build/`.

The build keeps the driver in this project and the app bundle. It does not
modify system driver directories, SANE configuration, or print queues, and
does not install a network service or background agent. The application is
signed locally with an ad-hoc signature.

## Verification

```bash
bash scripts/test.sh
codesign --verify --deep --strict "dist/HP Scan.app"
```

Output tests cover RGB and grayscale in all four formats, pixel dimensions,
DPI metadata, physical PDF page size, and protection against overwriting files.
Frame tests cover complete frames without an EOF marker, rejection of partial
or failed transfers, and EOF handling when the height is not known in advance.

A hardware test scan is saved as `scans/first-scan-150dpi.png`: **1240 × 1753 px**,
color, 150 DPI. The glass was empty during that test; it verifies image transfer.
Full-glass color scanning at **600 DPI** has also been verified:
`scans/verified-600dpi.png`, **5098 × 7012 px**. It completes and saves the file
without waiting for an extra end-of-page marker.

The frontend completes a scan when the full declared frame has arrived, avoiding
an extra read for an end marker that older SCL firmware can omit. Driver read
timeouts are handled explicitly, and cancellation has a fallback for a driver
that does not return from a USB read.

This version provides scanning. It does not configure macOS printing.
See [THIRD_PARTY.md](THIRD_PARTY.md) for licenses, source links, and driver changes.

## CI and releases

GitHub Actions builds the app and HPLIP driver from source on a **macOS 15 arm64**
runner for pull requests, pushes to `main`, and manual runs. It runs both test
suites, verifies the app signature, and uploads a build artifact retained for
14 days. Download it from the workflow run's **Artifacts** section; it contains
`HP-Scan-<version>-macos-arm64.zip`, corresponding sources (including the upstream
HPLIP and libusb archives), and `SHA256SUMS`. These builds target the runner's
macOS version and Apple Silicon. They use the same ad-hoc signing as local builds.

As in `r8s`, **Release Please** manages the release PR, changelog, and version tags.
After a successful build on `main`, conventional commits such as `fix: ...` and
`feat: ...` create or update a release PR. Merging it creates a GitHub Release;
Actions then builds and tests that exact tag and attaches the ZIP, source archive,
and checksums. Version `1.0.0` is the initial baseline. Release PRs update
`version.txt`, both app version fields in `src/Info.plist`, and the release manifest.

Enable **Settings → Actions → General → Workflow permissions → Allow GitHub
Actions to create and approve pull requests** in the repository. The workflows
use the built-in `GITHUB_TOKEN`; no extra secrets are required. GitHub does not
start PR workflows for changes made with that token, so Release Please PRs are
checked by the build on `main` after merging. Regular PRs run the build normally.

To create the same archives locally after building:

```bash
bash scripts/package.sh
```

Packaging downloads the libusb source through Homebrew and requires internet access.
