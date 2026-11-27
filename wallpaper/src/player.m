#import "livewall.h"

@implementation LWPlayer

- (instancetype)initWithPath:(NSString *)path clock:(LWClock *)clock {
    if (!(self = [super init])) return nil;
    _layer = [AVSampleBufferDisplayLayer new];
    _layer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    _layer.controlTimebase = clock.timebase;
    _layer.opaque = YES;
    // Already the default on macOS; stated because a wallpaper that kept the display
    // awake would defeat its own purpose.
    _layer.preventsDisplaySleepDuringVideoPlayback = NO;
    _renderer = _layer.sampleBufferRenderer;

    AVSampleBufferVideoRenderer *renderer = _renderer;
    CMTimebaseRef timebase = clock.timebase;
    LWFeed *feed = [[LWFeed alloc] initWithPath:path];
    void (^refill)(void) = ^{
        NSString *error = [feed pumpInto:renderer timebase:timebase];
        // A stopped wallpaper that keeps running would only hold resources.
        if (error) LWFail(1, @"playback stopped: %@", error);
    };
    // The first batch is queued here rather than on the feed queue, so frames are already
    // waiting when the caller lets the clock run.
    refill();
    // Refills happen about once a second and a second ahead of need, so they can wait
    // for an efficiency core.
    dispatch_queue_t queue = dispatch_queue_create(
        "livewall.feed",
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
    [renderer requestMediaDataWhenReadyOnQueue:queue usingBlock:refill];
    return self;
}

@end
