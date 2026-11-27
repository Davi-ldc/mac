// Owns a press's timer.
#import "press.h"

@implementation DKPress {
    NSTimer *_timer;
}

- (instancetype)initWithSeconds:(NSTimeInterval)seconds held:(void (^)(void))held {
    if (!(self = [super init])) return nil;
    __weak DKPress *weakSelf = self;
    _timer = [NSTimer timerWithTimeInterval:seconds repeats:NO block:^(NSTimer *timer) {
        DKPress *press = weakSelf;
        if (!press) return;
        press->_timer = nil;
        held();
    }];
    // Common modes: a mouse press is held inside the table's own loop, which tracks the button
    // in another run loop mode until it goes up.
    [NSRunLoop.mainRunLoop addTimer:_timer forMode:NSRunLoopCommonModes];
    return self;
}

- (BOOL)end {
    BOOL tap = _timer != nil;
    [_timer invalidate];
    _timer = nil;
    return tap;
}

- (BOOL)isTiming { return _timer != nil; }

- (void)dealloc { [_timer invalidate]; }

@end
