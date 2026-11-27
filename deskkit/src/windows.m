// Owns the per-app AXObservers, the Accessibility timeout, and the window queries.
#import "windows.h"

// Private but stable: every window manager on macOS (Rectangle, yabai, AeroSpace) uses it
// to match an Accessibility window with the window server's list.
extern AXError _AXUIElementGetWindow(AXUIElementRef element, CGWindowID *identifier);

// A hung app would otherwise hold the main thread for the system default of six seconds
// on every call.
static const float kMessagingTimeout = 0.3;
// An app still launching often cannot answer yet; it is tried again after 0.5, 1, 2 and 4
// seconds, and after that whenever it comes to the front.
static const int kObserveAttempts = 5;

static NSMutableArray<DKWindowEventHandler> *handlers;
/// AXObservers of the apps whose notifications are registered, by pid.
static NSMutableDictionary<NSNumber *, id> *observers;

static void SetTimeout(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Set on the system-wide element, the timeout applies to every element.
        AXUIElementRef system = AXUIElementCreateSystemWide();
        AXUIElementSetMessagingTimeout(system, kMessagingTimeout);
        CFRelease(system);
    });
}

static void Emit(DKWindowEvent event, AXUIElementRef _Nullable window, pid_t pid) {
    for (DKWindowEventHandler handler in handlers) handler(event, window, pid);
}

static void Callback(AXObserverRef observer, AXUIElementRef element, CFStringRef notification, void *refcon) {
    pid_t pid = (pid_t)(intptr_t)refcon;
    if (CFEqual(notification, kAXWindowCreatedNotification)) {
        // A window can only report its own destruction, so each one is watched as it appears.
        AXObserverAddNotification(observer, element, kAXUIElementDestroyedNotification, refcon);
        Emit(DKWindowCreated, element, pid);
    } else if (CFEqual(notification, kAXUIElementDestroyedNotification)) {
        Emit(DKWindowDestroyed, element, pid);
    } else if (CFEqual(notification, kAXFocusedWindowChangedNotification)) {
        Emit(DKWindowFocused, element, pid);
    } else if (CFEqual(notification, kAXWindowMiniaturizedNotification)) {
        Emit(DKWindowMinimized, element, pid);
    }
}

static BOOL Watched(NSRunningApplication *app) {
    return app.activationPolicy == NSApplicationActivationPolicyRegular && app.processIdentifier != getpid() &&
           !app.terminated;
}

/// Registers the app's notifications. Returns NO, keeping nothing, while its Accessibility
/// cannot answer (still launching, or deskkit not allowed yet).
static BOOL Observe(pid_t pid) {
    if (observers[@(pid)]) return YES;
    AXObserverRef observer;
    if (AXObserverCreate(pid, Callback, &observer) != kAXErrorSuccess) return NO;
    void *refcon = (void *)(intptr_t)pid;
    AXUIElementRef app = AXUIElementCreateApplication(pid);
    BOOL registered = YES;
    for (NSString *name in @[ (id)kAXWindowCreatedNotification, (id)kAXFocusedWindowChangedNotification,
                              (id)kAXWindowMiniaturizedNotification ]) {
        AXError error = AXObserverAddNotification(observer, app, (__bridge CFStringRef)name, refcon);
        registered = registered && (error == kAXErrorSuccess || error == kAXErrorNotificationAlreadyRegistered);
    }
    CFRelease(app);
    if (!registered) {
        CFRelease(observer);
        return NO;
    }
    for (id window in DKAppWindows(pid))
        AXObserverAddNotification(observer, (__bridge AXUIElementRef)window, kAXUIElementDestroyedNotification, refcon);
    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), kCFRunLoopDefaultMode);
    observers[@(pid)] = CFBridgingRelease(observer);
    return YES;
}

static void ObserveWithRetry(NSRunningApplication *app, int attempt) {
    // Without permission every attempt fails; the permission change itself triggers a retry.
    if (!Watched(app) || !AXIsProcessTrusted() || Observe(app.processIdentifier) || attempt + 1 >= kObserveAttempts) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * (1 << attempt) * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ ObserveWithRetry(app, attempt + 1); });
}

static void ObserveAll(void) {
    for (NSRunningApplication *app in NSWorkspace.sharedWorkspace.runningApplications) ObserveWithRetry(app, 0);
}

