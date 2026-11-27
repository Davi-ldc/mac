// Huddles in the store: rooms and invitations decoded with the official client's shapes, each
// conversation's huddle from the sh_room_* events and from huddle_thread messages, who is in a
// huddle, invitations ringing, call blocks kept current, and what each change announces.
// Made-up data.
#import "../net/stub.h"
#import "app/launch.h"
#import "store/fixture.h"
#import "test.h"

static NSDictionary *Room(NSString *roomID, NSArray *participants, BOOL ended) {
    return @{@"id" : roomID, @"name" : @"", @"created_by" : @"U02SAM", @"date_start" : @1795400000, @"date_end" : ended ? @1795400600 : @0,
             @"participants" : participants, @"participant_history" : @[ @"U02SAM", @"U03PRIYA", @"U04JORDAN" ], @"channels" : @[ @"C01GENERAL" ],
             @"is_dm_call" : @NO, @"has_ended" : @(ended), @"thread_root_ts" : @"1795400000.000100", @"canvas_thread_ts" : @"1795400000.000100",
             @"media_backend_type" : @"free_willy", @"pending_invitees" : @{}, @"knocks" : @{}, @"last_invite_status_by_user" : @{}};
}

static NSDictionary *RoomEvent(NSString *type, NSString *user, NSDictionary *room, NSString *eventTS) {
    NSMutableDictionary *event = [@{@"type" : type, @"user" : user, @"room" : room, @"huddle" : @{@"channel_id" : [room[@"channels"] firstObject]}} mutableCopy];
    if (eventTS) event[@"event_ts"] = eventTS;
    return event;
}

static SNStore *Store(void) {
    SNStore *store = [[SNStore alloc] initWithDatabase:nil api:nil];
    [store performChanges:^{
        [store applyWorkspace:@{@"id" : @"T0NORTHWND", @"name" : @"Northwind Studio", @"domain" : @"northwind-studio"}];
        [store applySelfUserID:@"U01ALEX"];
        [store applyUsers:@[ @{@"id" : @"U01ALEX", @"name" : @"alex", @"profile" : @{@"real_name" : @"Alex Rivera"}},
                             @{@"id" : @"U02SAM", @"name" : @"sam", @"profile" : @{@"real_name" : @"Sam Chen"}},
                             @{@"id" : @"U03PRIYA", @"name" : @"priya", @"profile" : @{@"real_name" : @"Priya Nair"}} ]];
        [store applyConversations:@[ @{@"id" : @"C01GENERAL", @"name" : @"general", @"is_channel" : @YES, @"is_member" : @YES},
                                     @{@"id" : @"D05SAM", @"is_im" : @YES, @"user" : @"U02SAM"} ]];
    }];
    return store;
}

/// What the store announced while `block` ran and the next turns settled.
static NSArray<SNChange *> *Changes(SNStore *store, void (^block)(void)) {
    NSMutableArray *changes = [NSMutableArray new];
    SNFlushChanges();
    id observer = SNObserveChanges(store, ^(SNChange *change) { [changes addObject:change]; });
    block();
    SNSettle(0.05);
    SNStopObserving(observer);
    return changes;
}

/// What `changes` named under one of SNChange's properties (@YES for one that only says so).
static NSSet *Announced(NSArray<SNChange *> *changes, NSString *kind) {
    NSMutableSet *all = [NSMutableSet new];
    for (SNChange *change in changes) {
        id value = [change valueForKey:kind];
        if ([value isKindOfClass:NSSet.class]) [all unionSet:value];
        else if ([value boolValue]) [all addObject:@YES];
    }
    return all;
}

