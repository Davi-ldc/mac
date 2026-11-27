// Desktop notifications for DMs and mentions, as Slack decides them (per-conversation and global
// notification prefs, keywords, mute, Do Not Disturb, the conversation in front), and the dock
// badge (mentions and DMs as a number, a dot for other unread conversations).
#import "store/store.h"

NS_ASSUME_NONNULL_BEGIN

@interface SNNotifier : NSObject
/// Takes the store's messageArrived and follows its counts for the badge.
- (instancetype)initWithStore:(SNStore *)store;
/// The conversation in front while the app is active; its messages do not notify.
@property (nonatomic, copy, nullable) NSString *_Nullable (^focusedConversation)(void);
/// Shows a notification; by default through UNUserNotificationCenter (tests replace it).
@property (nonatomic, copy) void (^deliver)(NSString *identifier, NSString *title, NSString *_Nullable subtitle, NSString *body, NSDictionary *userInfo);
/// Shows the badge; by default on the dock tile (tests replace it).
@property (nonatomic, copy) void (^showBadge)(NSString *label);
/// Bounces the Dock icon after a notification (Slack's mac_ssb_bounce): once, or until the app is
/// active; replaceable for tests.
@property (nonatomic, copy) void (^bounce)(BOOL untilActive);
/// The user clicked a notification.
@property (nonatomic, copy, nullable) void (^onOpen)(NSString *conversationID, NSString *_Nullable threadTS);

- (BOOL)shouldNotify:(SNMessage *)message inConversation:(SNConversation *)conversation;
/// "3", "•" or "".
@property (nonatomic, readonly) NSString *badgeLabel;
/// Assigns the notification center delegate synchronously before applicationDidFinishLaunching:
/// returns so cold-launch notification clicks are never dropped.
- (void)installDelegate;
/// Asks for permission (the system asks the user once) and updates the dock badge. Only for a
/// signed-in launch: tests never call it.
- (void)start;
/// Stops delivering notifications or updating the dock badge (sign-out).
- (void)stop;
@end

/// The notification text of a message: its preview (render/message.h) as plain text.
NSString *SNNotificationText(SNMessage *message, SNStore *store);

NS_ASSUME_NONNULL_END