static void AccessibilityChanged(CFNotificationCenterRef center, void *observer, CFNotificationName name,
                                 const void *object, CFDictionaryRef info) {
    // The new permission applies a moment after the notification.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        fprintf(stderr, "deskkit: Accessibility %s\n", AXIsProcessTrusted() ? "granted" : "not granted");
        ObserveAll();
    });
}

static void Start(void) {
    SetTimeout();
    observers = [NSMutableDictionary new];
    ObserveAll();
    NSNotificationCenter *center = NSWorkspace.sharedWorkspace.notificationCenter;
    [center addObserverForName:NSWorkspaceDidLaunchApplicationNotification object:nil queue:nil
                    usingBlock:^(NSNotification *note) { ObserveWithRetry(note.userInfo[NSWorkspaceApplicationKey], 0); }];
    [center addObserverForName:NSWorkspaceDidActivateApplicationNotification object:nil queue:nil
                    usingBlock:^(NSNotification *note) {
                        NSRunningApplication *app = note.userInfo[NSWorkspaceApplicationKey];
                        if (Watched(app)) Observe(app.processIdentifier);
                        Emit(DKAppActivated, NULL, app.processIdentifier);
                    }];
    [center addObserverForName:NSWorkspaceDidTerminateApplicationNotification object:nil queue:nil
                    usingBlock:^(NSNotification *note) {
                        pid_t pid = [note.userInfo[NSWorkspaceApplicationKey] processIdentifier];
                        id observer = observers[@(pid)];
                        if (observer)
                            CFRunLoopRemoveSource(CFRunLoopGetMain(),
                                                  AXObserverGetRunLoopSource((__bridge AXObserverRef)observer),
                                                  kCFRunLoopDefaultMode);
                        [observers removeObjectForKey:@(pid)];
                        Emit(DKAppTerminated, NULL, pid);
                    }];
    // Posted when the list of apps allowed to use Accessibility changes. Delivered at once
    // even though deskkit is never the active app, which would otherwise hold it back.
    CFNotificationCenterAddObserver(CFNotificationCenterGetDistributedCenter(), NULL, AccessibilityChanged,
                                    CFSTR("com.apple.accessibility.api"), NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
}

void DKObserveWindows(DKWindowEventHandler handler) {
    if (!handlers) handlers = [NSMutableArray new];
    [handlers addObject:[handler copy]];
    if (!observers) Start();
}

NSArray *DKAppWindows(pid_t pid) {
    if (pid == getpid()) return @[];
    SetTimeout();
    AXUIElementRef app = AXUIElementCreateApplication(pid);
    CFArrayRef windows = NULL;
    AXUIElementCopyAttributeValue(app, kAXWindowsAttribute, (CFTypeRef *)&windows);
    CFRelease(app);
    return CFBridgingRelease(windows) ?: @[];
}

AXUIElementRef DKCopyFocusedWindow(pid_t pid) {
    if (pid <= 0 || pid == getpid()) return NULL;
    SetTimeout();
    AXUIElementRef app = AXUIElementCreateApplication(pid), window = NULL;
    AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute, (CFTypeRef *)&window);
    CFRelease(app);
    return window;
}

BOOL DKIsStandardWindow(AXUIElementRef window) {
    CFTypeRef subrole = NULL;
    AXUIElementCopyAttributeValue(window, kAXSubroleAttribute, &subrole);
    BOOL standard = subrole && CFEqual(subrole, kAXStandardWindowSubrole);
    if (subrole) CFRelease(subrole);
    return standard;
}

pid_t DKWindowOwner(AXUIElementRef window) {
    pid_t pid = 0;
    AXUIElementGetPid(window, &pid);
    return pid;
}

CGWindowID DKWindowID(AXUIElementRef window) {
    CGWindowID identifier = 0;
    return _AXUIElementGetWindow(window, &identifier) == kAXErrorSuccess ? identifier : 0;
}

NSArray<NSDictionary *> *DKWindowList(BOOL currentSpaceOnly) {
    CGWindowListOption options = currentSpaceOnly ? kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements
                                                  : kCGWindowListOptionAll;
    NSArray<NSDictionary *> *all = CFBridgingRelease(CGWindowListCopyWindowInfo(options, kCGNullWindowID));
    return [all filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *window, id bindings) {
        return [window[(id)kCGWindowLayer] intValue] == 0;
    }]];
}