SN_TEST(HuddleDecodesRoomsAndInvites) {
    SNHuddle *huddle = [SNHuddle huddleWithJSON:Room(@"R01ROOM", @[ @"U02SAM", @"U03PRIYA" ], NO)];
    SNExpect([huddle.identifier isEqualToString:@"R01ROOM"] && [huddle.conversationIDs isEqualToArray:@[ @"C01GENERAL" ]], "room ID and conversations");
    SNExpect(huddle.participantIDs.count == 2 && huddle.historyIDs.count == 3 && [huddle.creatorID isEqualToString:@"U02SAM"], "participants, history and creator");
    SNExpect(huddle.isActive && !huddle.hasEnded && !huddle.isDMCall && huddle.dateStart == 1795400000 && huddle.dateEnd == 0, "going on, with its start");
    SNExpect([huddle.threadTS isEqualToString:@"1795400000.000100"] && !huddle.name, "thread ts; an empty name is none");
    SNHuddle *empty = [huddle huddleByMergingJSON:@{@"participants" : @[]}];
    SNExpect(!empty.isActive && !empty.hasEnded, "nobody in it is not going on");
    SNExpect(![huddle huddleByMergingJSON:@{@"has_ended" : @YES}].isActive, "ended");
    SNHuddle *canvas = [SNHuddle huddleWithJSON:@{@"id" : @"R02", @"thread_root_ts" : @"0000000000.000000", @"canvas_thread_ts" : @"1795400001.000200"}];
    SNExpect([canvas.threadTS isEqualToString:@"1795400001.000200"], "a zero thread_root_ts falls back to canvas_thread_ts");
    SNExpect(![SNHuddle huddleWithJSON:@{@"participants" : @[]}], "no room without an ID");

    NSDate *now = NSDate.date;
    SNHuddleInvite *invite = [SNHuddleInvite inviteWithJSON:@{@"type" : @"huddle_invite", @"channel_id" : @"D05SAM", @"call_id" : @"R03", @"sender_user_id" : @"U02SAM", @"team_id" : @"T0NORTHWND"} received:now];
    SNExpect([invite.conversationID isEqualToString:@"D05SAM"] && [invite.huddleID isEqualToString:@"R03"] && [invite.senderID isEqualToString:@"U02SAM"] && invite.received == now, "invite fields");
    SNExpect((![SNHuddleInvite inviteWithJSON:@{@"channel_id" : @"D05SAM", @"call_id" : @"R03"} received:now]), "no invite without a sender");
}

SN_TEST(HuddleUserStateFromProfile) {
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    SNUser *user = [SNUser userWithJSON:@{@"id" : @"U02SAM", @"name" : @"sam", @"profile" : @{@"huddle_state" : @"in_a_huddle", @"huddle_state_expiration_ts" : @(now + 300), @"huddle_state_channel_id" : @"C01GENERAL"}}];
    SNExpect([user.huddleState isEqualToString:@"in_a_huddle"] && [user.huddleChannelID isEqualToString:@"C01GENERAL"], "huddle state and channel");
    SNExpect([user isInHuddleAt:NSDate.date] && ![user isInHuddleAt:[NSDate dateWithTimeIntervalSince1970:now + 301]], "in a huddle until it expires");
    SNUser *unbounded = [user userByMergingJSON:@{@"profile" : @{@"huddle_state" : @"in_a_huddle"}}];
    SNExpect(![unbounded isInHuddleAt:NSDate.date], "a state without an expiration is not believed, as the official client");
    SNUser *left = [user userByMergingJSON:@{@"profile" : @{@"huddle_state" : @"default_unset", @"huddle_state_expiration_ts" : @0}}];
    SNExpect(![left isInHuddleAt:NSDate.date], "left");
}

