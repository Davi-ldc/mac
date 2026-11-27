// When each API call may go out: user-facing calls first, background calls spaced out
// (~1 per 1.2 s), each method within its Slack rate tier per minute (chat.postMessage ~1 per
// second per channel), a method answered 429 held until its Retry-After, identical calls waiting
// or in flight merged into one, and methods that answered unknown_method never called again.
#import "net/api.h"

NS_ASSUME_NONNULL_BEGIN

/// What a call's work reports back to the scheduler.
typedef NS_ENUM(NSInteger, SNCallOutcome) {
    SNCallDone,
    /// Slack said 429 (or ok:false ratelimited): hold the rate key for `retryAfter` and run again.
    SNCallRateLimited,
    /// Slack said unknown_method: fail this and every later call of the method.
    SNCallUnknownMethod,
};

/// Calls `finish` once when the work is over; `retryAfter` only matters for SNCallRateLimited.
typedef void (^SNCallFinish)(SNCallOutcome outcome, NSTimeInterval retryAfter, NSDictionary *_Nullable response, NSError *_Nullable error);
typedef void (^SNCallWork)(SNCallFinish finish);

@interface SNScheduler : NSObject
/// Seconds between background calls (default 1.2).
@property (nonatomic) NSTimeInterval backgroundInterval;
/// The window tier limits count over (default 60 s; tests shorten it).
@property (nonatomic) NSTimeInterval rateWindow;
/// Calls running at once at most (default 6).
@property (nonatomic) NSInteger maxInFlight;

/// Queues `work` for `method`. Calls with the same `mergeKey` (nil: never merged) while one is
/// queued or running share its result; `rateKey` groups calls under one limit (the method, or
/// "chat.postMessage <channel>"). `completion` runs on the main thread.
- (void)enqueue:(NSString *)method
       mergeKey:(nullable NSString *)mergeKey
        rateKey:(NSString *)rateKey
       priority:(SNCallPriority)priority
           work:(SNCallWork)work
     completion:(nullable SNAPICompletion)completion;
- (BOOL)isDisabled:(NSString *)method;
/// Calls queued, not yet started.
@property (nonatomic, readonly) NSUInteger queuedCount;
@end

/// Calls per rateWindow allowed for a rate key: Slack's tiers (1, 20, 50, 100 per minute) by
/// method, 60 for chat.postMessage per channel (one a second).
NSInteger SNRateLimitForKey(NSString *rateKey);

NS_ASSUME_NONNULL_END
