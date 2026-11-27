// Owns cmd+shift+c, which opens Claude Code in a new Ghostty tab on the Clad folder, and
// `deskkit --claude`, the same from a terminal.
#import <AppKit/AppKit.h>
#import <os/log.h>

#import "features.h"
#import "hotkey.h"

// The decision waits for cmd and shift to be released, so "r" can still be added.
static const NSTimeInterval kClaudeGiveUpSeconds = 3;
// The modifiers are polled because watching key events would need Accessibility. The
// polling lasts only while the shortcut is held, and at this interval the release is
// acted on within one frame.
static const NSTimeInterval kReleasePollSeconds = 0.005;

static NSTimer *claudeWatch;
static NSArray<DKHotkey *> *resumeKeys;

static NSString *AppleScriptLiteral(NSString *text) {
    text = [text stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    text = [text stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    return [NSString stringWithFormat:@"\"%@\"", text];
}

BOOL DKOpenClaude(NSString *arguments) {
    CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
    NSString *folder = [NSHomeDirectory() stringByAppendingPathComponent:@"Desktop/clad"];
    [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES
                                             attributes:nil error:nil];
    NSString *command = [@"claude --dangerously-skip-permissions " stringByAppendingString:arguments];
    // Every statement Ghostty must answer costs a round trip of tens of milliseconds, so
    // activating does not wait for its answer and a missing window is found by failing to
    // open the tab rather than by counting windows first. The script runs on the main
    // thread: the timeout bounds how long a hung Ghostty can hold the other shortcuts.
    NSString *source = [NSString stringWithFormat:
        @"tell application \"Ghostty\"\n"
         "  ignoring application responses\n"
         "    activate\n"
         "  end ignoring\n"
         "  with timeout of 5 seconds\n"
         "    set cfg to new surface configuration\n"
         "    set initial working directory of cfg to %@\n"
         "    set initial input of cfg to %@ & linefeed\n"
         "    try\n"
         "      new tab in front window with configuration cfg\n"
         "    on error\n"
         "      new window with configuration cfg\n"
         "    end try\n"
         "  end timeout\n"
         "end tell",
        AppleScriptLiteral(folder), AppleScriptLiteral(command)];
    NSDictionary *error;
    if (![[[NSAppleScript alloc] initWithSource:source] executeAndReturnError:&error]) {
        fprintf(stderr, "deskkit: cannot open Claude in Ghostty: %s\n",
                [error[NSAppleScriptErrorMessage] UTF8String]);
        return NO;
    }
    // Read with: log show --last 1h --predicate 'process == "deskkit"'
    os_log(OS_LOG_DEFAULT, "claude tab opened in %.1f ms", (CFAbsoluteTimeGetCurrent() - started) * 1000);
    return YES;
}

static void FinishClaude(NSString *_Nullable arguments) {
    [claudeWatch invalidate];
    claudeWatch = nil;
    for (DKHotkey *key in resumeKeys) [key unregister];
    resumeKeys = nil;
    if (arguments) DKOpenClaude(arguments);
}

static BOOL CommandOrShiftHeld(void) {
    CGEventFlags flags = CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState);
    return (flags & (kCGEventFlagMaskCommand | kCGEventFlagMaskShift)) != 0;
}

void DKStartClaudeShortcut(void) {
    [DKHotkey key:kVK_ANSI_C modifiers:cmdKey | shiftKey handler:^(BOOL pressed) {
        if (!pressed || claudeWatch) return;
        // "r" counts with whichever of the two modifiers is still held.
        NSMutableArray *keys = [NSMutableArray new];
        for (NSNumber *modifiers in @[ @(cmdKey | shiftKey), @(cmdKey), @(shiftKey) ]) {
            DKHotkey *r = [DKHotkey key:kVK_ANSI_R modifiers:modifiers.unsignedIntValue
                                handler:^(BOOL down) {
                if (down) FinishClaude(@"--resume");
            }];
            if (r) [keys addObject:r];
        }
        resumeKeys = keys;
        NSDate *started = [NSDate date];
        claudeWatch = [NSTimer scheduledTimerWithTimeInterval:kReleasePollSeconds repeats:YES
                                                        block:^(NSTimer *t) {
            if (!CommandOrShiftHeld()) FinishClaude(@"");
            else if (-started.timeIntervalSinceNow > kClaudeGiveUpSeconds) FinishClaude(nil);
        }];
    }];
}