SN_TEST(HuddleFollowsRoomEvents) {
    SNStore *store = Store();
    SNExpect(![store huddleInConversation:@"C01GENERAL"] && ![store isUserInHuddle:@"U02SAM"], "nothing at first");
    NSArray<SNChange *> *changes = Changes(store, ^{ [store applyEvent:RoomEvent(@"sh_room_join", @"U02SAM", Room(@"R01ROOM", @[ @"U02SAM" ], NO), @"1795400000.000001")]; });
    SNHuddle *huddle = [store huddleInConversation:@"C01GENERAL"];
    SNExpect([huddle.identifier isEqualToString:@"R01ROOM"] && huddle.participantIDs.count == 1, "the join starts the conversation's huddle");
    SNExpect(changes.count == 1 && [Announced(changes, @"huddles") isEqualToSet:[NSSet setWithObject:@"C01GENERAL"]], "one change naming the conversation");
    SNExpect([Announced(changes, @"users") containsObject:@"U02SAM"] && [store isUserInHuddle:@"U02SAM"], "the participant is in a huddle");

    changes = Changes(store, ^{ [store applyEvent:RoomEvent(@"sh_room_join", @"U03PRIYA", Room(@"R01ROOM", @[ @"U02SAM", @"U03PRIYA" ], NO), @"1795400000.000002")]; });
    SNExpect([store huddleInConversation:@"C01GENERAL"].participantIDs.count == 2, "a second participant");
    SNExpect([Announced(changes, @"users") isEqualToSet:[NSSet setWithObject:@"U03PRIYA"]] && [Announced(changes, @"huddles") containsObject:@"C01GENERAL"], "only the newcomer is announced");

    changes = Changes(store, ^{ [store applyEvent:RoomEvent(@"sh_room_update", @"U03PRIYA", Room(@"R01ROOM", @[ @"U02SAM", @"U03PRIYA" ], NO), @"1795400000.000003")]; });
    SNExpect(changes.count == 0, "the same room again announces nothing");

    // Delivered late: an older event says less than the store already knows.
    changes = Changes(store, ^{ [store applyEvent:RoomEvent(@"sh_room_join", @"U02SAM", Room(@"R01ROOM", @[ @"U02SAM" ], NO), @"1795400000.000001")]; });
    SNExpect(changes.count == 0 && [store huddleInConversation:@"C01GENERAL"].participantIDs.count == 2, "an older event is ignored");

    changes = Changes(store, ^{ [store applyEvent:RoomEvent(@"sh_room_leave", @"U03PRIYA", Room(@"R01ROOM", @[ @"U02SAM" ], NO), @"1795400000.000004")]; });
    SNExpect(![store isUserInHuddle:@"U03PRIYA"] && [store isUserInHuddle:@"U02SAM"] && [Announced(changes, @"users") isEqualToSet:[NSSet setWithObject:@"U03PRIYA"]], "who left is out");

    changes = Changes(store, ^{ [store applyEvent:RoomEvent(@"sh_room_leave", @"U02SAM", Room(@"R01ROOM", @[], NO), @"1795400000.000005")]; });
    SNExpect(![store huddleInConversation:@"C01GENERAL"] && [Announced(changes, @"huddles") containsObject:@"C01GENERAL"], "the last to leave takes the huddle away");
    SNExpect(![store isUserInHuddle:@"U02SAM"] && [Announced(changes, @"users") containsObject:@"U02SAM"], "and its last participant");

    [store applyEvent:RoomEvent(@"sh_room_join", @"U02SAM", Room(@"R01ROOM", @[ @"U02SAM" ], NO), @"1795400000.000006")];
    SNExpect([store huddleInConversation:@"C01GENERAL"] != nil, "someone back in the same room before it ended");
    changes = Changes(store, ^{ [store applyEvent:RoomEvent(@"sh_room_update", @"U02SAM", Room(@"R01ROOM", @[], YES), @"1795400000.000007")]; });
    SNExpect(![store huddleInConversation:@"C01GENERAL"] && [Announced(changes, @"huddles") containsObject:@"C01GENERAL"], "ended");
    [store applyEvent:RoomEvent(@"sh_room_join", @"U02SAM", Room(@"R01ROOM", @[ @"U02SAM" ], NO), nil)];
    SNExpect(![store huddleInConversation:@"C01GENERAL"], "an ended huddle never starts again");

    [store applyEvent:RoomEvent(@"sh_room_join", @"U03PRIYA", Room(@"R02NEXT", @[ @"U03PRIYA" ], NO), nil)];
    SNExpect([[store huddleInConversation:@"C01GENERAL"].identifier isEqualToString:@"R02NEXT"], "a new huddle in the same conversation");
}

