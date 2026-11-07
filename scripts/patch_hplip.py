"""Small, checked Darwin fixes. No LEDM device-ID emulation for the PSC."""
from pathlib import Path
import shutil
import sys

source, vendor = map(Path, sys.argv[1:])


def replace(file, old, new):
    path = source / file
    text = path.read_text()
    if new in text:
        return
    if text.count(old) != 1:
        raise SystemExit(f"Unexpected HPLIP source in {file}; refusing to patch")
    path.write_text(text.replace(old, new))


for file in ("orblitei.h", "orblite.c"):
    shutil.copyfile(vendor / "stubs" / file, source / "scan/sane" / file)

replace("scan/sane/bb_ledm.c", "# include <stdlib.h>",
        "# include <stdlib.h>\n# include <unistd.h>\n# include <sys/time.h>")
replace("scan/sane/http.c", "#include <ctype.h>",
        "#include <ctype.h>\n#include <unistd.h>")
replace("scan/sane/sclpml.c", "#include <fcntl.h>",
        "#include <fcntl.h>\n#include <sys/time.h>")
replace("scan/sane/hpaio.c", "   SANE_Device*** devList;\n   orblite_get_devices(devList, localOnly);",
        "   /* orblite is disabled on Darwin; DeviceList is already populated. */")
replace("io/hpmud/musb.c", "bugout:\n    if (!hd)\n        libusb_close(hd);",
        "bugout:\n    if (hd)\n        libusb_close(hd);")
replace("io/hpmud/model.c", "   homedir[0] = 0;",
        """   homedir[0] = 0;
   /* Allow the standalone macOS app to carry its own model database. */
   const char *home_override = getenv("HP_SCAN_HPLIP_HOME");
   if (home_override && home_override[0] && strlen(home_override) < sizeof(homedir))
   {
      strcpy(homedir, home_override);
      return 0;
   }""")

# SCL's legacy loop ignores READ_TIMEOUT and otherwise retries forever when a
# printer stops sending image records. Finish/fail through its normal path.
path = source / "scan/sane/sclpml.c"
text = path.read_text()
old = "rService & MFPDTF_RESULT_ERROR_MASK"
new = "rService & (MFPDTF_RESULT_ERROR_MASK | MFPDTF_RESULT_READ_TIMEOUT)"
if old in text:
    if text.count(old) != 3:
        raise SystemExit("Unexpected SCL read loop; refusing timeout patch")
    path.write_text(text.replace(old, new))
elif text.count(new) != 3:
    raise SystemExit("SCL timeout patch could not be verified")
