// Owns pasting into another app: waiting for it to come forward, then a synthetic ⌘V.
#import <Carbon/Carbon.h>

#import "paste.h"

// How long the app being returned to has to come to the front; after that the paste is
// dropped rather than sent to whatever is in front instead.
static const NSTimeInterval kPasteWaitSeconds = 1;

static void PostPaste(void) {
    CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateCombinedSessionState);
    for (NSNumber *down in @[ @YES, @NO ]) {
        CGEventRef key = CGEventCreateKeyboardEvent(source, kVK_ANSI_V, down.boolValue);
        CGEventSetFlags(key, kCGEventFlagMaskCommand);
        CGEventPost(kCGHIDEventTap, key);
        CFRelease(key);
    }
    CFRelease(source);
}

void DKPasteInto(NSRunningApplication *app) {
    if (app.active) return PostPaste();
    __block id observer;
    void (^stop)(void) = ^{
        if (observer) [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:observer];
        observer = nil;
    };
    observer = [NSWorkspace.sharedWorkspace.notificationCenter addObserverForName:NSWorkspaceDidActivateApplicationNotification
                                                                           object:nil queue:nil
                                                                       usingBlock:^(NSNotification *note) {
        if ([note.userInfo[NSWorkspaceApplicationKey] processIdentifier] != app.processIdentifier) return;
        stop();
        PostPaste();
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kPasteWaitSeconds * NSEC_PER_SEC)), dispatch_get_main_queue(), stop);
}
