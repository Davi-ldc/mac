// Slack's toast (c-toast), as the VIP button's answers use it: a base-inv-pry box (radius 8, a
// 1 pt ring and a 4/12 shadow) up to 350 pt wide, 20 pt from the window's bottom right, 12/16
// padding around a 20 pt icon, 15 pt text (1.5 lines) and the close button, which takes its room
// always and shows while the pointer is over the toast. It rises 20 pt as it fades in over 80 ms,
// stays `duration` (the pointer over it holds it) and leaves the same way. One at a time.
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface SNToast : NSObject
/// `text` with the parts inside <b>...</b> in bold (Slack's rt() strings), after `icon`.
+ (void)showText:(NSString *)text icon:(NSString *)icon duration:(NSTimeInterval)duration inWindow:(NSWindow *)window;
/// The toast on screen as plain text (tests); nil when none is.
@property (class, nonatomic, readonly, nullable) NSString *currentText;
+ (void)close;
@end

NS_ASSUME_NONNULL_END
