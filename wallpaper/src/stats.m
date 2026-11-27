#import "livewall.h"

static const NSTimeInterval kIntervalSeconds = 2;

/// Frames that reached the screen. The public total counts frames as they are queued, so
/// it runs ahead of the display and says nothing about pacing. These two counters are the
/// ones that do; the headers hide them on macOS, but the object answers them.
static NSUInteger DisplayedFrames(AVVideoPerformanceMetrics *metrics, NSUInteger *direct) {
    NSUInteger composited = 0;
    *direct = 0;
    if ([metrics respondsToSelector:NSSelectorFromString(@"numberOfDisplayCompositedVideoFrames")]) {
        *direct = [[metrics valueForKey:@"numberOfDisplayCompositedVideoFrames"] unsignedIntegerValue];
        composited = [[metrics valueForKey:@"numberOfNonDisplayCompositedVideoFrames"] unsignedIntegerValue];
    }
    return *direct + composited;
}

void LWReportStats(AVSampleBufferVideoRenderer *renderer) {
    __block NSUInteger previousDisplayed = 0;
    __block CFAbsoluteTime previousTime = 0;
    [NSTimer scheduledTimerWithTimeInterval:kIntervalSeconds
                                    repeats:YES
                                      block:^(NSTimer *timer) {
        [renderer loadVideoPerformanceMetricsWithCompletionHandler:^(AVVideoPerformanceMetrics *metrics) {
            if (!metrics) return;
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            NSUInteger direct;
            NSUInteger displayed = DisplayedFrames(metrics, &direct);
            double fps = previousTime ? (displayed - previousDisplayed) / (now - previousTime) : 0;
            previousDisplayed = displayed;
            previousTime = now;
            fprintf(stderr, "stats fps=%.1f displayed=%lu dropped=%ld direct_to_display=%lu\n", fps,
                    (unsigned long)displayed, (long)metrics.numberOfDroppedFrames,
                    (unsigned long)direct);
        }];
    }];
}
