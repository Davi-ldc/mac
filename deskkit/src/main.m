// One small background app doing the jobs of Raycast, Hammerspoon and Rectangle on this
// Mac: the launcher and clipboard history, the Claude and Ghostty shortcuts, closing apps
// with their last window, screenshots to the clipboard, and window snapping.
//
// Environment: DESKKIT_SHOW=<screen> only opens that launcher screen (see
// DKInspectLauncher); DESKKIT_NO_PROMPT=1 skips the Accessibility prompt; DESKKIT_HOME and
// DESKKIT_KEYCHAIN_SERVICE move the data folder and the Keychain item.
#import <AppKit/AppKit.h>

#import "bench.h"
#import "features.h"

int DKSelfTest(void);

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc > 1 && !strcmp(argv[1], "--selftest")) return DKSelfTest();
        if (argc > 2 && !strcmp(argv[1], "--rank")) return DKPrintRanking(@(argv[2]), argc > 3 ? (NSUInteger)atoi(argv[3]) : 10);
        if (argc > 1 && !strcmp(argv[1], "--bench")) {
            NSArray<NSString *> *arguments = NSProcessInfo.processInfo.arguments;
            return DKBench([arguments subarrayWithRange:NSMakeRange(2, arguments.count - 2)]);
        }
        if (argc > 1 && !strcmp(argv[1], "--claude")) {
            NSArray<NSString *> *arguments = NSProcessInfo.processInfo.arguments;
            arguments = [arguments subarrayWithRange:NSMakeRange(2, arguments.count - 2)];
            return DKOpenClaude([arguments componentsJoinedByString:@" "]) ? 0 : 1;
        }

        NSApplication *app = NSApplication.sharedApplication;
        app.activationPolicy = NSApplicationActivationPolicyAccessory;
        const char *show = getenv("DESKKIT_SHOW");
        if (show) {
            NSString *screen = @(show);
            dispatch_async(dispatch_get_main_queue(), ^{ DKInspectLauncher(screen); });
            [app run];
            return 0;
        }
        // Window moves, the window rules and pasting all go through Accessibility. Each
        // feature notices a later grant by itself, so this only asks for it.
        if (!getenv("DESKKIT_NO_PROMPT") &&
            !AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{(__bridge id)kAXTrustedCheckOptionPrompt : @YES}))
            fprintf(stderr, "deskkit: waiting for Accessibility\n");
        DKStartClipboardHistory();
        DKStartLauncher();
        DKStartClaudeShortcut();
        DKStartGhostty();
        DKStartLastWindowRule();
        DKStartRefocus();
        DKStartSnapping();
        DKStartScreenshotCopy();
        [app run];
    }
    return 0;
}
