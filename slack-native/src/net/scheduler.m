// Owns the call queue: priorities, spacing, tier windows, Retry-After holds, merging, disabling.
#import "net/scheduler.h"

NSInteger SNRateLimitForKey(NSString *rateKey) {
    if ([rateKey hasPrefix:@"chat.postMessage "]) return 60;
    NSString *method = [rateKey componentsSeparatedByString:@" "].firstObject;
    static NSDictionary<NSString *, NSNumber *> *tiers;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Slack's published tiers where documented; internal methods get the tier of their
        // documented counterpart. Everything else is Tier 3.
        tiers = @{
            @"search.messages" : @20, @"search.modules" : @20, @"users.list" : @20, @"conversations.list" : @20, @"emoji.list" : @20,
            @"client.userBoot" : @20, @"client.getWebSocketURL" : @20, @"users.prefs.get" : @20, @"users.channelSections.list" : @20,
            @"team.info" : @20, @"files.getUploadURL" : @20,
            @"users.info" : @100, @"conversations.info" : @100, @"users.profile.get" : @100, @"auth.test" : @100,
            @"chat.postMessage" : @100,
        };
    });
    return tiers[method].integerValue ?: 50;
}

@interface SNScheduledCall : NSObject
@property (nonatomic) NSString *method, *rateKey;
@property (nonatomic, nullable) NSString *mergeKey;
@property (nonatomic) SNCallPriority priority;
@property (nonatomic, copy) SNCallWork work;
@property (nonatomic) NSMutableArray<SNAPICompletion> *completions;
@end

@implementation SNScheduledCall
@end

@implementation SNScheduler {
    NSMutableArray<SNScheduledCall *> *_queue;
    NSMutableArray<SNScheduledCall *> *_running;
    NSMutableDictionary<NSString *, NSMutableArray<NSDate *> *> *_starts;
    NSMutableDictionary<NSString *, NSDate *> *_heldUntil;
    NSMutableSet<NSString *> *_disabled;
    NSDate *_lastBackground;
    NSTimer *_timer;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _backgroundInterval = 1.2;
    _rateWindow = 60;
    _maxInFlight = 6;
    _queue = [NSMutableArray new];
    _running = [NSMutableArray new];
    _starts = [NSMutableDictionary new];
    _heldUntil = [NSMutableDictionary new];
    _disabled = [NSMutableSet new];
    return self;
}

- (void)dealloc { [_timer invalidate]; }

- (BOOL)isDisabled:(NSString *)method { return [_disabled containsObject:method]; }
- (NSUInteger)queuedCount { return _queue.count; }

- (void)enqueue:(NSString *)method mergeKey:(NSString *)mergeKey rateKey:(NSString *)rateKey priority:(SNCallPriority)priority
           work:(SNCallWork)work completion:(SNAPICompletion)completion {
    if ([_disabled containsObject:method]) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, SNAPIMakeError(SNAPIErrorDisabled, @"unknown_method")); });
        return;
    }
    if (mergeKey)
        for (SNScheduledCall *call in [_queue arrayByAddingObjectsFromArray:_running]) {
            if (![call.mergeKey isEqualToString:mergeKey]) continue;
            if (completion) [call.completions addObject:completion];
            // A user waiting on a merged background call lifts it ahead.
            if (priority == SNCallUserFacing) call.priority = SNCallUserFacing;
            [self pump];
            return;
        }
    SNScheduledCall *call = [SNScheduledCall new];
    call.method = method;
    call.mergeKey = mergeKey;
    call.rateKey = rateKey;
    call.priority = priority;
    call.work = work;
    call.completions = [NSMutableArray new];
    if (completion) [call.completions addObject:completion];
    [_queue addObject:call];
    [self pump];
}

/// When `call` may start, or nil for now.
- (NSDate *)waitFor:(SNScheduledCall *)call now:(NSDate *)now {
    NSDate *wait = nil;
    NSDate *held = _heldUntil[call.rateKey];
    if (held && [held compare:now] == NSOrderedDescending) wait = held;
    NSMutableArray<NSDate *> *starts = _starts[call.rateKey];
    while (starts.count && -starts.firstObject.timeIntervalSinceNow >= self.rateWindow) [starts removeObjectAtIndex:0];
    NSInteger limit = MAX(1, (NSInteger)llround(SNRateLimitForKey(call.rateKey) * self.rateWindow / 60.0));
    if ((NSInteger)starts.count >= limit) {
        NSDate *free = [starts.firstObject dateByAddingTimeInterval:self.rateWindow];
        if (!wait || [free compare:wait] == NSOrderedDescending) wait = free;
    }
    if (call.priority == SNCallBackground && _lastBackground) {
        NSDate *spaced = [_lastBackground dateByAddingTimeInterval:self.backgroundInterval];
        if ([spaced compare:now] == NSOrderedDescending && (!wait || [spaced compare:wait] == NSOrderedDescending)) wait = spaced;
    }
    return wait;
}

- (void)pump {
    [_timer invalidate];
    _timer = nil;
    NSDate *now = NSDate.date, *next = nil;
    for (SNCallPriority priority = SNCallUserFacing; priority <= SNCallBackground; priority++)
        for (SNScheduledCall *call in [_queue copy]) {
            if (call.priority != priority) continue;
            if ((NSInteger)_running.count >= self.maxInFlight) return;
            NSDate *wait = [self waitFor:call now:now];
            if (wait) {
                next = next && [next compare:wait] == NSOrderedAscending ? next : wait;
                continue;
            }
            [self start:call now:now];
        }
    if (!next) return;
    __weak SNScheduler *weakSelf = self;
    _timer = [NSTimer timerWithTimeInterval:MAX(0.01, next.timeIntervalSinceNow) repeats:NO block:^(NSTimer *timer) { [weakSelf pump]; }];
    // Common modes: calls keep going while a menu is open or the window is resized.
    [NSRunLoop.mainRunLoop addTimer:_timer forMode:NSRunLoopCommonModes];
}

- (void)start:(SNScheduledCall *)call now:(NSDate *)now {
    [_queue removeObject:call];
    [_running addObject:call];
    NSMutableArray *starts = _starts[call.rateKey] ?: (_starts[call.rateKey] = [NSMutableArray new]);
    [starts addObject:now];
    if (call.priority == SNCallBackground) _lastBackground = now;
    __block BOOL finished = NO;
    call.work(^(SNCallOutcome outcome, NSTimeInterval retryAfter, NSDictionary *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (finished) return;
            finished = YES;
            [self finish:call outcome:outcome retryAfter:retryAfter response:response error:error];
        });
    });
}

- (void)finish:(SNScheduledCall *)call outcome:(SNCallOutcome)outcome retryAfter:(NSTimeInterval)retryAfter response:(NSDictionary *)response error:(NSError *)error {
    [_running removeObject:call];
    if (outcome == SNCallRateLimited) {
        _heldUntil[call.rateKey] = [NSDate dateWithTimeIntervalSinceNow:MAX(1, retryAfter)];
        [_queue insertObject:call atIndex:0];
        [self pump];
        return;
    }
    if (outcome == SNCallUnknownMethod) {
        [_disabled addObject:call.method];
        error = SNAPIMakeError(SNAPIErrorDisabled, @"unknown_method");
        response = nil;
        NSArray *queued = [_queue copy];
        for (SNScheduledCall *other in queued)
            if ([other.method isEqualToString:call.method]) {
                [_queue removeObject:other];
                for (SNAPICompletion completion in other.completions) completion(nil, error);
            }
    }
    for (SNAPICompletion completion in call.completions) completion(response, error);
    [self pump];
}

@end
