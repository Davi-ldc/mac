// Huddles (read from the websocket's sh_room_* and huddle_* events, huddle_thread messages and users' huddle_state) and the user's own call, audio only.
#import <Foundation/Foundation.h>

#import "model/call.h"
#import "model/huddle.h"

NS_ASSUME_NONNULL_BEGIN

@protocol SNHuddlesSource <NSObject>
/// The huddle going on in a conversation (channel, DM or group DM); nil when none is known.
- (nullable SNHuddle *)huddleInConversation:(NSString *)conversationID;
/// The user is in a huddle now: their profile's huddle_state is "in_a_huddle", or a huddle known
/// here has them among its participants.
- (BOOL)isUserInHuddle:(NSString *)userID;
/// Invitations ringing now, oldest first: each leaves when Slack cancels it, the user joins or
/// dismisses it, or SNHuddleInviteTimeout passes.
@property (nonatomic, readonly) NSArray<SNHuddleInvite *> *huddleInvites;
/// The invite banner's close: the invite leaves at once (Slack is not told).
- (void)dismissHuddleInvite:(SNHuddleInvite *)invite;
/// This build can join huddles (it was linked with libwebrtc).
@property (nonatomic, readonly) BOOL canJoinHuddles;
/// The huddle the user is in from this Mac; nil when none.
@property (nonatomic, readonly, nullable) SNCall *call;
/// Joins the huddle going on in the conversation, muted, leaving the current call first; with none
/// going on there, starts one (the microphone on unless the user's huddles_mute_by_default), as
/// Slack's header button and profile button do. Nothing happens when the build cannot join.
- (void)joinHuddleInConversation:(NSString *)conversationID;
- (void)setCallMuted:(BOOL)muted;
/// Leaves the call (signalling leave, then rooms.leave); `call` is nil once it is over.
- (void)leaveCall;
@end

NS_ASSUME_NONNULL_END
