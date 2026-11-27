// The "Não lidas" switch of list headers (components.json unreads_toggle, effects.txt [A14]): a
// 12 pt bold label 8 pt left of a 28x18 pill whose 12 pt handle slides 10 pt right when on, with
// a small overshoot over 200 ms; the colours change in 40 ms.
#import "ui/kit/hoverview.h"

NS_ASSUME_NONNULL_BEGIN

@interface SNUnreadsToggle : SNHoverView
- (instancetype)initWithTitle:(NSString *)title;
@property (nonatomic, getter=isOn) BOOL on;
/// Off, the theme's light colours over the sidebar (Slack's p-unreads_toggle--inverse); NO for
/// dark surfaces such as the rail's peeks, where the label, ring and handle are #b9babd.
@property (nonatomic) BOOL inverse;
- (void)setOn:(BOOL)on animated:(BOOL)animated;
/// Called after a click flipped the switch.
@property (nonatomic, copy, nullable) void (^changed)(BOOL on);
@property (nonatomic, readonly) NSSize fittingSize;
@end

NS_ASSUME_NONNULL_END
