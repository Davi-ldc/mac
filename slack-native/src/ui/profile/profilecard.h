// The profile hover card's content (components.json profile_hover_card, measured live): avatar,
// name, title, status, local time and the buttons, inside the foundation's SNHoverCard, which
// owns the timing (opens ~370 ms after hover, closes 265 ms after the pointer leaves, no fade).
// The buttons are Slack's MemberProfileButtons: message, huddle and VIP (ui/profile/vip.h).
#import <AppKit/AppKit.h>

#import "source/source.h"
#import "ui/shell/pane.h"

NS_ASSUME_NONNULL_BEGIN

/// "1h16 hora local", "1h16 (amanhã) hora local" when the person's day is ahead of the one here,
/// at `date` (Slack's useProfileMemberLocalTime).
NSString *SNProfileLocalTime(id<SNSource> source, SNUser *user, NSDate *date);

@interface SNProfileCardView : NSView
/// SNHoverCardWidth wide and as tall as the user's details need.
- (instancetype)initWithUser:(SNUser *)user source:(id<SNSource>)source;
@property (nonatomic, readonly) SNUser *user;
/// The time shown as the user's local time; now unless set (snapshots fix it).
@property (nonatomic, copy, nullable) NSDate *date;
@property (nonatomic, readonly) NSString *localTime;
/// The buttons' labels in order, the VIP one's state as Slack's aria-label says it (tests).
@property (nonatomic, readonly) NSArray<NSString *> *buttonTitles;
/// Clicks the button labelled `title` (tests).
- (void)clickButton:(NSString *)title;
@end

@interface SNProfileCard : NSObject
/// Hover over an avatar or a name at `rect` (in `view`'s coordinates) began; the card for
/// `userID` opens when SNHoverCard's delay ends.
+ (void)hoverBeganOverRect:(NSRect)rect inView:(NSView *)view userID:(NSString *)userID source:(id<SNSource>)source;
/// The pointer left the avatar or name.
+ (void)hoverEnded;
/// Where the card's buttons and a click on an avatar or name go: set once by the window's
/// conversation column.
@property (class, nonatomic, weak, nullable) id<SNNavigator> navigator;
/// A click on someone's avatar or name: their full profile opens in the right column.
+ (void)openProfileOfUser:(NSString *)userID;
/// The card's and the profile's message button: the DM with `userID`, opened where the window is.
+ (void)openDirectMessageWithUser:(NSString *)userID source:(id<SNSource>)source;
/// The huddle button: the huddle in the DM with `userID`.
+ (void)startHuddleWithUser:(NSString *)userID source:(id<SNSource>)source;
/// The huddle button's call menu (Slack's "Start a call", 305 pt wide) under `rect` in `view`:
/// "Start Huddle", "Join Huddle" while one goes on in the DM, "Leave Huddle" while the user is in it.
+ (void)showHuddleMenuForUser:(NSString *)userID source:(id<SNSource>)source forRect:(NSRect)rect inView:(NSView *)view;
@end

NS_ASSUME_NONNULL_END
