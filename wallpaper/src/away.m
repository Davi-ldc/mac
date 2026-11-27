#import "livewall.h"

// A video nobody is watching costs the same as one somebody is, and this Mac may be set
// to never sleep, so being left alone is the longest stretch freezing can save.

static const NSTimeInterval kAwayAfterSeconds = 300;
/// How often to look for the user's return, so also the longest the video stays frozen
/// after it.
static const NSTimeInterval kReturnCheckSeconds = 3;

void LWHoldWhileAway(LWClock *clock) {
    NSTimer *timer =
        [NSTimer scheduledTimerWithTimeInterval:kReturnCheckSeconds
                                        repeats:YES
                                          block:^(NSTimer *timer) {
            NSTimeInterval idle = CGEventSourceSecondsSinceLastEventType(
                kCGEventSourceStateCombinedSessionState, kCGAnyInputEventType);
            BOOL away = idle >= kAwayAfterSeconds;
            [clock setHold:LWHoldAway active:away];
            // With the user around, the hold cannot fall due before the idle time has
            // run its full course, so there is nothing to look at until then.
            timer.fireDate = [NSDate dateWithTimeIntervalSinceNow:away ? kReturnCheckSeconds
                                                                       : kAwayAfterSeconds - idle];
        }];
    // Lets the system fire this together with other wakeups instead of on its own.
    timer.tolerance = 1;
}
