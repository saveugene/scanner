// Exercise actual ImageIO/PDF output, dimensions, DPI and non-overwrite behavior.
#define main scanner_cli_main
#include "../src/scanner.m"
#undef main

int main(void) {
    @autoreleasepool {
        NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL];
        @try {
            for (int channels = 1; channels <= 3; channels += 2) {
                SANE_Parameters p = {.format = channels == 3 ? SANE_FRAME_RGB : SANE_FRAME_GRAY,
                    .last_frame = SANE_TRUE, .bytes_per_line = 32 * channels, .pixels_per_line = 32, .lines = 24, .depth = 8};
                NSMutableData *pixels = [NSMutableData dataWithLength:p.bytes_per_line * p.lines];
                for (NSUInteger i = 0; i < pixels.length; i++) ((uint8_t *)pixels.mutableBytes)[i] = (uint8_t)i;
                for (NSString *extension in @[@"png", @"jpg", @"tiff", @"pdf"]) {
                    NSString *path = [directory stringByAppendingPathComponent:[NSString stringWithFormat:@"test-%d.%@", channels, extension]];
                    saveImage(pixels, p, 300, path, NO);
                    NSURL *url = [NSURL fileURLWithPath:path];
                    if ([extension isEqual:@"pdf"]) {
                        CGPDFDocumentRef pdf = CGPDFDocumentCreateWithURL((__bridge CFURLRef)url);
                        assert(pdf && CGPDFDocumentGetNumberOfPages(pdf) == 1);
                        CGRect page = CGPDFPageGetBoxRect(CGPDFDocumentGetPage(pdf, 1), kCGPDFMediaBox);
                        assert(fabs(page.size.width - 32 * 72.0 / 300) < 0.001);
                        assert(fabs(page.size.height - 24 * 72.0 / 300) < 0.001);
                        CGPDFDocumentRelease(pdf);
                    } else {
                        CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
                        assert(source);
                        NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
                        assert([properties[(id)kCGImagePropertyPixelWidth] intValue] == 32);
                        assert([properties[(id)kCGImagePropertyPixelHeight] intValue] == 24);
                        assert(fabs([properties[(id)kCGImagePropertyDPIWidth] doubleValue] - 300) < 0.1);
                        CFRelease(source);
                    }
                    NSData *before = [NSData dataWithContentsOfFile:path];
                    BOOL rejected = NO;
                    @try { saveImage(pixels, p, 300, path, NO); }
                    @catch (NSException *error) { rejected = YES; }
                    assert(rejected && [before isEqual:[NSData dataWithContentsOfFile:path]]);
                }
            }
            puts("PASS: RGB/gray PNG, JPEG, TIFF, PDF; image dimensions, DPI, atomic non-overwrite");
        } @finally { [NSFileManager.defaultManager removeItemAtPath:directory error:NULL]; }
    }
    return 0;
}