SN_TEST(HuddleInDirectMessage) {
    SNStore *store = Store();
    NSMutableDictionary *room = [Room(@"R05CALL", @[ @"U01ALEX", @"U02SAM" ], NO) mutableCopy];
    room[@"channels"] = @[ @"D05SAM" ];
    room[@"is_dm_call"] = @YES;
    [store applyEvent:RoomEvent(@"sh_room_join", @"U01ALEX", room, nil)];
    SNHuddle *huddle = [store huddleInConversation:@"D05SAM"];
    SNExpect(huddle.isDMCall && [store isUserInHuddle:@"U01ALEX"], "a 1:1 call is the DM's huddle");
    SNExpect(![store huddleInConversation:@"C01GENERAL"], "only there");
    // A room update that is not a huddle's (no "huddle") keeps the room but names no conversation.
    [store applyEvent:@{@"type" : @"sh_room_update", @"user" : @"U02SAM", @"room" : Room(@"R06APP", @[ @"U02SAM" ], NO)}];
    SNExpect(![[store huddleInConversation:@"C01GENERAL"].identifier isEqualToString:@"R06APP"], "a call's room is not a conversation's huddle");
}

SN_TEST(HuddleFromMessages) {
    SNStore *store = Store();
    NSDictionary *thread = @{@"type" : @"message", @"subtype" : @"huddle_thread", @"channel" : @"C01GENERAL", @"user" : @"U02SAM", @"text" : @"",
                             @"ts" : @"1795400000.000100", @"room" : Room(@"R01ROOM", @[ @"U02SAM" ], NO)};
    NSArray<SNChange *> *changes = Changes(store, ^{ [store applyEvent:thread]; });
    SNExpect([[store huddleInConversation:@"C01GENERAL"].identifier isEqualToString:@"R01ROOM"], "a huddle_thread message names its conversation's huddle");
    SNExpect([Announced(changes, @"huddles") containsObject:@"C01GENERAL"] && [Announced(changes, @"users") containsObject:@"U02SAM"], "announced");

    NSMutableDictionary *ended = [thread mutableCopy];
    ended[@"room"] = Room(@"R01ROOM", @[], YES);
    [store applyEvent:@{@"type" : @"message", @"subtype" : @"message_changed", @"channel" : @"C01GENERAL", @"message" : ended}];
    SNExpect(![store huddleInConversation:@"C01GENERAL"], "message_changed's room ends it");

    // Once an event described the conversation, a message's copy no longer decides it.
    [store applyEvent:RoomEvent(@"sh_room_join", @"U03PRIYA", Room(@"R02NEXT", @[ @"U03PRIYA" ], NO), nil)];
    NSMutableDictionary *stale = [thread mutableCopy];
    stale[@"ts"] = @"1795400100.000200";
    stale[@"room"] = Room(@"R07STALE", @[ @"U02SAM" ], NO);
    [store applyEvent:stale];
    SNExpect([[store huddleInConversation:@"C01GENERAL"].identifier isEqualToString:@"R02NEXT"], "the event's huddle stays");
    NSMutableDictionary *plain = [@{@"type" : @"message", @"channel" : @"C01GENERAL", @"user" : @"U02SAM", @"text" : @"hi", @"ts" : @"1795400200.000300"} mutableCopy];
    [store applyEvent:plain];
    SNExpect([[store huddleInConversation:@"C01GENERAL"].identifier isEqualToString:@"R02NEXT"], "other messages change nothing");
}

