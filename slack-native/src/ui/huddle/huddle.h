// What every huddle surface shares (design/_src: HuddleAvatarStack, HuddleStatusIcon,
// HuddleMsgAvatar): the facepile of people in a huddle, the headphones square of huddle
// messages and the LIVE badge.
#import <AppKit/AppKit.h>

#import "render/images.h"
#import "source/source.h"
#import "ui/kit/button.h"

NS_ASSUME_NONNULL_BEGIN

/// .p-huddle_avatar_stack's x_small avatars.
static const CGFloat SNHuddleFacepileAvatar = 20;

/// The conversation's huddle while it goes on (SNHuddle.isActive); nil otherwise.
SNHuddle *_Nullable SNActiveHuddle(id<SNSource> source, NSString *conversationID);
/// The user is in `conversationID`'s huddle from this Mac (a call that has not started leaving).
BOOL SNInCallInConversation(id<SNSource> source, NSString *conversationID);

/// The first `count` people in the huddle (Slack's order), at most `limit`.
NSArray<NSString *> *SNFacepileUserIDs(SNHuddle *huddle, NSUInteger limit);
/// The facepile's width for `count` avatars of `size`.
CGFloat SNFacepileWidth(NSUInteger count, CGFloat size);
/// Draws the facepile with its top-left at `origin` (flipped context): avatars rounded at a
/// quarter of their side, each after the first cut by Slack's huddles-mask so it curves around the
/// one before. The pictures are held by `images` (render/images.h).
void SNDrawFacepile(NSArray<SNUser *> *users, CGFloat size, NSPoint origin, SNImageHolder *images);
/// The people of `userIDs` the source knows.
NSArray<SNUser *> *SNFacepileUsers(NSArray<NSString *> *userIDs, id<SNSource> source);

/// SNDrawFacepile in a view of its own (over a button's fill), redrawn as pictures arrive.
@interface SNFacepileView : NSView
- (instancetype)initWithSource:(id<SNSource>)source;
@property (nonatomic, copy) NSArray<NSString *> *userIDs;
@end

/// .p-huddle_msg_join_button: the outline button with up to three faces before "Join Huddle",
/// bordered jade-20, at 80% opacity under the pointer.
@interface SNHuddleJoinButton : SNButton
- (instancetype)initWithSource:(id<SNSource>)source;
@property (nonatomic, copy) NSArray<NSString *> *userIDs;
/// Its width for `title` and `count` faces.
+ (CGFloat)widthForTitle:(NSString *)title faces:(NSUInteger)count;
@end

/// .p-huddle_msg_avatar: the headphones on a rounded square of `rect`, jade while the huddle is
/// live.
void SNDrawHuddleAvatar(NSRect rect, BOOL live);
/// .p-huddle_msg_status_badge--live__dark_mode ("LIVE"), its left edge at `x`, centred on
/// `middle`; returns its width.
CGFloat SNDrawLiveBadge(CGFloat x, CGFloat middle);
CGFloat SNLiveBadgeWidth(void);

NS_ASSUME_NONNULL_END
