// Owns refocusing after a close: keeps a most-recently-used stack of windows, and when the
// focused window goes away and nothing else takes focus, raises the window used before it.
#import "features.h"
#import "windows.h"

// Closing a window sets off a burst of activations (the app picking another of its
// windows, the system picking another app); the check waits until the burst has been
// quiet this long, but never longer than the deadline.
static const NSTimeInterval kQuietSeconds = 0.15, kDeadlineSeconds = 0.8;
static const NSUInteger kStackLimit = 100;

/// AXUIElementRef windows, most recently focused first.
static NSMutableArray *stack;
static NSTimer *quietTimer;
static NSDate *pendingSince;

static void Remove(AXUIElementRef window) {
    for (id entry in stack.copy)
        if (CFEqual((__bridge CFTypeRef)entry, window)) [stack removeObject:entry];
}

static void Push(AXUIElementRef _Nullable window) {
    if (!window || !DKIsStandardWindow(window)) return;
    Remove(window);
    [stack insertObject:(__bridge id)window atIndex:0];
    if (stack.count > kStackLimit) [stack removeLastObject];
}

static void PushFocusedWindowOf(pid_t pid) {
    AXUIElementRef window = DKCopyFocusedWindow(pid);
    Push(window);
    if (window) CFRelease(window);
}

static void FocusNext(void) {
    NSMutableSet<NSNumber *> *visible = [NSMutableSet new];
    for (NSDictionary *info in DKWindowList(YES)) [visible addObject:info[(id)kCGWindowNumber]];
    for (id entry in stack.copy) {
        AXUIElementRef window = (__bridge AXUIElementRef)entry;
        if (![visible containsObject:@(DKWindowID(window))]) continue;
        AXUIElementRef app = AXUIElementCreateApplication(DKWindowOwner(window));
        // Setting the app frontmost through Accessibility works from the background, where
        // NSRunningApplication activation is refused since macOS 14.
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute, kCFBooleanTrue);
        AXUIElementSetAttributeValue(window, kAXMainAttribute, kCFBooleanTrue);
        AXUIElementPerformAction(window, kAXRaiseAction);
        CFRelease(app);
        Push(window);
        return;
    }
}

static void Settle(void) {
    [quietTimer invalidate];
    quietTimer = nil;
    pendingSince = nil;
    // The picker in front has focus even though it is no other app's window.
    if (NSRunningApplication.currentApplication.active) return;
    AXUIElementRef focused = DKCopyFocusedWindow(NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier);
    if (focused) return CFRelease(focused);
    FocusNext();
}

/// Starts or extends the wait for the activation burst to end.
static void Wait(void) {
    if (!pendingSince) pendingSince = NSDate.date;
    NSTimeInterval left = kDeadlineSeconds + pendingSince.timeIntervalSinceNow;
    [quietTimer invalidate];
    quietTimer = [NSTimer scheduledTimerWithTimeInterval:MAX(0, MIN(kQuietSeconds, left)) repeats:NO
                                                   block:^(NSTimer *timer) { Settle(); }];
}

/// Fills the stack with the windows on screen, front to back, so the first close after
/// launch already has somewhere to go.
static void Seed(void) {
    NSMutableDictionary<NSNumber *, id> *byID = [NSMutableDictionary new];
    for (NSRunningApplication *app in NSWorkspace.sharedWorkspace.runningApplications) {
        if (app.activationPolicy != NSApplicationActivationPolicyRegular) continue;
        for (id window in DKAppWindows(app.processIdentifier)) byID[@(DKWindowID((__bridge AXUIElementRef)window))] = window;
    }
    for (NSDictionary *info in DKWindowList(YES).reverseObjectEnumerator) {
        id window = byID[info[(id)kCGWindowNumber]];
        if (window) Push((__bridge AXUIElementRef)window);
    }
}

void DKStartRefocus(void) {
    stack = [NSMutableArray new];
    DKObserveWindows(^(DKWindowEvent event, AXUIElementRef window, pid_t pid) {
        switch (event) {
        case DKWindowFocused:
            Push(window);
            break;
        case DKAppActivated:
            PushFocusedWindowOf(pid);
            break;
        case DKWindowDestroyed: {
            BOOL wasFocused = stack.count && CFEqual((__bridge CFTypeRef)stack.firstObject, window);
            Remove(window);
            if (wasFocused) Wait();
            return;
        }
        case DKAppTerminated: {
            BOOL hadFocus = stack.count && DKWindowOwner((__bridge AXUIElementRef)stack.firstObject) == pid;
            for (id entry in stack.copy)
                if (DKWindowOwner((__bridge AXUIElementRef)entry) == pid) [stack removeObject:entry];
            if (hadFocus) Wait();
            return;
        }
        case DKWindowMinimized:
            Remove(window);
            return;
        case DKWindowCreated:
            return;
        }
        if (pendingSince) Wait();
    });
    Seed();
}