SN_TEST(HuddleFromFixtureHistory) {
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    [source loadConversation:@"C02RANDOM"];
    SNExpect(SNWaitUntil(2, ^BOOL { return [source huddleInConversation:@"C02RANDOM"] != nil; }), "the fetched history's huddle_thread names the huddle");
    SNHuddle *huddle = [source huddleInConversation:@"C02RANDOM"];
    SNExpect([huddle.identifier isEqualToString:@"R01LIVE"] && [huddle.participantIDs isEqualToArray:(@[ @"U02SAM", @"U03PRIYA" ])], "the going one, not the ended one");
    SNExpect([source isUserInHuddle:@"U03PRIYA"] && ![source isUserInHuddle:@"U05TAYLOR"], "its participants are in a huddle");

    // The huddle_thread message shown follows the room's events.
    NSMutableDictionary *room = [huddle.json mutableCopy];
    room[@"participants"] = @[ @"U02SAM", @"U03PRIYA", @"U04JORDAN" ];
    NSArray<SNChange *> *changes = Changes(source, ^{
        [source applyEvent:@{@"type" : @"sh_room_join", @"user" : @"U04JORDAN", @"room" : room, @"huddle" : @{@"channel_id" : @"C02RANDOM"}}];
    });
    SNMessage *message = nil;
    for (SNMessage *candidate in [source messagesInConversation:@"C02RANDOM"])
        if ([candidate.ts isEqualToString:@"1795294800.000110"]) message = candidate;
    SNExpect([message.json[@"room"][@"participants"] count] == 3, "the message's room has the newcomer");
    SNExpect([Announced(changes, @"messageKeys") containsObject:SNMessageKey(message)], "and the message is announced");
}

SN_TEST(HuddleOnlyFromTheNewestThread) {
    SNStore *store = Store();
    NSMutableDictionary *open = [Room(@"R09OLD", @[ @"U02SAM" ], NO) mutableCopy];
    open[@"date_start"] = @1795300000;
    NSArray *messages = @[ @{@"type" : @"message", @"subtype" : @"huddle_thread", @"user" : @"U03PRIYA", @"text" : @"", @"ts" : @"1795400000.000100", @"room" : Room(@"R10NEW", @[], YES)},
                           @{@"type" : @"message", @"subtype" : @"huddle_thread", @"user" : @"U02SAM", @"text" : @"", @"ts" : @"1795300000.000100", @"room" : open} ];
    [store applyNewestHistory:@{@"messages" : messages, @"has_more" : @NO} inConversation:@"C01GENERAL"];
    SNSettle(0.05);
    SNExpect(![store huddleInConversation:@"C01GENERAL"], "an open huddle behind a newer ended one is not brought back");
    SNExpect(![store isUserInHuddle:@"U02SAM"], "nor its people");
}

SN_TEST(HuddleInvitesRing) {
    SNStore *store = Store();
    store.huddleInviteTimeout = 0.3;
    NSDictionary *invite = @{@"type" : @"huddle_invite", @"channel_id" : @"D05SAM", @"call_id" : @"R05CALL", @"sender_user_id" : @"U02SAM", @"team_id" : @"T0NORTHWND"};
    NSArray<SNChange *> *changes = Changes(store, ^{ [store applyEvent:invite]; });
    SNExpect(store.huddleInvites.count == 1 && [store.huddleInvites.firstObject.senderID isEqualToString:@"U02SAM"], "an invitation rings");
    SNExpect([Announced(changes, @"huddleInvites") count] == 1, "announced");
    [store applyEvent:invite];
    SNExpect(store.huddleInvites.count == 1, "one per conversation");

    changes = Changes(store, ^{ [store applyEvent:@{@"type" : @"huddle_invite_cancel", @"channel_id" : @"D05SAM"}]; });
    SNExpect(store.huddleInvites.count == 0 && [Announced(changes, @"huddleInvites") count] == 1, "cancelled");

    [store applyEvent:invite];
    changes = Changes(store, ^{ [store dismissHuddleInvite:store.huddleInvites.firstObject]; });
    SNExpect(store.huddleInvites.count == 0 && [Announced(changes, @"huddleInvites") count] == 1, "dismissed");

    [store applyEvent:invite];
    SNExpect(SNWaitUntil(2, ^BOOL { return store.huddleInvites.count == 0; }), "missed after the timeout");

    NSMutableDictionary *room = [Room(@"R05CALL", @[ @"U02SAM" ], NO) mutableCopy];
    room[@"channels"] = @[ @"D05SAM" ];
    store.huddleInviteTimeout = 0;
    [store applyEvent:invite];
    [store applyEvent:RoomEvent(@"sh_room_join", @"U01ALEX", room, nil)];
    SNExpect(store.huddleInvites.count == 0, "joining (here or elsewhere) answers it");
    [store applyEvent:invite];
    room[@"pending_invitees"] = @{@"U03PRIYA" : @"ringing"};
    [store applyEvent:RoomEvent(@"sh_room_update", @"U02SAM", room, nil)];
    SNExpect(store.huddleInvites.count == 0, "no longer among the invitees");
    [store applyEvent:invite];
    room[@"pending_invitees"] = @{@"U01ALEX" : @"ringing"};
    [store applyEvent:RoomEvent(@"sh_room_update", @"U02SAM", room, nil)];
    SNExpect(store.huddleInvites.count == 1, "still invited");
    room[@"participants"] = @[];
    [store applyEvent:RoomEvent(@"sh_room_leave", @"U02SAM", room, nil)];
    SNExpect(store.huddleInvites.count == 0, "nobody left to answer");
}

