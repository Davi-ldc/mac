// The bottom of the Home sidebar while huddles reach the user (the IA4 client's huddle
// workspace in the sidebar): an incoming invitation (HuddleInvite: who rings, Join, Decline) and,
// while the user is in a huddle from here, the footer (HuddleSidebarFooter): the person heard now
// with the speaking ring, the huddle's name and how many are in it, the microphone and Leave.
#import <AppKit/AppKit.h>

#import "source/source.h"
#import "ui/kit/button.h"

NS_ASSUME_NONNULL_BEGIN

@interface SNHuddleSidebarFooter : NSView
- (instancetype)initWithSource:(id<SNSource>)source;
/// 0 when there is nothing to show.
@property (nonatomic, readonly) CGFloat preferredHeight;
/// preferredHeight changed: the sidebar lays its list out again.
@property (nonatomic, copy, nullable) void (^heightChanged)(void);
/// The invitation's buttons (Join only when the build can join) and the call's, for tests; nil
/// while not shown.
@property (nonatomic, readonly, nullable) SNButton *joinButton, *declineButton, *micButton, *leaveButton;
/// The person the footer shows as heard now, for tests.
@property (nonatomic, readonly, nullable) NSString *speakerID;
@end

NS_ASSUME_NONNULL_END
