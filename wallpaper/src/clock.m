#import "livewall.h"

static const Float64 kStartLeadSeconds = 0.25;

@implementation LWClock {
    uint8_t _holds;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    // The host clock is what the display itself is paced against.
    OSStatus status = CMTimebaseCreateWithSourceClock(kCFAllocatorDefault,
                                                      CMClockGetHostTimeClock(), &_timebase);
    if (status != noErr) LWFail(1, @"creating the timebase failed with OSStatus %d", status);
    // Starting slightly before zero gives the decoder a head start on the first frames,
    // which would otherwise miss their timestamps and be dropped.
    CMTimebaseSetTime(_timebase, CMTimeMakeWithSeconds(-kStartLeadSeconds, 600));
    _holds = LWHoldPreroll;
    return self;
}

- (void)dealloc {
    CFRelease(_timebase);
}

- (void)setHold:(LWHold)hold active:(BOOL)active {
    uint8_t before = _holds;
    _holds = active ? (before | hold) : (before & ~hold);
    // Some holds are re-asserted on a timer; only a real change may touch the timebase.
    if ((before == 0) != (_holds == 0)) CMTimebaseSetRate(_timebase, _holds == 0 ? 1.0 : 0.0);
}

@end