SN_TEST(HuddleProfileStateExpires) {
    SNStore *store = Store();
    NSTimeInterval soon = NSDate.date.timeIntervalSince1970 + 0.3;
    NSArray<SNChange *> *changes = Changes(store, ^{
        [store applyEvent:@{@"type" : @"user_change", @"user" : @{@"id" : @"U03PRIYA", @"name" : @"priya",
                                                                  @"profile" : @{@"real_name" : @"Priya Nair", @"huddle_state" : @"in_a_huddle", @"huddle_state_expiration_ts" : @(soon)}}}];
    });
    SNExpect([store isUserInHuddle:@"U03PRIYA"] && [Announced(changes, @"users") containsObject:@"U03PRIYA"], "in a huddle by the profile");
    __block BOOL announced = NO;
    id observer = SNObserveChanges(store, ^(SNChange *change) {
        announced = announced || [change.users containsObject:@"U03PRIYA"];
    });
    SNExpect(SNWaitUntil(2, ^BOOL { return announced; }) && ![store isUserInHuddle:@"U03PRIYA"], "announced again when it expires");
    SNStopObserving(observer);
}

SN_TEST(HuddleCallBlockUpdates) {
    SNStore *store = Store();
    NSDictionary *v1 = @{@"id" : @"R08APP", @"app_id" : @"A01CALLS", @"name" : @"Weekly sync", @"created_by" : @"U02SAM", @"date_start" : @1795400000,
                         @"active_participants" : @[ @{@"slack_id" : @"U02SAM"} ], @"all_participants" : @[ @{@"slack_id" : @"U02SAM"} ],
                         @"display_id" : @"123-456", @"join_url" : @"https://calls.example.com/j/123", @"channels" : @[ @"C01GENERAL" ], @"has_ended" : @NO};
    NSDictionary *block = @{@"type" : @"call", @"block_id" : @"R08APP", @"call_id" : @"R08APP", @"api_decoration_available" : @NO,
                            @"call" : @{@"v1" : v1, @"media_backend_type" : @"platform_call"}};
    [store applyNewestHistory:@{@"messages" : @[ @{@"type" : @"message", @"user" : @"U02SAM", @"text" : @"", @"ts" : @"1795400000.000100", @"blocks" : @[ block ]} ], @"has_more" : @NO}
               inConversation:@"C01GENERAL"];
    NSMutableDictionary *ended = [v1 mutableCopy];
    ended[@"has_ended"] = @YES;
    ended[@"active_participants"] = @[];
    NSArray<SNChange *> *changes = Changes(store, ^{
        [store applyEvent:@{@"type" : @"call_block_updated", @"block" : @{@"type" : @"call", @"call_id" : @"R08APP", @"block_id" : @"R08APP", @"call" : @{@"v1" : ended, @"media_backend_type" : @"platform_call"}}}];
    });
    SNMessage *message = [store messagesInConversation:@"C01GENERAL"].lastObject;
    SNExpect([message.blocks.firstObject[@"call"][@"v1"][@"has_ended"] boolValue], "the call block takes the update");
    SNExpect([Announced(changes, @"messageKeys") containsObject:SNMessageKey(message)], "and its message is announced");
}

