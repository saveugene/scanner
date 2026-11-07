// Verify legacy frames without an EOF marker and reject partial/error frames.
#define main scanner_cli_main
#include "../src/scanner.m"
#undef main

static int scenario, reads;
static SANE_Option_Descriptor options[] = {
    {0},
    {.name = "mode", .type = SANE_TYPE_STRING, .size = 16, .cap = SANE_CAP_SOFT_SELECT},
    {.name = "resolution", .type = SANE_TYPE_INT, .size = sizeof(SANE_Word), .cap = SANE_CAP_SOFT_SELECT}
};
static const SANE_Option_Descriptor *fakeDescriptor(SANE_Handle h, SANE_Int i) {
    (void)h;
    return i >= 0 && i < 3 ? &options[i] : NULL;
}
static SANE_Status fakeControl(SANE_Handle h, SANE_Int i, SANE_Action action, void *value, SANE_Int *info) {
    (void)h; (void)i;
    if (action == SANE_ACTION_GET_VALUE) *(SANE_Word *)value = 600;
    if (info) *info = 0;
    return SANE_STATUS_GOOD;
}
static SANE_Status fakeStart(SANE_Handle h) { (void)h; return SANE_STATUS_GOOD; }
static void fakeCancel(SANE_Handle h) { (void)h; }
static SANE_Status fakeParameters(SANE_Handle h, SANE_Parameters *p) {
    (void)h;
    *p = (SANE_Parameters){.format = SANE_FRAME_GRAY, .last_frame = SANE_TRUE,
                          .bytes_per_line = 8, .pixels_per_line = 8, .lines = scenario == 3 ? -1 : 2, .depth = 8};
    return SANE_STATUS_GOOD;
}
static SANE_Status fakeRead(SANE_Handle h, SANE_Byte *data, SANE_Int max, SANE_Int *length) {
    (void)h; (void)max;
    reads++;
    if (scenario == 3 && reads == 3) { *length = 0; return SANE_STATUS_EOF; }
    assert(reads <= 2); // A complete, known-size frame must not request an EOF read.
    if (scenario == 1 && reads == 2) { *length = 0; return SANE_STATUS_EOF; }
    memset(data, 128, 8);
    *length = 8;
    return scenario == 2 && reads == 2 ? SANE_STATUS_IO_ERROR : SANE_STATUS_GOOD;
}

int main(void) {
    @autoreleasepool {
        NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL];
        backend = (Backend){.get_option_descriptor = fakeDescriptor, .control_option = fakeControl,
            .start = fakeStart, .cancel = fakeCancel, .get_parameters = fakeParameters, .read = fakeRead};
        @try {
            for (scenario = 0; scenario <= 3; scenario++) {
                reads = 0;
                NSString *output = [directory stringByAppendingPathComponent:[NSString stringWithFormat:@"frame-%d.png", scenario]];
                BOOL failed = NO;
                @try { scanTo(output, 600, @"Gray", NO, 210, 297); }
                @catch (NSException *error) { failed = YES; }
                BOOL shouldFail = scenario == 1 || scenario == 2;
                assert(failed == shouldFail);
                assert([NSFileManager.defaultManager fileExistsAtPath:output] == !shouldFail);
                assert(reads == (scenario == 3 ? 3 : 2));
            }
            puts("PASS: complete frame without EOF; partial/error rejection; unknown-height EOF");
        } @finally { [NSFileManager.defaultManager removeItemAtPath:directory error:NULL]; }
    }
    return 0;
}
