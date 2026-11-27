// Plays a looping video in a window at desktop level, just above the system wallpaper,
// where the menu bar, the Dock and sidebars sample it like the real wallpaper.
//
// Environment hooks for power experiments: LIVEWALL_FRAME and LIVEWALL_ABOVE move the
// window, LIVEWALL_KEEP_PLAYING=1 plays on while the Mac is left alone, and
// LIVEWALL_STATS=1 reports what the renderer puts on screen.

#import "livewall.h"

void LWFail(int code, NSString *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    fprintf(stderr, "livewall: %s\n", message.UTF8String);
    exit(code);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        LWIgnoreControlSignals();
        if (argc != 2) {
            fputs("usage: livewall <video file>\n", stderr);
            return 2;
        }
        LWPlacement placement = LWPlacementFromEnvironment();

        NSApplication *app = NSApplication.sharedApplication;
        app.activationPolicy = NSApplicationActivationPolicyAccessory;

        // The window is covered by other windows most of the time, which is exactly when
        // App Nap would throttle the queue that feeds frames to the layer.
        id activity = [NSProcessInfo.processInfo
            beginActivityWithOptions:NSActivityUserInitiatedAllowingIdleSystemSleep
                              reason:@"wallpaper playback"];

        LWClock *clock = [LWClock new];
        LWPlayer *player = [[LWPlayer alloc] initWithPath:@(argv[1]) clock:clock];
        // A new window counts as not visible until the window server says otherwise; a
        // window that opens fully covered never gets that notification, and must not play.
        [clock setHold:LWHoldHidden active:YES];
        NSWindow *window = LWOpenDesktopWindow(player.layer, placement, ^(BOOL visible) {
            [clock setHold:LWHoldHidden active:!visible];
        });
        [clock setHold:LWHoldPreroll active:NO];

        LWHandleControlSignals(clock);
        if (!getenv("LIVEWALL_KEEP_PLAYING")) LWHoldWhileAway(clock);
        if (getenv("LIVEWALL_STATS")) LWReportStats(player.renderer);
        [app run];
        (void)activity;
        (void)window;
    }
    return 0;
}
