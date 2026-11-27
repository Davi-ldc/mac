#import "livewall.h"

LWPlacement LWPlacementFromEnvironment(void) {
    LWPlacement placement = {NSZeroRect, NO};
    const char *frame = getenv("LIVEWALL_FRAME");
    if (frame) {
        // A value that does not parse is an error: a mislabelled experiment is worse than none.
        double x, y, width, height;
        char rest;
        if (sscanf(frame, "%lf,%lf,%lf,%lf%c", &x, &y, &width, &height, &rest) != 4)
            LWFail(2, @"LIVEWALL_FRAME is not x,y,w,h: %s", frame);
        placement.frame = NSMakeRect(x, y, width, height);
    }
    const char *above = getenv("LIVEWALL_ABOVE");
    if (above) {
        if (strcmp(above, "1") != 0) LWFail(2, @"LIVEWALL_ABOVE must be 1, not %s", above);
        placement.aboveWindows = YES;
    }
    return placement;
}

/// The screen that carries the menu bar, which stays the same one whichever app has focus.
static NSRect PrimaryScreenFrame(void) {
    return NSScreen.screens.firstObject.frame;
}

NSWindow *LWOpenDesktopWindow(CALayer *layer, LWPlacement placement,
                              void (^onVisibility)(BOOL visible)) {
    BOOL followsScreen = NSIsEmptyRect(placement.frame);
    NSWindow *window =
        [[NSWindow alloc] initWithContentRect:followsScreen ? PrimaryScreenFrame() : placement.frame
                                    styleMask:NSWindowStyleMaskBorderless
                                      backing:NSBackingStoreBuffered
                                        defer:NO];
    // Under ARC the returned reference owns the window; AppKit must not release it on close.
    window.releasedWhenClosed = NO;
    window.level = placement.aboveWindows ? NSFloatingWindowLevel
                                          : CGWindowLevelForKey(kCGDesktopWindowLevelKey);
    window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                NSWindowCollectionBehaviorStationary |
                                NSWindowCollectionBehaviorIgnoresCycle;
    window.opaque = YES;
    window.hasShadow = NO;
    window.ignoresMouseEvents = YES;
    window.backgroundColor = NSColor.blackColor;

    // Assigning the layer before wantsLayer makes this a layer-hosting view, so AppKit
    // leaves the video layer alone instead of drawing into a backing layer of its own.
    window.contentView.layer = layer;
    window.contentView.wantsLayer = YES;

    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserverForName:NSWindowDidChangeOcclusionStateNotification
                        object:window
                         queue:nil
                    usingBlock:^(NSNotification *note) {
                        NSWindow *changed = note.object;
                        onVisibility((changed.occlusionState & NSWindowOcclusionStateVisible) != 0);
                    }];
    if (followsScreen) {
        [center addObserverForName:NSApplicationDidChangeScreenParametersNotification
                            object:nil
                             queue:nil
                        usingBlock:^(NSNotification *note) {
                            [window setFrame:PrimaryScreenFrame() display:YES];
                        }];
    }

    [window orderFrontRegardless];
    return window;
}
