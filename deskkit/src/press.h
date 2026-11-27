// Telling a tap of ⏎ or the mouse button on a row from a hold.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// How long ⏎ or the mouse button stays down on a row before it counts as held.
static const NSTimeInterval DKHoldSeconds = 0.15;

/// One press, timed from its start. Its timer lives only until the press is held or ended.
@interface DKPress : NSObject
/// Starts timing: `held` runs once after `seconds`, unless the press ends first.
- (instancetype)initWithSeconds:(NSTimeInterval)seconds held:(void (^)(void))held;
/// Ends the press: YES when it was a tap, which is when `held` has not run, and now never will.
- (BOOL)end;
/// Whether the press is still being timed.
@property(readonly, getter=isTiming) BOOL timing;
@end

NS_ASSUME_NONNULL_END
