// Huddles as Slack describes them: a huddle is a "room" (R... ID) in a channel, DM or group DM (a
// 1:1 call is a huddle in the DM), decoded from the room objects that the sh_room_* websocket
// events, huddle_thread messages and rooms.join carry; and the invitations that ring the user.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SNHuddle : NSObject
/// The room's ID ("R...").
@property (nonatomic, readonly) NSString *identifier;
/// Its conversations ("channels"); the first is where it happens.
@property (nonatomic, readonly) NSArray<NSString *> *conversationIDs;
@property (nonatomic, readonly, nullable) NSString *name;
@property (nonatomic, readonly, nullable) NSString *creatorID;
/// Who is in it now ("participants"), in Slack's order.
@property (nonatomic, readonly) NSArray<NSString *> *participantIDs;
/// Everyone who was in it ("participant_history").
@property (nonatomic, readonly) NSArray<NSString *> *historyIDs;
@property (nonatomic, readonly) BOOL hasEnded, isDMCall;
/// Going on: not ended and someone in it, the official client's test for a conversation's huddle.
@property (nonatomic, readonly) BOOL isActive;
/// Unix seconds; dateEnd is 0 while it goes on.
@property (nonatomic, readonly) NSTimeInterval dateStart, dateEnd;
/// The huddle_thread message whose thread holds the huddle's messages, when known
/// (thread_root_ts, else canvas_thread_ts).
@property (nonatomic, readonly, nullable) NSString *threadTS;
/// The room as Slack sent it, with later updates laid over it.
@property (nonatomic, readonly) NSDictionary *json;
+ (nullable instancetype)huddleWithJSON:(NSDictionary *)json;
/// Decoded again from its JSON with `changes` laid over it; NSNull removes a key.
- (instancetype)huddleByMergingJSON:(NSDictionary *)changes;
@end

/// Someone ringing the user into a huddle (huddle_invite), until it is cancelled, answered,
/// dismissed or missed.
@interface SNHuddleInvite : NSObject
@property (nonatomic, readonly) NSString *conversationID, *huddleID, *senderID;
/// When it arrived; Slack's client counts it missed 30 s later.
@property (nonatomic, readonly) NSDate *received;
@property (nonatomic, readonly) NSDictionary *json;
/// From the huddle_invite event; nil without channel_id, call_id or sender_user_id.
+ (nullable instancetype)inviteWithJSON:(NSDictionary *)json received:(NSDate *)received;
@end

/// How long an invite rings before Slack's client counts it missed.
static const NSTimeInterval SNHuddleInviteTimeout = 30;

NS_ASSUME_NONNULL_END
