// Headless self-test runner invoked by `--selftest` in dev builds (runs all M1 + M2 unit & UI tests).
#import "test.h"
#import "render/images.h"
#import "store/change.h"

#import <AppKit/AppKit.h>
#import <mach/mach.h>
#import <mach/mach_time.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>

typedef struct {
    const char *name;
    SPTestFunction fn;
} SPTestEntry;

static SPTestEntry gTests[512];
static int gTestCount = 0;
static int gCurrentFailures = 0;
static int gTotalFailures = 0;
static NSString *gRepoRoot = nil;

void SPRegisterTest(const char *name, SPTestFunction fn) {
    if (gTestCount < (int)(sizeof(gTests) / sizeof(gTests[0]))) {
        gTests[gTestCount++] = (SPTestEntry){name, fn};
    }
}

void SPFailTest(const char *file, int line, NSString *message) {
    gCurrentFailures++;
    const char *base = strrchr(file, '/');
    fprintf(stderr, "    FAIL %s:%d: %s\n", base ? base + 1 : file, line, message.UTF8String);
}

NSString *SPTestRepoRoot(void) {
    return gRepoRoot ?: NSFileManager.defaultManager.currentDirectoryPath;
}

NSURL *SPTestTempDirectory(NSString *prefix) {
    NSString *name = [NSString stringWithFormat:@"%@-%@", prefix ?: @"sp-test", NSUUID.UUID.UUIDString];
    NSURL *dir = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES] URLByAppendingPathComponent:name isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

BOOL SPWaitUntil(NSTimeInterval timeoutSeconds, BOOL (^predicate)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeoutSeconds];
    while (!predicate()) {
        if (deadline.timeIntervalSinceNow <= 0) return NO;
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
    }
    return YES;
}

static int CompareTests(const void *a, const void *b) {
    return strcmp(((const SPTestEntry *)a)->name, ((const SPTestEntry *)b)->name);
}

static double NowSeconds(void) {
    static mach_timebase_info_data_t tb;
    if (tb.denom == 0) mach_timebase_info(&tb);
    uint64_t t = mach_absolute_time();
    return (double)t * (double)tb.numer / (double)tb.denom / 1e9;
}

static double ResidentMemoryMB(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) == KERN_SUCCESS) {
        return (double)info.phys_footprint / (1024.0 * 1024.0);
    }
    return 0.0;
}

int SPRunSelfTest(NSString *repoRoot, NSArray<NSString *> *filters) {
    @autoreleasepool {
        // Headless AppKit setup: never show Dock icon, never activate, never fetch remote artwork.
        NSApplication *app = [NSApplication sharedApplication];
        app.activationPolicy = NSApplicationActivationPolicyProhibited;
        app.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
        SPSetImageNetworkEnabled(NO);

        gRepoRoot = repoRoot.length ? repoRoot : NSFileManager.defaultManager.currentDirectoryPath;
        gTotalFailures = 0;

        qsort(gTests, (size_t)gTestCount, sizeof(SPTestEntry), CompareTests);

        double startAll = NowSeconds();
        int ran = 0;
        int passed = 0;

        for (int i = 0; i < gTestCount; i++) {
            NSString *name = @(gTests[i].name);
            if (filters.count > 0) {
                BOOL matched = NO;
                for (NSString *f in filters) {
                    if ([name rangeOfString:f options:NSCaseInsensitiveSearch].location != NSNotFound) {
                        matched = YES;
                        break;
                    }
                }
                if (!matched) continue;
            }
            ran++;
            gCurrentFailures = 0;
            double t0 = NowSeconds();
            @autoreleasepool {
                SPSetImageFetcher(nil);
                SPSetImageNetworkEnabled(NO);
                gTests[i].fn();
                SPFlushChanges();
                // Drain deferred post-CA image releases between tests so each test starts clean.
                [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
            }
            double elapsedMs = (NowSeconds() - t0) * 1000.0;
            if (gCurrentFailures == 0) {
                passed++;
                printf("  PASS %-56s (%.2f ms)\n", gTests[i].name, elapsedMs);
            } else {
                gTotalFailures += gCurrentFailures;
                printf("  FAIL %-56s (%.2f ms, %d failure%s)\n",
                       gTests[i].name, elapsedMs, gCurrentFailures, gCurrentFailures == 1 ? "" : "s");
            }
            fflush(stdout);
        }

        double totalMs = (NowSeconds() - startAll) * 1000.0;
        printf("\n%d/%d tests passed in %.2f ms (RAM %.2f MB)\n", passed, ran, totalMs, ResidentMemoryMB());
        return (gTotalFailures == 0 && ran > 0) ? 0 : 1;
    }
}
