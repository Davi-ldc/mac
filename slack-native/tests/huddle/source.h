// The public fixture with huddles, invitations and a call set by the test, for the huddle UI's
// tests and snapshots: the store's own huddle and call state is overridden so a test can put the
// UI in any state (a call needs a controller and media otherwise), and the requests the UI makes
// are recorded instead of reaching a controller.
#import "store/fixture.h"

NS_ASSUME_NONNULL_BEGIN

@interface SNHuddleFixture : SNFixtureSource
/// The public fixture (made-up people), language English.
+ (instancetype)fixture;
/// Each setter announces its change as the store would.
- (void)setHuddle:(nullable SNHuddle *)huddle inConversation:(NSString *)conversationID;
@property (nonatomic, copy) NSSet<NSString *> *usersInHuddles;
@property (nonatomic, copy) NSArray<SNHuddleInvite *> *invites;
@property (nonatomic, nullable) SNCall *fakeCall;
@property (nonatomic) BOOL joinable;
/// What the UI asked: conversations joined, mute settings, leaves, dismissed invites.
@property (nonatomic, readonly) NSMutableArray<NSString *> *joined;
@property (nonatomic, readonly) NSMutableArray<NSNumber *> *mutes;
@property (nonatomic, readonly) NSInteger leaves;
@property (nonatomic, readonly) NSMutableArray<SNHuddleInvite *> *dismissed;
@end

/// A room as sh_room_join carries it (made-up values).
NSDictionary *SNTestRoom(NSString *roomID, NSString *conversationID, NSArray<NSString *> *participants, BOOL ended);

NS_ASSUME_NONNULL_END