SN_TEST(HuddleThreadLeavesTheChannelRead) {
    SNStore *store = Store();
    __block NSInteger arrived = 0;
    store.messageArrived = ^(SNMessage *message, SNConversation *conversation) { arrived++; };
    [store applyCounts:@{@"channels" : @[ @{@"id" : @"C01GENERAL", @"last_read" : @"1795300000.000100", @"has_unreads" : @NO, @"mention_count" : @0} ]}];
    [store applyEvent:@{@"type" : @"message", @"subtype" : @"huddle_thread", @"channel" : @"C01GENERAL", @"user" : @"U02SAM", @"ts" : @"1795400000.000100",
                        @"text" : @"", @"room" : Room(@"R09LIVE", @[ @"U02SAM" ], NO)}];
    SNExpect(![store conversationWithID:@"C01GENERAL"].hasUnreads && arrived == 0, "a huddle's card neither marks the channel unread nor notifies");
    [store applyEvent:@{@"type" : @"message", @"channel" : @"C01GENERAL", @"user" : @"U02SAM", @"ts" : @"1795400001.000100", @"text" : @"hi"}];
    SNExpect([store conversationWithID:@"C01GENERAL"].hasUnreads && arrived == 1, "a message still does");
}

/// A controller that only notes what it was asked.
@interface SNNotingCallController : SNCallController
@property (nonatomic) NSMutableArray<NSString *> *asked;
@end

@implementation SNNotingCallController
- (void)joinHuddle:(SNHuddle *)huddle inConversation:(NSString *)conversationID { [self.asked addObject:[@"join " stringByAppendingString:huddle.identifier]]; }
- (void)startHuddleInConversation:(NSString *)conversationID muted:(BOOL)muted { [self.asked addObject:[NSString stringWithFormat:@"start %@%@", conversationID, muted ? @" muted" : @""]]; }
@end

SN_TEST(HuddleButtonJoinsOrStarts) {
    SNStore *store = Store();
    SNNotingCallController *calls = [[SNNotingCallController alloc] initWithAPI:[SNTestAPI new] urlSession:NSURLSession.sharedSession userID:@"U01ALEX" recoveryFile:nil];
    calls.asked = [NSMutableArray new];
    store.callController = calls;
    [store joinHuddleInConversation:@"C01GENERAL"];
    SNExpect(calls.asked.count == 0, "nothing without media");
    calls.makeMedia = ^SNCallMedia *(NSArray<SNICEServer *> *servers) { return nil; };
    [store joinHuddleInConversation:@"C01GENERAL"];
    [store joinHuddleInConversation:@"D05SAM"];
    SNExpect(([calls.asked isEqual:@[ @"start C01GENERAL", @"start D05SAM" ]]), "no huddle going on: starts one, the microphone on");
    [store applyPreferences:@{@"huddles_mute_by_default" : @YES}];
    [store joinHuddleInConversation:@"C01GENERAL"];
    SNExpect([calls.asked.lastObject isEqualToString:@"start C01GENERAL muted"], "muted with huddles_mute_by_default");
    [store applyEvent:RoomEvent(@"sh_room_join", @"U02SAM", Room(@"R01GOING", @[ @"U02SAM" ], NO), @"1795400001.000100")];
    [store joinHuddleInConversation:@"C01GENERAL"];
    SNExpect([calls.asked.lastObject isEqualToString:@"join R01GOING"], "a huddle going on: joins it");
}

