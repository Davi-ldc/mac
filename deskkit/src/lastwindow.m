// Owns the last-window rule: closing the last window of a Dock app quits it, like on
// Windows. Menu bar apps and the apps listed below keep running.
#import "features.h"
#import "windows.h"

// Gives an app time to replace a closing window without ever having none.
static const NSTimeInterval kQuitDelaySeconds = 0.8;
// A launching app can close its splash screen before the main window opens, so only an
// app that has shown a standard window for this long can be quit.
static const NSTimeInterval kSettledSeconds = 5;

/// When each app was first seen with a standard window, by pid.
static NSMutableDictionary<NSNumber *, NSDate *> *standardSince;
static NSDate *startedAt;

static NSSet<NSString *> *KeepRunning(void) {
    return [NSSet setWithObjects:@"com.apple.finder", @"com.mitchellh.ghostty", nil];
}

static BOOL Settled(NSRunningApplication *app) {
    // Apps that were running before deskkit started finished launching long ago.
    if (app.launchDate && [app.launchDate compare:startedAt] == NSOrderedAscending) return YES;
    NSDate *since = standardSince[@(app.processIdentifier)];
    return since && -since.timeIntervalSinceNow >= kSettledSeconds;
}

/// Accessibility lists only windows on the current Space; the window server lists them
/// all, including ones parked off screen. Counting those means an app with a window on
/// another Space is never quit, at the price of sometimes keeping an app whose only
/// windows were hidden helpers.
static BOOL HasWindowAnywhere(pid_t pid) {
    if (DKAppWindows(pid).count) return YES;
    for (NSDictionary *window in DKWindowList(NO)) {
        if ([window[(id)kCGWindowOwnerPID] intValue] != pid || [window[(id)kCGWindowAlpha] doubleValue] <= 0) continue;
        CGRect bounds;
        CGRectMakeWithDictionaryRepresentation((CFDictionaryRef)window[(id)kCGWindowBounds], &bounds);
        if (bounds.size.width >= 100 && bounds.size.height >= 100) return YES;
    }
    return NO;
}

static void QuitIfWindowless(pid_t pid) {
    NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    if (!app || app.terminated || app.activationPolicy != NSApplicationActivationPolicyRegular ||
        [KeepRunning() containsObject:app.bundleIdentifier ?: @""] || !Settled(app) || HasWindowAnywhere(pid))
        return;
    [app terminate];
}

void DKStartLastWindowRule(void) {
    standardSince = [NSMutableDictionary new];
    startedAt = NSDate.date;
    DKObserveWindows(^(DKWindowEvent event, AXUIElementRef window, pid_t pid) {
        switch (event) {
        case DKWindowCreated:
        case DKWindowFocused:
            if (!standardSince[@(pid)] && DKIsStandardWindow(window)) standardSince[@(pid)] = NSDate.date;
            break;
        case DKWindowDestroyed:
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kQuitDelaySeconds * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ QuitIfWindowless(pid); });
            break;
        case DKAppTerminated:
            [standardSince removeObjectForKey:@(pid)];
            break;
        case DKWindowMinimized:
        case DKAppActivated:
            break;
        }
    });
}
