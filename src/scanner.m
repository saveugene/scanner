// SPDX-License-Identifier: GPL-2.0-or-later
// Native macOS frontend for the HPLIP hpaio backend. No SANE system registration.
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#include <sane/sane.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <signal.h>
#include <unistd.h>
#include <limits.h>
#include <errno.h>

typedef struct {
    SANE_Status (*init)(SANE_Int *, SANE_Auth_Callback);
    void (*exit)(void);
    SANE_Status (*get_devices)(const SANE_Device ***, SANE_Bool);
    SANE_Status (*open)(SANE_String_Const, SANE_Handle *);
    void (*close)(SANE_Handle);
    const SANE_Option_Descriptor *(*get_option_descriptor)(SANE_Handle, SANE_Int);
    SANE_Status (*control_option)(SANE_Handle, SANE_Int, SANE_Action, void *, SANE_Int *);
    SANE_Status (*get_parameters)(SANE_Handle, SANE_Parameters *);
    SANE_Status (*start)(SANE_Handle);
    SANE_Status (*read)(SANE_Handle, SANE_Byte *, SANE_Int, SANE_Int *);
    void (*cancel)(SANE_Handle);
} Backend;

static Backend backend;
static SANE_Handle scanner;
static volatile sig_atomic_t interrupted;
static void handleSignal(int sig) { interrupted = sig; }

static void fail(NSString *message) {
    @throw [NSException exceptionWithName:@"ScannerError" reason:message userInfo:nil];
}

static NSString *statusText(SANE_Status status) {
    switch (status) {
        case SANE_STATUS_GOOD: return @"OK";
        case SANE_STATUS_UNSUPPORTED: return @"Operation not supported";
        case SANE_STATUS_CANCELLED: return @"Scan cancelled";
        case SANE_STATUS_DEVICE_BUSY: return @"Scanner busy. Close other scanning applications";
        case SANE_STATUS_INVAL: return @"Invalid settings or device unavailable";
        case SANE_STATUS_JAMMED: return @"Scanner mechanism blocked";
        case SANE_STATUS_NO_DOCS: return @"No document loaded";
        case SANE_STATUS_COVER_OPEN: return @"Cover open";
        case SANE_STATUS_IO_ERROR: return @"USB communication error. Check the power and cable, then reconnect the printer";
        case SANE_STATUS_NO_MEM: return @"Not enough memory";
        case SANE_STATUS_ACCESS_DENIED: return @"USB access denied. Run the application outside the sandbox";
        default: return [NSString stringWithFormat:@"SANE error %d", status];
    }
}

static void check(SANE_Status status, NSString *operation) {
    if (status != SANE_STATUS_GOOD)
        fail([NSString stringWithFormat:@"%@: %@ (SANE %d)", operation, statusText(status), status]);
}

static void json(id object) {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingPrettyPrinted error:&error];
    if (!data) fail(error.localizedDescription);
    fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout);
}

