// The conversation header's huddle control (HuddleChannelHeaderButton, the --polish variant the
// header shows): the headphones button and the options caret. Idle, the button starts a huddle.
// While a huddle goes on there and the user is not in it, the container turns jade-5 with up to
// three faces before the headphones and the number of people after them, and the button joins;
// from the moment the user joins or starts (as Slack's optimistic huddle state) a jade-50 fill
// slides in from the left (200 ms) and the button leaves, its headphones turning into a close
// glyph under the pointer. The caret's menu offers starting or joining.
#import <AppKit/AppKit.h>

#import "source/source.h"
#import "ui/kit/button.h"

NS_ASSUME_NONNULL_BEGIN

@interface SNHuddleHeaderControl : NSView
- (instancetype)initWithSource:(id<SNSource>)source;
/// The conversation the header shows; the control follows its huddle and the user's call.
@property (nonatomic, copy, nullable) NSString *conversationID;
@property (nonatomic, readonly) SNButton *button, *options;
/// Its width in the current state (the header lays it out).
@property (nonatomic, readonly) CGFloat preferredWidth;
/// The width changed (a huddle started or ended, someone joined): lay the header out again.
@property (nonatomic, copy, nullable) void (^widthChanged)(void);
@end

NS_ASSUME_NONNULL_END