SN_TEST(HuddleAskedOfTheEdgeAPIWhenRead) {
    SNTestAPI *api = [SNTestAPI new];
    SNStore *store = Store();
    store.api = api;
    __block NSDictionary *(^answer)(NSArray *ids) = ^NSDictionary *(NSArray *ids) {
        return @{@"ok" : @YES, @"huddles" : @[ @{@"channel_id" : @"C01GENERAL", @"call_id" : @"R02EDGE", @"room_id" : @"R02EDGE", @"active_members" : @[ @"U02SAM", @"U03PRIYA" ], @"dropped_members" : @[ @"U03PRIYA" ]} ],
                 @"failed_ids" : @[], @"invalid_ids" : @[]};
    };
    api.edgeAnswer = ^NSDictionary *(NSString *path, NSDictionary *body) { return answer(body[@"channel_ids"]); };
    SNExpect(![store huddleInConversation:@"C01GENERAL"] && ![store huddleInConversation:@"D05SAM"] && ![store huddleInConversation:@"C01GENERAL"], "nothing known yet");
    NSArray<SNChange *> *changes = Changes(store, ^{ SNWaitUntil(1, ^BOOL { return [store huddleInConversation:@"C01GENERAL"] != nil; }); });
    SNExpect(([api.calls isEqual:@[ @[ @"huddles/info", @{@"channel_ids" : @[ @"C01GENERAL", @"D05SAM" ]} ] ]]), "one huddles/info for the reads of a turn, each conversation once");
    SNHuddle *huddle = [store huddleInConversation:@"C01GENERAL"];
    SNExpect([huddle.identifier isEqualToString:@"R02EDGE"] && [huddle.participantIDs isEqual:@[ @"U02SAM" ]], "its huddle, without the people who dropped");
    SNExpect([store isUserInHuddle:@"U02SAM"] && ![store isUserInHuddle:@"U03PRIYA"], "who is in it");
    BOOL announced = NO;
    for (SNChange *change in changes) announced = announced || [change.huddles containsObject:@"C01GENERAL"];
    SNExpect(announced, "announced");
    SNExpect(![store huddleInConversation:@"D05SAM"], "the DM has none");

    // A huddle a message left open shows until Slack says it is over.
    [store applyConversations:@[ @{@"id" : @"G01GROUP", @"is_group" : @YES, @"is_member" : @YES, @"name" : @"group"} ]];
    answer = ^NSDictionary *(NSArray *ids) { return @{@"ok" : @YES, @"huddles" : @[]}; };
    NSMutableDictionary *stale = [Room(@"R03STALE", @[ @"U02SAM" ], NO) mutableCopy];
    stale[@"channels"] = @[ @"G01GROUP" ];
    [store applyEvent:@{@"type" : @"message", @"subtype" : @"huddle_thread", @"channel" : @"G01GROUP", @"user" : @"U02SAM", @"ts" : @"1795400000.000200", @"text" : @"", @"room" : stale}];
    SNExpect([[store huddleInConversation:@"G01GROUP"].identifier isEqualToString:@"R03STALE"], "the message's huddle at once");
    SNExpect(SNWaitUntil(1, ^BOOL { return ![store huddleInConversation:@"G01GROUP"]; }) && api.calls.count == 2, "asked, and an answer without it ends it");

    // After a reconnect that missed events it is asked again, and an event while the question is
    // out decides.
    answer = ^NSDictionary *(NSArray *ids) {
        [store applyEvent:RoomEvent(@"sh_room_join", @"U02SAM", Room(@"R04LIVE", @[ @"U02SAM" ], NO), @"1795400002.000100")];
        return @{@"ok" : @YES, @"huddles" : @[]};
    };
    [store forgetHuddleAnswers];
    [store huddleInConversation:@"C01GENERAL"];
    SNExpect(SNWaitUntil(1, ^BOOL { return api.calls.count == 3; }), "asked again");
    SNSettle(0.05);
    SNExpect([[store huddleInConversation:@"C01GENERAL"].identifier isEqualToString:@"R04LIVE"], "the event's huddle stays");

    // No answer changes nothing, and is not asked again until a reconnect.
    api.edgeAnswer = ^NSDictionary *(NSString *path, NSDictionary *body) { return nil; };
    [store huddleInConversation:@"D06NEW"];
    SNSettle(0.05);
    [store huddleInConversation:@"D06NEW"];
    SNSettle(0.05);
    SNExpect(api.calls.count == 4, "asked once");
}
