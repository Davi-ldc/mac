// Owns Ghostty-only behaviour: cmd+q quits it only after being held, and cmd+v pastes a
// copied image. Both follow the front app, so nothing changes while another app is in front.
#import <AppKit/AppKit.h>

#import "alert.h"
#import "features.h"
#import "hotkey.h"

static NSString *const kGhostty = @"com.mitchellh.ghostty";
static const NSTimeInterval kQuitHoldSeconds = 0.35;

#pragma mark Hold to quit

static DKHotkey *quitKey;
static NSTimer *quitTimer;

static void CancelQuit(void) {
    [quitTimer invalidate];
    quitTimer = nil;
    DKHideAlert();
}

// The shortcut exists only while Ghostty is in front, so cmd+q stays normal elsewhere.
static void FollowQuit(BOOL ghostty) {
    if (ghostty && !quitKey) {
        quitKey = [DKHotkey key:kVK_ANSI_Q modifiers:cmdKey handler:^(BOOL pressed) {
            // Every press starts a new hold; a timer left from an earlier one would quit early.
            CancelQuit();
            if (!pressed) return;
            DKShowAlert(@"hold", kQuitHoldSeconds);
            quitTimer = [NSTimer scheduledTimerWithTimeInterval:kQuitHoldSeconds repeats:NO block:^(NSTimer *t) {
                CancelQuit();
                [[NSRunningApplication runningApplicationsWithBundleIdentifier:kGhostty].firstObject terminate];
            }];
        }];
    } else if (!ghostty && quitKey) {
        CancelQuit();
        [quitKey unregister];
        quitKey = nil;
    }
}

#pragma mark Image paste

// Ghostty's cmd+v pastes text only, while Claude Code reads an image from the clipboard on
// ctrl+v. So while Ghostty is in front and the clipboard holds an image and no text, cmd+v
// goes on as ctrl+v. The tap sees key presses only while Ghostty is in front, and lets
// every other one through untouched.

static CFMachPortRef pasteTap;
static BOOL ghosttyInFront;
/// The v key went down as ctrl+v, so its release is sent as ctrl+v too.
static BOOL rewriting;

BOOL DKPasteboardHoldsOnlyImage(NSPasteboard *pasteboard) {
    NSArray<NSPasteboardType> *types = pasteboard.types;
    if ([types containsObject:NSPasteboardTypeString]) return NO;
    if ([types containsObject:NSPasteboardTypePNG] || [types containsObject:NSPasteboardTypeTIFF]) return YES;
    return [pasteboard canReadObjectForClasses:@[ NSURL.class ] options:@{
        NSPasteboardURLReadingFileURLsOnlyKey : @YES,
        NSPasteboardURLReadingContentsConformToTypesKey : @[ @"public.image" ],
    }];
}

static CGEventRef RewritePaste(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *info) {
    // The system turns off a tap it thinks is too slow; it stays on only while it is needed.
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        CGEventTapEnable(pasteTap, ghosttyInFront);
        return event;
    }
    if (CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode) != kVK_ANSI_V) return event;
    CGEventFlags flags = CGEventGetFlags(event);
    if (type == kCGEventKeyUp) {
        if (!rewriting) return event;
        rewriting = NO;
    } else {
        const CGEventFlags modifiers =
            kCGEventFlagMaskCommand | kCGEventFlagMaskControl | kCGEventFlagMaskAlternate | kCGEventFlagMaskShift;
        rewriting = ghosttyInFront && (flags & modifiers) == kCGEventFlagMaskCommand &&
                    DKPasteboardHoldsOnlyImage(NSPasteboard.generalPasteboard);
        if (!rewriting) return event;
    }
    CGEventSetFlags(event, (flags & ~kCGEventFlagMaskCommand) | kCGEventFlagMaskControl);
    return event;
}

// Making the tap needs Accessibility; without it this is tried again on the next switch to
// Ghostty or change of the permission.
static void FollowPaste(BOOL ghostty) {
    ghosttyInFront = ghostty;
    if (ghostty && !pasteTap) {
        pasteTap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault,
                                    CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp), RewritePaste, NULL);
        if (!pasteTap) return;
        CFRunLoopSourceRef source = CFMachPortCreateRunLoopSource(NULL, pasteTap, 0);
        CFRunLoopAddSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);
        CFRelease(source);
    }
    if (pasteTap) CGEventTapEnable(pasteTap, ghostty);
}

#pragma mark Following the front app

static void Follow(NSRunningApplication *front) {
    BOOL ghostty = [front.bundleIdentifier isEqualToString:kGhostty];
    FollowQuit(ghostty);
    FollowPaste(ghostty);
}

static void AccessibilityChanged(CFNotificationCenterRef center, void *observer, CFNotificationName name,
                                 const void *object, CFDictionaryRef info) {
    // The new permission applies a moment after the notification.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(),
                   ^{ Follow(NSWorkspace.sharedWorkspace.frontmostApplication); });
}

void DKStartGhostty(void) {
    [NSWorkspace.sharedWorkspace.notificationCenter addObserverForName:NSWorkspaceDidActivateApplicationNotification
                                                                object:nil
                                                                 queue:nil
                                                            usingBlock:^(NSNotification *note) {
        Follow(note.userInfo[NSWorkspaceApplicationKey]);
    }];
    CFNotificationCenterAddObserver(CFNotificationCenterGetDistributedCenter(), NULL, AccessibilityChanged,
                                    CFSTR("com.apple.accessibility.api"), NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    Follow(NSWorkspace.sharedWorkspace.frontmostApplication);
}
