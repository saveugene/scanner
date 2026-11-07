"""Use the native linker directly, bypassing HPLIP's obsolete Darwin libtool."""
from pathlib import Path
import subprocess
import sys

root, prefix, brew = map(Path, sys.argv[1:])
# Release tarball already contains generated autotools files. Do not regenerate
# them with the automake-1.11 version from 2012 recorded in that tarball.
make = ["make", *[arg for name in ("Makefile", "Makefile.in", "aclocal.m4", "configure", "config.status")
                   for arg in ("-o", name)]]
groups = subprocess.check_output([
    *make, "-s", "-f", "Makefile", "-f", str(root / "scripts/driver-objects.mk"),
    "print-driver-objects"], text=True).strip().splitlines()
assert len(groups) == 3
subprocess.run([*make, "-j4", *" ".join(groups).split()], check=True)
lib = prefix / "lib"
(lib / "sane").mkdir(parents=True, exist_ok=True)
for group, name, flags in zip(groups,
    ["libhpmud.0.dylib", "libhpip.0.dylib", "sane/libsane-hpaio.1.so"],
    [[f"-L{brew / 'lib'}", "-lusb-1.0", "-lpthread", "-ldl"], ["-lm"],
     [str(lib / "libhpmud.0.dylib"), str(lib / "libhpip.0.dylib"), "-lcups", "-ldl",
      "-framework", "CoreFoundation", "-Wl,-rpath,@loader_path/.."]]):
    objects = [str(Path(".libs") / (Path(p).stem + ".o")) for p in group.split()]
    subprocess.run(["clang", "-dynamiclib", *objects, *flags, "-o", str(lib / name),
                    "-install_name", "@rpath/" + Path(name).name], check=True)
# Bundle the USB transport so the app can run without a Homebrew lookup.
import shutil
if (lib / "libusb-1.0.0.dylib").exists():
    (lib / "libusb-1.0.0.dylib").unlink()
shutil.copy2(brew / "lib/libusb-1.0.0.dylib", lib / "libusb-1.0.0.dylib")
(lib / "libusb-1.0.0.dylib").chmod(0o755)
subprocess.run(["install_name_tool", "-id", "@rpath/libusb-1.0.0.dylib", str(lib / "libusb-1.0.0.dylib")], check=True)
deps = subprocess.check_output(["otool", "-L", str(lib / "libhpmud.0.dylib")], text=True)
usb_path = next(line.strip().split(" (")[0] for line in deps.splitlines()[1:] if "libusb" in line)
subprocess.run(["install_name_tool", "-change", usb_path, "@loader_path/libusb-1.0.0.dylib",
                str(lib / "libhpmud.0.dylib")], check=True)
for file in lib.rglob("*"):
    if file.is_file():
        subprocess.run(["codesign", "--force", "--sign", "-", str(file)], check=True)
