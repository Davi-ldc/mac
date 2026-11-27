// The hover card (components.json profile_hover_card, measured live): after 370 ms over an avatar
// or a name (the CSS says 750; the app does not), a 340 pt card (#1a1d21, radius 8, 1 pt
// #3a3d40 ring) fades in over 80 ms 11 pt below the target, aligned with its left edge. It stays
// while the pointer is on the target or the card and closes at once 265 ms after it left both.
#import <AppKit/AppKit.h>

#import "theme/theme.h"

NS_ASSUME_NONNULL_BEGIN

static const NSTimeInterval SNHoverCardDelay = SNLiveHoverCardDelay;
static const CGFloat SNHoverCardWidth = 340;

@interface SNHoverCard : NSObject
/// Starts the delay for a card about `rect` (in `view`'s coordinates) showing `key` (a user ID).
/// When it is due, `content` makes the card's content view: SNHoverCardWidth wide, as tall as it
/// likes. The open card stays if it shows the same key, and is replaced otherwise.
+ (void)hoverBeganOverRect:(NSRect)rect inView:(NSView *)view key:(NSString *)key content:(NSView * (^)(void))content;
/// The key of the card on screen, nil when none is.
@property (class, nonatomic, readonly, nullable) NSString *key;
/// The pointer left the target; the card closes unless the pointer reaches it in time.
+ (void)hoverEnded;
+ (void)close;
@end

NS_ASSUME_NONNULL_END