static NSString *runtimePath(void) {
    char executable[PATH_MAX], resolved[PATH_MAX];
    uint32_t size = sizeof(executable);
    if (_NSGetExecutablePath(executable, &size) || !realpath(executable, resolved))
        fail(@"Could not locate the application directory");
    return [[[NSString stringWithUTF8String:resolved] stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
}

static void loadBackend(void) {
    NSString *runtime = runtimePath();
    setenv("HP_SCAN_HPLIP_HOME", [[runtime stringByAppendingPathComponent:@"share/hplip"] fileSystemRepresentation], 1);
    NSString *path = [runtime stringByAppendingPathComponent:@"lib/sane/libsane-hpaio.1.so"];
    void *library = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (!library) fail([NSString stringWithFormat:@"Could not load the driver: %s", dlerror()]);
#define LOAD(name) do { \
    backend.name = (typeof(backend.name))dlsym(library, "sane_hpaio_" #name); \
    if (!backend.name) fail(@"Driver function missing: sane_hpaio_" @#name); \
} while (0)
    LOAD(init); LOAD(exit); LOAD(get_devices); LOAD(open); LOAD(close);
    LOAD(get_option_descriptor); LOAD(control_option); LOAD(get_parameters);
    LOAD(start); LOAD(read); LOAD(cancel);
#undef LOAD
    SANE_Int version;
    check(backend.init(&version, NULL), @"Initialize driver");
}

static NSArray *devices(void) {
    const SANE_Device **list = NULL;
    check(backend.get_devices(&list, SANE_TRUE), @"Find scanners");
    NSMutableArray *result = [NSMutableArray array];
    for (int i = 0; list && list[i]; i++) {
        const SANE_Device *d = list[i];
        [result addObject:@{@"id": @(d->name), @"vendor": @(d->vendor), @"model": @(d->model)}];
    }
    return result;
}

static NSDictionary *hardwareStatus(NSString *device) {
    // PSC 1400's documented HPLIP MLC mode is 6. Read IEEE-1284 status
    // before reserving the scanner, so paper errors do not look like a hang.
    if ([device rangeOfString:@"/PSC_1400_series?" options:NSCaseInsensitiveSearch].location == NSNotFound)
        return @{@"known": @NO};
    NSString *path = [runtimePath() stringByAppendingPathComponent:@"lib/libhpmud.0.dylib"];
    void *lib = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (!lib) return @{@"known": @NO};
    int (*openDevice)(const char *, int, int *) = dlsym(lib, "hpmud_open_device");
    int (*getID)(int, char *, int, int *) = dlsym(lib, "hpmud_get_device_id");
    int (*closeDevice)(int) = dlsym(lib, "hpmud_close_device");
    if (!openDevice || !getID || !closeDevice) return @{@"known": @NO};
    NSString *uri = [device hasPrefix:@"hpaio:"] ? [@"hp:" stringByAppendingString:[device substringFromIndex:6]] :
                    [device hasPrefix:@"hp:"] ? device : [@"hp:" stringByAppendingString:device];
    int handle = 0, length = 0;
    if (openDevice(uri.UTF8String, 6, &handle)) return @{@"known": @NO};
    char buffer[4096] = {0};
    int result = getID(handle, buffer, sizeof(buffer) - 1, &length);
    closeDevice(handle);
    if (result || length <= 0) return @{@"known": @NO};
    NSString *idString = [[NSString alloc] initWithBytes:buffer length:MIN(length, (int)sizeof(buffer) - 1) encoding:NSASCIIStringEncoding];
    NSString *field = nil;
    for (NSString *part in [idString componentsSeparatedByString:@";"])
        if ([part hasPrefix:@"S:"]) { field = [part substringFromIndex:2]; break; }
    // Position map from HPLIP base/status.py (S-field revisions 0..4).
    if (field.length < 2) return @{@"known": @NO};
    unsigned revision;
    NSScanner *parser = [NSScanner scannerWithString:[field substringWithRange:NSMakeRange(1, 1)]];
    if (![parser scanHexInt:&revision] || revision > 4) return @{@"known": @NO};
    const unsigned positions[] = {14, 14, 14, 16, 20};
    unsigned position = positions[revision], code;
    if (field.length < position + 2) return @{@"known": @NO};
    parser = [NSScanner scannerWithString:[field substringWithRange:NSMakeRange(position, 2)]];
    if (![parser scanHexInt:&code]) return @{@"known": @NO};
    // 0x3x is one shared printhead-status category in HP's format.
    if ((code & 0xf0) == 0x30) code = 0x30;
    NSDictionary *messages = @{
        @0: @"Printer ready", @1: @"Printer busy", @2: @"Printing", @5: @"Cancelling the job",
        @9: @"Out of paper. Press the orange X (Cancel) button on the printer to clear the pending job. If the error remains, load paper and press On/Resume",
        @14: @"Paper jam. Clear the jam and press On/Resume",
        @15: @"Print carriage blocked", @16: @"Paper feed error",
        @17: @"Cartridge error. Check the cartridges and close the access door",
        @18: @"The printer reports a hardware error", @26: @"Out of ink",
        @41: @"The printer is waiting to resume cartridge alignment", @46: @"Printer in power-saving mode",
        @47: @"Incompatible cartridge", @48: @"Cartridge missing"};
    return @{@"known": @YES, @"code": @(1000 + code),
             @"message": messages[@(code)] ?: [NSString stringWithFormat:@"Printer status: %u", 1000 + code]};
}

static int optionIndex(const char *name) {
    for (int i = 1; i < 512; i++) {
        const SANE_Option_Descriptor *d = backend.get_option_descriptor(scanner, i);
        if (!d) break;
        if (d->name && !strcmp(d->name, name)) return i;
    }
    return -1;
}

static double numberValue(SANE_Word value, SANE_Value_Type type) {
    return type == SANE_TYPE_FIXED ? SANE_UNFIX(value) : value;
}

static NSDictionary *optionDetails(const char *name) {
    int index = optionIndex(name);
    if (index < 0) return @{};
    const SANE_Option_Descriptor *d = backend.get_option_descriptor(scanner, index);
    NSMutableDictionary *result = [@{@"active": @(SANE_OPTION_IS_ACTIVE(d->cap)),
                                    @"settable": @(SANE_OPTION_IS_SETTABLE(d->cap))} mutableCopy];
    if (d->constraint_type == SANE_CONSTRAINT_STRING_LIST) {
        NSMutableArray *values = [NSMutableArray array];
        for (const char *const *v = d->constraint.string_list; *v; v++) [values addObject:@(*v)];
        result[@"values"] = values;
    } else if (d->constraint_type == SANE_CONSTRAINT_WORD_LIST) {
        NSMutableArray *values = [NSMutableArray array];
        for (int i = 1; i <= d->constraint.word_list[0]; i++)
            [values addObject:@(numberValue(d->constraint.word_list[i], d->type))];
        result[@"values"] = values;
    } else if (d->constraint_type == SANE_CONSTRAINT_RANGE) {
        result[@"min"] = @(numberValue(d->constraint.range->min, d->type));
        result[@"max"] = @(numberValue(d->constraint.range->max, d->type));
        result[@"step"] = @(numberValue(d->constraint.range->quant, d->type));
    }
    return result;
}

static void setOption(const char *name, id value, BOOL optional) {
    int index = optionIndex(name);
    if (index < 0 && optional) return;
    if (index < 0) fail([NSString stringWithFormat:@"Option %s is missing", name]);
    const SANE_Option_Descriptor *d = backend.get_option_descriptor(scanner, index);
    if (!SANE_OPTION_IS_ACTIVE(d->cap) || !SANE_OPTION_IS_SETTABLE(d->cap)) {
        if (optional) return;
        fail([NSString stringWithFormat:@"Option %s is unavailable", name]);
    }
    NSMutableData *data = [NSMutableData dataWithLength:MAX(d->size, (int)sizeof(SANE_Word))];
    if (d->type == SANE_TYPE_STRING) {
        const char *s = [value UTF8String];
        if (strlen(s) >= data.length) fail(@"Option value is too long");
        strcpy(data.mutableBytes, s);
    } else {
        double v = [value doubleValue];
        if (optional && d->constraint_type == SANE_CONSTRAINT_RANGE) {
            v = fmin(v, numberValue(d->constraint.range->max, d->type));
            v = fmax(v, numberValue(d->constraint.range->min, d->type));
        }
        *(SANE_Word *)data.mutableBytes = d->type == SANE_TYPE_FIXED ? SANE_FIX(v) : (SANE_Word)v;
    }
    SANE_Int info = 0;
    check(backend.control_option(scanner, index, SANE_ACTION_SET_VALUE, data.mutableBytes, &info),
          [NSString stringWithFormat:@"Set option %s", name]);
}

static double readNumber(const char *name) {
    int index = optionIndex(name);
    if (index < 0) fail(@"The driver does not report a resolution");
    const SANE_Option_Descriptor *d = backend.get_option_descriptor(scanner, index);
    SANE_Word value = 0;
    check(backend.control_option(scanner, index, SANE_ACTION_GET_VALUE, &value, NULL), @"Read option");
    return numberValue(value, d->type);
}

static void saveImage(NSData *pixels, SANE_Parameters p, double dpi, NSString *output, BOOL overwrite) {
    NSString *extension = output.pathExtension.lowercaseString;
    NSDictionary *types = @{@"png": @"public.png", @"jpg": @"public.jpeg", @"jpeg": @"public.jpeg", @"tif": @"public.tiff", @"tiff": @"public.tiff"};
    if (!types[extension] && ![extension isEqual:@"pdf"]) fail(@"Supported file formats: png, jpg, tiff, pdf");
    CGColorSpaceRef space = p.format == SANE_FRAME_RGB ? CGColorSpaceCreateDeviceRGB() : CGColorSpaceCreateDeviceGray();
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)pixels);
    CGImageRef image = CGImageCreate(p.pixels_per_line, p.lines, 8, p.format == SANE_FRAME_RGB ? 24 : 8,
                                   p.bytes_per_line, space, (CGBitmapInfo)kCGImageAlphaNone, provider, NULL, false, kCGRenderingIntentDefault);
    CGColorSpaceRelease(space);
    CGDataProviderRelease(provider);
    if (!image) fail(@"Could not create the image");
    NSString *temp = [[output stringByDeletingLastPathComponent] stringByAppendingPathComponent:
                     [NSString stringWithFormat:@".hp-scan-%@.tmp", NSUUID.UUID.UUIDString]];
    @try {
        NSURL *url = [NSURL fileURLWithPath:temp];
        if ([extension isEqual:@"pdf"]) {
            CGRect page = CGRectMake(0, 0, p.pixels_per_line * 72.0 / dpi, p.lines * 72.0 / dpi);
            CGContextRef context = CGPDFContextCreateWithURL((__bridge CFURLRef)url, &page, NULL);
            if (!context) fail(@"Could not create the PDF");
            CGPDFContextBeginPage(context, NULL);
            CGContextDrawImage(context, page, image);
            CGPDFContextEndPage(context);
            CGPDFContextClose(context);
            CGContextRelease(context);
        } else {
            CGImageDestinationRef dest = CGImageDestinationCreateWithURL((__bridge CFURLRef)url,
                                        (__bridge CFStringRef)types[extension], 1, NULL);
            if (!dest) fail(@"Could not create the image file");
            NSDictionary *properties = @{(id)kCGImagePropertyDPIWidth: @(dpi), (id)kCGImagePropertyDPIHeight: @(dpi),
                                         (id)kCGImageDestinationLossyCompressionQuality: @0.95};
            CGImageDestinationAddImage(dest, image, (__bridge CFDictionaryRef)properties);
            BOOL saved = CGImageDestinationFinalize(dest);
            CFRelease(dest);
            if (!saved) fail(@"Could not save the image");
        }
        // Atomic publication; never clobber an existing scan without --overwrite.
        if (overwrite) {
            if (rename(temp.fileSystemRepresentation, output.fileSystemRepresentation)) fail(@(strerror(errno)));
        } else {
            if (link(temp.fileSystemRepresentation, output.fileSystemRepresentation)) fail(@(strerror(errno)));
        }
    } @finally {
        [[NSFileManager defaultManager] removeItemAtPath:temp error:NULL];
        CGImageRelease(image);
    }
}

static void scanTo(NSString *output, int requestedDpi, NSString *mode, BOOL overwrite, double width, double height) {
    setOption("mode", mode, NO);
    setOption("resolution", @(requestedDpi), NO);
    setOption("tl-x", @0, YES); setOption("tl-y", @0, YES);
    setOption("br-x", @(width), YES); setOption("br-y", @(height), YES);
    double dpi = readNumber("resolution");
    fprintf(stderr, "Resolution: %.0f DPI. Preparing the scanner…\n", dpi);
    if (interrupted) fail(@"Scan cancelled");
    check(backend.start(scanner), @"Start scanning");
    SANE_Parameters p;
    check(backend.get_parameters(scanner, &p), @"Read image parameters");
    if ((p.format != SANE_FRAME_RGB && p.format != SANE_FRAME_GRAY) || p.depth != 8 || !p.last_frame)
        fail(@"The driver returned an unsupported format. Use 8-bit Color or Gray");
    int channels = p.format == SANE_FRAME_RGB ? 3 : 1;
    if (p.pixels_per_line <= 0 || p.bytes_per_line < (int64_t)p.pixels_per_line * channels || p.lines == 0)
        fail(@"The driver returned invalid image dimensions");
    const NSUInteger limit = 512u * 1024u * 1024u;
    uint64_t expected = p.lines > 0 ? (uint64_t)p.lines * p.bytes_per_line : 0;
    if (expected > limit) fail(@"The image exceeds 512 MB. Lower the resolution");
    NSMutableData *pixels = [NSMutableData data];
    uint8_t buffer[65536];
    int previous = -1;
    while (!interrupted) {
        SANE_Int count = 0;
        SANE_Status status = backend.read(scanner, buffer, sizeof(buffer), &count);
        if (count < 0 || (NSUInteger)count > sizeof(buffer) || pixels.length + count > limit)
            fail(@"Image size limit exceeded");
        if (status != SANE_STATUS_EOF) check(status, @"Read image");
        if (count) [pixels appendBytes:buffer length:count];
        if (expected) {
            if (pixels.length > expected) fail(@"The driver returned more data than the declared frame size");
            int progress = (int)MIN(100, pixels.length * 100 / expected);
            if (progress != previous) { fprintf(stderr, "PROGRESS %d\n", progress); previous = progress; }
            // Old SCL firmware can omit the end-of-page marker at high DPI.
            // The declared, fully received frame is complete; don't request
            // another read that can wait indefinitely for an optional marker.
            if (pixels.length == expected) break;
        }
        if (status == SANE_STATUS_EOF) break;
        if (!count) usleep(10000);
    }
    backend.cancel(scanner);
    if (interrupted) fail(@"Scan cancelled");
    if (!pixels.length || (expected && pixels.length != expected) || pixels.length % p.bytes_per_line)
        fail(@"The scan returned an incomplete image. No file was saved");
    if (p.lines < 0) p.lines = (SANE_Int)(pixels.length / p.bytes_per_line);
    saveImage(pixels, p, dpi, output, overwrite);
    json(@{@"path": output, @"width": @(p.pixels_per_line), @"height": @(p.lines), @"dpi": @(dpi), @"mode": mode});
}

int main(void) {
    @autoreleasepool {
        signal(SIGINT, handleSignal); signal(SIGTERM, handleSignal);
        int lock = -1;
        @try {
            NSArray<NSString *> *args = NSProcessInfo.processInfo.arguments;
            if (args.count < 2 || [args[1] isEqual:@"--help"]) {
                puts("hp-scan list\nhp-scan status [--device ID]\nhp-scan options [--device ID]\nhp-scan scan --output FILE [--dpi 300] [--mode Color|Gray] [--device ID]\n             [--width 210] [--height 297] [--overwrite]\nOutput: PNG, JPEG, TIFF, PDF. Default page: A4; default mode: Color.");
                return 0;
            }
            NSString *command = args[1];
            if (![@[@"list", @"status", @"options", @"scan"] containsObject:command]) fail(@"Unknown command. See --help");
            NSMutableDictionary *settings = [NSMutableDictionary dictionary];
            BOOL overwrite = NO;
            NSSet *keys = [NSSet setWithArray:@[@"--output", @"--dpi", @"--mode", @"--device", @"--width", @"--height"]];
            for (NSUInteger i = 2; i < args.count; i++) {
                if ([args[i] isEqual:@"--overwrite"]) { overwrite = YES; continue; }
                if (![keys containsObject:args[i]] || i + 1 == args.count) fail(@"Invalid arguments. See --help");
                NSString *key = args[i++]; settings[key] = args[i];
            }
            NSString *output = nil;
            int dpi = 300;
            NSString *mode = settings[@"--mode"] ?: @"Color";
            double width = 210, height = 297;
            if ([command isEqual:@"scan"]) {
                NSString *path = settings[@"--output"];
                if (!path.length) fail(@"Specify --output /path/to/scan.png");
                output = path.stringByExpandingTildeInPath.stringByStandardizingPath;
                if (![output isAbsolutePath]) output = [NSFileManager.defaultManager.currentDirectoryPath stringByAppendingPathComponent:output];
                if (![@[@"png", @"jpg", @"jpeg", @"tif", @"tiff", @"pdf"] containsObject:output.pathExtension.lowercaseString])
                    fail(@"Supported file formats: png, jpg, tiff, pdf");
                if (!overwrite && [NSFileManager.defaultManager fileExistsAtPath:output]) fail(@"The file already exists. Choose another name or use --overwrite");
                BOOL isDirectory = NO;
                NSString *parent = output.stringByDeletingLastPathComponent;
                if (![NSFileManager.defaultManager fileExistsAtPath:parent isDirectory:&isDirectory] || !isDirectory || access(parent.fileSystemRepresentation, W_OK))
                    fail(@"The destination directory does not exist or is not writable");
                if (settings[@"--dpi"]) {
                    NSScanner *parser = [NSScanner scannerWithString:settings[@"--dpi"]];
                    if (![parser scanInt:&dpi] || !parser.isAtEnd) fail(@"Invalid resolution");
                }
                if (dpi < 75 || dpi > 600) fail(@"Resolution must be between 75 and 600 DPI");
                if (![@[@"Color", @"Gray"] containsObject:mode]) fail(@"Color mode must be Color or Gray");
                for (NSString *key in @[@"--width", @"--height"]) {
                    if (!settings[key]) continue;
                    double value;
                    NSScanner *parser = [NSScanner scannerWithString:settings[key]];
                    if (![parser scanDouble:&value] || !parser.isAtEnd || !isfinite(value) || value <= 0 || value > 400)
                        fail(@"Page dimensions must be greater than 0 and no more than 400 mm");
                    if ([key isEqual:@"--width"]) width = value; else height = value;
                }
            }
            NSString *lockPath = [NSString stringWithFormat:@"/private/tmp/hp-psc-1410-%u.lock", getuid()];
            lock = open(lockPath.fileSystemRepresentation, O_CREAT | O_RDWR | O_NOFOLLOW, 0600);
            if (lock < 0 || flock(lock, LOCK_EX | LOCK_NB)) fail(@"The scanner is already in use by another instance of HP Scan");
            loadBackend();
            NSArray *found = devices();
            if ([command isEqual:@"list"]) { json(found); return 0; }
            NSString *device = settings[@"--device"];
            if (!device) {
                for (NSDictionary *item in found)
                    if ([item[@"id"] rangeOfString:@"PSC_1400" options:NSCaseInsensitiveSearch].location != NSNotFound) { device = item[@"id"]; break; }
                if (!device && found.count == 1) device = found[0][@"id"];
            }
            if (!device) fail(found.count ? @"Multiple scanners found: specify --device" : @"No scanner found. Check the power and USB cable");
            NSDictionary *state = hardwareStatus(device);
            if ([command isEqual:@"status"]) { json(state); return 0; }
            if ([command isEqual:@"scan"] && [@[@1009, @1014, @1015, @1016, @1017, @1018, @1047, @1048] containsObject:state[@"code"]])
                fail([NSString stringWithFormat:@"%@ (HP %@)", state[@"message"], state[@"code"]]);
            NSString *name = [device hasPrefix:@"hpaio:"] ? [device substringFromIndex:6] : device;
            check(backend.open(name.UTF8String, &scanner), @"Open scanner");
            if ([command isEqual:@"options"])
                json(@{@"device": device, @"mode": optionDetails("mode"), @"resolution": optionDetails("resolution"),
                       @"width": optionDetails("br-x"), @"height": optionDetails("br-y"), @"status": state});
            else scanTo(output, dpi, mode, overwrite, width, height);
        } @catch (NSException *error) {
            fprintf(stderr, "%s\n", error.reason.UTF8String);
            return interrupted ? 130 : 1;
        } @finally {
            if (scanner) { backend.cancel(scanner); backend.close(scanner); }
            if (backend.exit) backend.exit();
            if (lock >= 0) close(lock);
        }
    }
    return 0;
}
