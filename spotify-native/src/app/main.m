// Spotify Native entrypoint: overlapped Keychain+SQLite launch preload; dev builds also host --selftest, --memory, --bench.
#import <AppKit/AppKit.h>

#import "app/app.h"
#import "app/trace.h"

#ifndef SP_RELEASE
int SPRunSelfTest(NSString *repoRoot, NSArray<NSString *> *filters);
int SPRunMemoryFixtureGen(NSString *dirPath);
int SPRunMemoryBenchmark(void);
int SPRunPerfBenchmark(void);
#endif

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        SPTraceInit();
        SPTraceLaunch("launch:main");

#ifndef SP_RELEASE
        if (argc >= 2) {
            NSString *mode = @(argv[1]);
            if ([mode isEqualToString:@"--selftest"]) {
                NSString *repoRoot = argc >= 3 ? @(argv[2]) : NSFileManager.defaultManager.currentDirectoryPath;
                NSMutableArray<NSString *> *filters = [NSMutableArray new];
                for (int i = 3; i < argc; i++) {
                    NSString *f = @(argv[i]);
                    if (f.length) [filters addObject:f];
                }
                return SPRunSelfTest(repoRoot, filters);
            }
            if ([mode isEqualToString:@"--memory-gen-fixture"] && argc >= 3) {
                return SPRunMemoryFixtureGen(@(argv[2]));
            }
            if ([mode isEqualToString:@"--memory"]) {
                return SPRunMemoryBenchmark();
            }
            if ([mode isEqualToString:@"--bench"]) {
                return SPRunPerfBenchmark();
            }
        }
#endif

        // Kick off Keychain read + SQLite WAL open + theme setup BEFORE AppKit bootstrap so they overlap.
        SPAppPreload *preload = [SPAppPreload startAsync];

        NSApplication *app = [NSApplication sharedApplication];
        app.activationPolicy = NSApplicationActivationPolicyRegular;
        SPApplySavedAppearancePreference();

        __attribute__((objc_precise_lifetime)) SPAppController *controller = [SPAppController new];
        controller.preload = preload;
        app.delegate = controller;

        [app run];
        return 0;
    }
}
