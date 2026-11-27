// Slack's "more" button: the vertical ellipsis on an icon button with the header's kebab fills.
#import "ui/kit/button.h"

NS_ASSUME_NONNULL_BEGIN

@interface SNKebabButton : SNButton
/// `size` square, the header's kebab fills (#2c2e31 hovered, #434548 pressed, measured live).
/// Slack's view header uses a small icon button (16 px icon), the thread pane a medium one (20).
+ (instancetype)kebabWithSize:(CGFloat)size iconSize:(CGFloat)iconSize;
@end

NS_ASSUME_NONNULL_END
