// The user's call from this Mac, from joining or starting to leaving: the nearest media region
// (starting only), rooms.join, the Chime signalling
// connection (call/signaling.h) and the media (call/media.h). Every way out of a call sends both
// leaves (rooms.leave and the signalling leave, together, as Slack's client ends a huddle); a call
// still open when the app ended without leaving is left at the next launch (recover). Main thread.
#import <Foundation/Foundation.h>

#import "call/media.h"
#import "model/call.h"
#import "model/huddle.h"
#import "net/api.h"

NS_ASSUME_NONNULL_BEGIN

@interface SNCallController : NSObject
/// `recoveryFile` keeps what leaving needs while a call is open (nil: nothing kept, as in tests
/// that do not check recovery).
- (instancetype)initWithAPI:(id<SNAPI>)api urlSession:(NSURLSession *)urlSession userID:(NSString *)userID recoveryFile:(nullable NSURL *)recoveryFile;
/// Makes a call's media; nil when this build cannot join. Set to SNCallMedia with the Mac's
/// devices when SNCallMedia.isAvailable; tests give synthetic devices.
@property (nonatomic, copy, nullable) SNCallMedia *_Nullable (^makeMedia)(NSArray<SNICEServer *> *servers);
@property (nonatomic, readonly, nullable) SNCall *call;
/// After every change of `call`.
@property (nonatomic, copy, nullable) void (^onChange)(void);
/// Joins `huddle` in `conversationID`, muted, leaving the current call first.
- (void)joinHuddle:(SNHuddle *)huddle inConversation:(NSString *)conversationID;
/// Starts a huddle in the conversation (a channel, DM or group DM), as joining otherwise.
- (void)startHuddleInConversation:(NSString *)conversationID muted:(BOOL)muted;
/// Where the nearest Chime media region is asked (https://nearest-media-region.l.chime.aws), and
/// where the answer is kept between launches (nil: this launch only).
@property (nonatomic, copy) NSURL *regionURL;
@property (nonatomic, nullable) NSUserDefaults *regionDefaults;
/// Asks for the nearest region unless it is known, as Slack's client does shortly after launch,
/// so a start does not wait for it.
- (void)prefetchRegion;
/// The user's preferences (huddles_set_status), read when the profile's huddle state is refreshed.
@property (nonatomic, copy, nullable) NSDictionary *_Nullable (^preferences)(void);
/// Seconds between refreshes of the profile's huddle state while in a call (Slack's: 240).
@property (nonatomic) NSTimeInterval statusInterval;
/// The call's conversation has this huddle now (nil: none): a call whose huddle ended, or was
/// replaced by another, is left.
- (void)huddleChanged:(nullable SNHuddle *)huddle;
- (void)setMuted:(BOOL)muted;
- (void)leave;
/// Quitting: leaves the call within `timeout`, then `completion` (at once without a call).
- (void)leaveWithin:(NSTimeInterval)timeout completion:(void (^)(void))completion;
/// Sends both leaves for a call the recovery file still holds, once, then forgets it.
- (void)recover;
/// Seconds a join may take before it gives up (Slack's client: 60), and that leaving waits for
/// Chime and Slack to answer when the user leaves (2).
@property (nonatomic) NSTimeInterval joinTimeout, leaveTimeout;
@end

NS_ASSUME_NONNULL_END
