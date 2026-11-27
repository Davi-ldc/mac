// Slack's tooltip (components.json "tooltip", effects.txt [tooltip-show], measured live): a
// #212428 bubble with a 1 pt #414348 border, 13 pt bold text and an arrow, fading in over 80 ms
// after 150 ms of hover and gone at once when the pointer leaves. One shows at a time, app-wide.
// Where it goes depends on the caller: below top-bar and header buttons, above the message
// action bar, right of the rail.
#import <AppKit/AppKit.h>

#import "ui/kit/overlay.h"

NS_ASSUME_NONNULL_BEGIN

static const NSTimeInterval SNTooltipDelay = SNLiveTooltipDelay;

@interface SNTooltip : NSObject
/// Shows `text` on the `placement` side of `rect` (in `view`'s coordinates) after `delay`,
/// unless hidden before then.
+ (void)showText:(NSString *)text forRect:(NSRect)rect inView:(NSView *)view placement:(SNPlacement)placement delay:(NSTimeInterval)delay;
/// With a shortcut's keys (space-separated) in black chips under the text, as Slack shows them.
+ (void)showText:(NSString *)text
        shortcut:(nullable NSString *)shortcut
         forRect:(NSRect)rect
          inView:(NSView *)view
       placement:(SNPlacement)placement
           delay:(NSTimeInterval)delay;
/// Cancels a pending tooltip and removes the visible one.
+ (void)hide;
@end

NS_ASSUME_NONNULL_END
