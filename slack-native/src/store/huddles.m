// Owns huddles in the store, kept as the official client keeps them: every room Slack sends, by ID
// (sh_room_* events, and any message carrying a room, as its slurpCalls), each conversation's
// huddle as the sh_room_* events last described it (its activeChannels), the invitations ringing,
// and who is in a huddle. In memory only, as the official client's huddle store; rooms come back
// with the messages that carry them.
//
// As the official client, a conversation whose huddle no event has described is asked of the edge
// API (huddles/info) when it is first read; meanwhile its huddle is the newest huddle_thread
// message of its history fetched in this session.
#import "model/json.h"
#import "store/internal.h"

// Implements part of SNSource, which the primary class adopts (see internal.h).
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

@interface SNHuddleBook : NSObject
@property (nonatomic) NSMutableDictionary<NSString *, SNHuddle *> *rooms;
@property (nonatomic) NSMutableArray<NSString *> *roomOrder;
/// Conversation ID -> the ID of the room going on there.
@property (nonatomic) NSMutableDictionary<NSString *, NSString *> *active;
/// Conversations and rooms an sh_room_* event described in this session: a room in a message,
/// perhaps older than the event, no longer decides them.
@property (nonatomic) NSMutableSet<NSString *> *eventConversations, *eventRooms;
/// Room ID -> event_ts of the newest sh_room_* event applied (they may arrive out of order).
@property (nonatomic) NSMutableDictionary<NSString *, NSString *> *eventTimes;
/// Conversations asked of huddles/info, or that an event described, since the connection last
/// missed events; and the ones waiting for the next ask.
@property (nonatomic) NSMutableSet<NSString *> *asked;
@property (nonatomic) NSMutableOrderedSet<NSString *> *wanted;
/// sh_room_* events applied so far, and each conversation's count at its latest: an answer asked
/// before an event says nothing newer about that conversation.
@property (nonatomic) NSUInteger eventCount;
@property (nonatomic) NSMutableDictionary<NSString *, NSNumber *> *eventMarks;
@property (nonatomic) NSMutableArray<SNHuddleInvite *> *invites;
/// Users whose profile says they are in a huddle until a time still to come.
@property (nonatomic) NSMutableSet<NSString *> *expiring;
/// Conversation ID -> ts of the newest huddle_thread its history pages brought: an older one no
/// longer names the conversation's huddle.
@property (nonatomic) NSMutableDictionary<NSString *, NSString *> *newestThreads;
@property (nonatomic) NSTimer *inviteTimer, *stateTimer;
@end

@implementation SNHuddleBook

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _rooms = [NSMutableDictionary new];
    _roomOrder = [NSMutableArray new];
    _active = [NSMutableDictionary new];
    _eventConversations = [NSMutableSet new];
    _eventRooms = [NSMutableSet new];
    _eventTimes = [NSMutableDictionary new];
    _asked = [NSMutableSet new];
    _wanted = [NSMutableOrderedSet new];
    _eventMarks = [NSMutableDictionary new];
    _invites = [NSMutableArray new];
    _expiring = [NSMutableSet new];
    _newestThreads = [NSMutableDictionary new];
    return self;
}

- (void)dealloc {
    [_inviteTimer invalidate];
    [_stateTimer invalidate];
}

@end

/// A timer that also fires while a menu or a drag holds the run loop.
static NSTimer *SNHuddleTimer(NSDate *date, void (^block)(void)) {
    NSTimer *timer = [[NSTimer alloc] initWithFireDate:date interval:0 repeats:NO block:^(NSTimer *fired) { block(); }];
    [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
    return timer;
}

@implementation SNStore (Huddles)

- (SNHuddleBook *)book {
    return self.huddleBook ?: (self.huddleBook = [SNHuddleBook new]);
}

- (NSTimeInterval)inviteTimeout { return self.huddleInviteTimeout ?: SNHuddleInviteTimeout; }

#pragma mark SNSource

- (SNHuddle *)huddleInConversation:(NSString *)conversationID {
    [self askHuddleOf:conversationID];
    return [self heldHuddleIn:conversationID];
}

/// What the store holds, without asking Slack.
- (SNHuddle *)heldHuddleIn:(NSString *)conversationID {
    NSString *roomID = self.book.active[conversationID];
    SNHuddle *huddle = roomID ? self.book.rooms[roomID] : nil;
    return huddle.isActive ? huddle : nil;
}

- (BOOL)isUserInHuddle:(NSString *)userID {
    if ([[self knownUserWithID:userID] isInHuddleAt:NSDate.date]) return YES;
    for (NSString *conversationID in self.book.active)
        if ([[self heldHuddleIn:conversationID].participantIDs containsObject:userID]) return YES;
    return NO;
}

- (NSArray<SNHuddleInvite *> *)huddleInvites {
    NSDate *now = NSDate.date;
    NSTimeInterval timeout = self.inviteTimeout;
    return [self.book.invites filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(SNHuddleInvite *invite, NSDictionary *bindings) {
        return [now timeIntervalSinceDate:invite.received] < timeout;
    }]];
}

- (void)dismissHuddleInvite:(SNHuddleInvite *)invite {
    [self performChanges:^{
        [self removeInvites:^BOOL(SNHuddleInvite *held) { return held == invite || ([held.conversationID isEqualToString:invite.conversationID] && [held.huddleID isEqualToString:invite.huddleID]); }];
    }];
}

#pragma mark Events

- (void)applyHuddleEvent:(NSDictionary *)event type:(NSString *)type {
    if ([type isEqualToString:@"huddle_invite"]) [self applyInvite:event];
    else if ([type isEqualToString:@"huddle_invite_cancel"]) {
        NSString *conversationID = SNJSONString(event, @"channel_id");
        [self removeInvites:^BOOL(SNHuddleInvite *invite) { return [invite.conversationID isEqualToString:conversationID]; }];
    } else if ([type isEqualToString:@"call_block_updated"]) [self applyCallBlock:SNJSONObject(event, @"block")];
    else if ([type hasPrefix:@"sh_room_"]) [self applyRoomEvent:event type:type];
}

- (void)applyRoomEvent:(NSDictionary *)event type:(NSString *)type {
    NSDictionary *room = SNJSONObject(event, @"room");
    NSString *roomID = SNJSONString(room, @"id");
    if (!roomID) return;
    NSString *when = SNJSONString(event, @"event_ts");
    NSString *newest = self.book.eventTimes[roomID];
    if (when && newest && SNCompareTS(when, newest) == NSOrderedAscending) return;
    if (when) self.book.eventTimes[roomID] = when;
    NSDictionary *about = SNJSONObject(event, @"huddle");
    NSString *conversationID = SNJSONString(about, @"channel_id");
    NSUInteger mark = ++self.book.eventCount;
    for (NSString *described in [SNJSONStrings(room, @"channels") arrayByAddingObject:conversationID ?: @""])
        if (described.length) {
            self.book.eventMarks[described] = @(mark);
            [self.book.asked addObject:described];
        }
    // The event's huddle may know the thread when its room does not yet.
    NSString *threadTS = SNJSONString(about, @"thread_root_ts");
    if (threadTS && !room[@"thread_root_ts"]) room = SNJSONMerge(room, @{@"thread_root_ts" : threadTS});
    SNHuddle *huddle = [self putRoom:room inConversation:conversationID fromEvent:YES];
    if (!conversationID) return;
    // As the official client, an invite goes once the user is in that huddle, it is over, or the
    // user is no longer among the invitees it lists.
    NSDictionary *invitees = SNJSONObject(room, @"pending_invitees");
    BOOL joined = [type isEqualToString:@"sh_room_join"] && [SNJSONString(event, @"user") isEqualToString:self.meID];
    BOOL uninvited = [type isEqualToString:@"sh_room_update"] && invitees && self.meID && !invitees[self.meID];
    if (joined || uninvited || !huddle.isActive)
        [self removeInvites:^BOOL(SNHuddleInvite *invite) { return [invite.conversationID isEqualToString:conversationID] && [invite.huddleID isEqualToString:roomID]; }];
}

- (void)applyRoomInMessageEvent:(NSDictionary *)event {
    NSString *conversationID = SNJSONString(event, @"channel");
    NSString *subtype = SNJSONString(event, @"subtype");
    NSDictionary *message = [subtype isEqualToString:@"message_changed"] || [subtype isEqualToString:@"message_replied"] ? SNJSONObject(event, @"message") : event;
    NSDictionary *room = SNJSONObject(message, @"room");
    if (!conversationID || !room) return;
    BOOL thread = [SNJSONString(message, @"subtype") isEqualToString:@"huddle_thread"];
    NSString *ts = SNJSONString(message, @"ts"), *seen = self.book.newestThreads[conversationID];
    if (thread && ts && (!seen || SNCompareTS(ts, seen) == NSOrderedDescending)) self.book.newestThreads[conversationID] = ts;
    [self putRoom:room inConversation:thread ? conversationID : nil fromEvent:NO];
}

- (void)noteRoomsIn:(NSArray<SNMessage *> *)page ofConversation:(NSString *)conversationID {
    SNHuddleBook *book = self.book;
    NSString *newest = nil;
    for (SNMessage *message in page)
        if ([message.subtype isEqualToString:@"huddle_thread"] && SNJSONObject(message.json, @"room")) newest = message.ts;
    NSString *seen = book.newestThreads[conversationID];
    // Only the newest huddle_thread can be the huddle going on: an older one left open by a missed
    // update must not bring a finished huddle back.
    BOOL names = newest && (!seen || SNCompareTS(newest, seen) != NSOrderedAscending);
    if (names) book.newestThreads[conversationID] = newest;
    for (SNMessage *message in page) {
        NSDictionary *room = SNJSONObject(message.json, @"room");
        if (room) [self putRoom:room inConversation:names && [message.ts isEqualToString:newest] ? conversationID : nil fromEvent:NO];
    }
}

#pragma mark huddles/info

/// Conversations the official client would ask about: channels, group DMs and DMs by ID.
static BOOL SNHasHuddles(NSString *conversationID) {
    unichar first = conversationID.length > 1 ? [conversationID characterAtIndex:0] : 0;
    return first == 'C' || first == 'G' || first == 'D';
}

- (void)askHuddleOf:(NSString *)conversationID {
    SNHuddleBook *book = self.book;
    if (!self.api || !SNHasHuddles(conversationID) || [book.asked containsObject:conversationID]) return;
    [book.asked addObject:conversationID];
    [book.wanted addObject:conversationID];
    if (book.wanted.count > 1) return;
    // The reads of one layout pass go out together, as the official client's object fetcher
    // batches them.
    __weak SNStore *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf askForHuddles]; });
}

/// huddles/info as fetchHuddlesByChannelId: 100 conversations a request.
- (void)askForHuddles {
    SNHuddleBook *book = self.book;
    // A copy: an ordered set's array follows the set.
    NSArray<NSString *> *wanted = [book.wanted.array copy];
    [book.wanted removeAllObjects];
    NSUInteger mark = book.eventCount;
    __weak SNStore *weakSelf = self;
    for (NSUInteger start = 0; start < wanted.count; start += 100) {
        NSArray<NSString *> *batch = [wanted subarrayWithRange:NSMakeRange(start, MIN(100, wanted.count - start))];
        // A failure is not retried in this session; a reconnect Slack did not replay asks again.
        [self.api callEdge:@"huddles/info" body:@{@"channel_ids" : batch} priority:SNCallBackground completion:^(NSDictionary *response, NSError *error) {
            SNStore *store = weakSelf;
            if (!response || !store) return;
            [store performChanges:^{ [store applyHuddleInfo:response asked:batch since:mark]; }];
        }];
    }
}

- (void)forgetHuddleAnswers {
    [self.book.asked removeAllObjects];
}

/// The answer's huddles ({channel_id, call_id, active_members, dropped_members}) are those
/// conversations' huddles, and the rest of `asked` have none, as the official client's
/// upsertHuddleAndCallObjects; except where an event came after the question.
- (void)applyHuddleInfo:(NSDictionary *)response asked:(NSArray<NSString *> *)asked since:(NSUInteger)mark {
    SNHuddleBook *book = self.book;
    NSMutableSet<NSString *> *rest = [NSMutableSet setWithArray:asked];
    for (NSString *key in @[ @"failed_ids", @"invalid_ids", @"pending_ids" ]) [rest minusSet:[NSSet setWithArray:SNJSONStrings(response, key)]];
    NSArray *huddles = SNJSONArray(response, @"huddles") ?: SNJSONArray(response, @"results");
    BOOL (^newer)(NSString *) = ^BOOL(NSString *conversationID) { return [book.eventMarks[conversationID] unsignedIntegerValue] > mark; };
    for (NSDictionary *item in huddles) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSString *conversationID = SNJSONString(item, @"channel_id"), *roomID = SNJSONString(item, @"call_id");
        if (!conversationID || ![rest containsObject:conversationID]) continue;
        if (!roomID.length) continue;
        [rest removeObject:conversationID];
        if (newer(conversationID)) continue;
        NSMutableArray *present = [SNJSONStrings(item, @"active_members") mutableCopy];
        [present removeObjectsInArray:SNJSONStrings(item, @"dropped_members")];
        if (!present.count) {
            [rest addObject:conversationID];
            continue;
        }
        SNHuddle *huddle = [self putRoom:@{@"id" : roomID, @"channels" : @[ conversationID ], @"participants" : present, @"has_ended" : @NO} inConversation:nil fromEvent:NO];
        if (huddle.isActive && ![book.active[conversationID] isEqualToString:roomID]) {
            [self clearHuddleIn:conversationID];
            book.active[conversationID] = roomID;
            [self announceParticipantsOf:nil becoming:huddle];
            [self changed:SNChangeHuddles value:conversationID];
        }
        // As an event's, Slack's answer is not undone by an older room in a message.
        [book.eventConversations addObject:conversationID];
    }
    for (NSString *conversationID in rest) {
        if (newer(conversationID)) continue;
        [self clearHuddleIn:conversationID];
        [book.eventConversations addObject:conversationID];
    }
}

- (void)clearHuddleIn:(NSString *)conversationID {
    SNHuddle *current = [self heldHuddleIn:conversationID];
    if (!self.book.active[conversationID]) return;
    [self.book.active removeObjectForKey:conversationID];
    [self announceParticipantsOf:current becoming:nil];
    [self changed:SNChangeHuddles value:conversationID];
}

#pragma mark Rooms

/// Keeps a room Slack sent and, when it is `conversationID`'s huddle (an event's huddle, a
/// huddle_thread message's room), that conversation's huddle; announces what changed.
- (SNHuddle *)putRoom:(NSDictionary *)json inConversation:(NSString *)conversationID fromEvent:(BOOL)fromEvent {
    SNHuddleBook *book = self.book;
    NSString *roomID = SNJSONString(json, @"id");
    SNHuddle *held = book.rooms[roomID];
    // A message's copy of a room an event already described says nothing newer, and an ended
    // huddle never starts again.
    if (held && !fromEvent && [book.eventRooms containsObject:roomID]) return held;
    if (held.hasEnded && !SNJSONBool(json, @"has_ended")) return held;
    SNHuddle *huddle = held ? [held huddleByMergingJSON:json] : [SNHuddle huddleWithJSON:json];
    if (!huddle) return nil;
    if (fromEvent) [book.eventRooms addObject:roomID];
    BOOL changed = ![held.json isEqualToDictionary:huddle.json];
    book.rooms[roomID] = huddle;
    [book.roomOrder removeObject:roomID];
    [book.roomOrder addObject:roomID];
    // Cap ended rooms so long sessions do not accumulate every historical huddle_thread forever.
    static const NSUInteger kEndedRoomLimit = 100;
    if (book.roomOrder.count > kEndedRoomLimit) {
        NSSet<NSString *> *activeRooms = [NSSet setWithArray:book.active.allValues];
        NSUInteger i = 0;
        while (book.roomOrder.count > kEndedRoomLimit && i < book.roomOrder.count) {
            NSString *candidate = book.roomOrder[i];
            if ([candidate isEqualToString:roomID] || [activeRooms containsObject:candidate] || book.rooms[candidate].isActive) {
                i++;
                continue;
            }
            [book.roomOrder removeObjectAtIndex:i];
            [book.rooms removeObjectForKey:candidate];
            [book.eventRooms removeObject:candidate];
            [book.eventTimes removeObjectForKey:candidate];
        }
    }

    NSMutableSet<NSString *> *conversations = [NSMutableSet new];
    for (NSString *other in book.active)
        if ([book.active[other] isEqualToString:roomID]) [conversations addObject:other];
    if (conversationID && (fromEvent || ![book.eventConversations containsObject:conversationID])) {
        if (fromEvent) [book.eventConversations addObject:conversationID];
        SNHuddle *current = [self heldHuddleIn:conversationID];
        // A message names the conversation's huddle only when it is the newest one heard of.
        BOOL newer = fromEvent || !current || huddle.dateStart >= current.dateStart;
        if (huddle.isActive && newer && ![book.active[conversationID] isEqualToString:roomID]) {
            [self announceParticipantsOf:current becoming:nil];
            book.active[conversationID] = roomID;
            [self announceParticipantsOf:nil becoming:huddle];
            [self changed:SNChangeHuddles value:conversationID];
        }
    }
    if (!changed) return huddle;
    if (conversations.count) {
        [self announceParticipantsOf:held.isActive ? held : nil becoming:huddle.isActive ? huddle : nil];
        for (NSString *other in conversations) {
            if (!huddle.isActive) [book.active removeObjectForKey:other];
            [self changed:SNChangeHuddles value:other];
        }
    }
    if (fromEvent) {
        [conversations addObjectsFromArray:huddle.conversationIDs];
        if (conversationID) [conversations addObject:conversationID];
        [self refreshMessagesWithRoom:huddle inConversations:conversations];
    }
    return huddle;
}

/// People who joined or left, as far as `isUserInHuddle:` can tell (nil: no huddle going on).
- (void)announceParticipantsOf:(SNHuddle *)before becoming:(SNHuddle *)after {
    NSMutableSet *was = [NSMutableSet setWithArray:before.participantIDs ?: @[]], *is = [NSMutableSet setWithArray:after.participantIDs ?: @[]];
    NSMutableSet *moved = [was mutableCopy];
    [moved unionSet:is];
    [was intersectSet:is];
    [moved minusSet:was];
    for (NSString *userID in moved) [self changed:SNChangeUsers value:userID];
}

/// The huddle_thread and sh_room_created messages shown from memory carry the room as events
/// describe it now, as the official client draws them from its call store.
- (void)refreshMessagesWithRoom:(SNHuddle *)huddle inConversations:(NSSet<NSString *> *)conversationIDs {
    for (NSString *conversationID in conversationIDs) {
        for (SNMessage *message in [self.histories[conversationID].messages copy]) {
            NSDictionary *room = SNJSONObject(message.json, @"room");
            if (![SNJSONString(room, @"id") isEqualToString:huddle.identifier] || [room isEqualToDictionary:huddle.json]) continue;
            [self updateMessage:message.ts inConversation:conversationID transform:^SNMessage *(SNMessage *held) {
                return [held messageByMergingJSON:@{@"room" : SNJSONMerge(SNJSONObject(held.json, @"room") ?: @{}, huddle.json)}];
            }];
        }
    }
}

/// call_block_updated: the call blocks of the messages shown from memory take the block's call.
- (void)applyCallBlock:(NSDictionary *)block {
    NSString *callID = SNJSONString(block, @"call_id");
    NSDictionary *call = SNJSONObject(block, @"call");
    if (!callID || !call) return;
    for (NSString *conversationID in SNJSONStrings(SNJSONObject(call, @"v1"), @"channels")) {
        for (SNMessage *message in [self.histories[conversationID].messages copy]) {
            BOOL holds = NO;
            for (NSDictionary *held in message.blocks)
                holds = holds || ([SNJSONString(held, @"type") isEqualToString:@"call"] && [SNJSONString(held, @"call_id") isEqualToString:callID]);
            if (!holds) continue;
            [self updateMessage:message.ts inConversation:conversationID transform:^SNMessage *(SNMessage *held) {
                NSMutableArray *blocks = [NSMutableArray new];
                for (NSDictionary *candidate in held.blocks)
                    [blocks addObject:[SNJSONString(candidate, @"type") isEqualToString:@"call"] && [SNJSONString(candidate, @"call_id") isEqualToString:callID] ? SNJSONMerge(candidate, @{@"call" : call}) : candidate];
                return [held messageByMergingJSON:@{@"blocks" : blocks}];
            }];
        }
    }
}

#pragma mark Invites

- (void)applyInvite:(NSDictionary *)event {
    SNHuddleInvite *invite = [SNHuddleInvite inviteWithJSON:event received:NSDate.date];
    if (!invite) return;
    // The official client ignores a ring into the huddle the user is already in.
    SNCall *call = self.callController.call;
    if (call && [call.huddleID isEqualToString:invite.huddleID]) return;
    // One invite per conversation: a newer ring replaces the one before.
    [self removeInvites:^BOOL(SNHuddleInvite *held) { return [held.conversationID isEqualToString:invite.conversationID]; }];
    [self.book.invites addObject:invite];
    [self changed:SNChangeHuddleInvites value:nil];
    [self scheduleInviteExpiry];
}

- (void)removeInvites:(BOOL (^)(SNHuddleInvite *invite))matching {
    NSIndexSet *gone = [self.book.invites indexesOfObjectsPassingTest:^BOOL(SNHuddleInvite *invite, NSUInteger index, BOOL *stop) { return matching(invite); }];
    if (!gone.count) return;
    [self.book.invites removeObjectsAtIndexes:gone];
    [self changed:SNChangeHuddleInvites value:nil];
    [self scheduleInviteExpiry];
}

- (void)scheduleInviteExpiry {
    SNHuddleBook *book = self.book;
    [book.inviteTimer invalidate];
    book.inviteTimer = nil;
    SNHuddleInvite *oldest = book.invites.firstObject;
    if (!oldest) return;
    __weak SNStore *weakSelf = self;
    NSTimeInterval timeout = self.inviteTimeout;
    book.inviteTimer = SNHuddleTimer([oldest.received dateByAddingTimeInterval:timeout], ^{
        SNStore *store = weakSelf;
        [store performChanges:^{
            NSDate *now = NSDate.date;
            [store removeInvites:^BOOL(SNHuddleInvite *invite) { return [now timeIntervalSinceDate:invite.received] >= timeout; }];
        }];
        [store scheduleInviteExpiry];
    });
}

#pragma mark Profiles

/// Profiles say "in a huddle" until a time; when it passes without Slack saying more, the people
/// are announced so what shows them in a huddle stops.
- (void)watchHuddleStateOf:(SNUser *)user {
    BOOL expiring = [user isInHuddleAt:NSDate.date];
    if (expiring == [self.book.expiring containsObject:user.userID]) return;
    if (expiring) [self.book.expiring addObject:user.userID];
    else [self.book.expiring removeObject:user.userID];
    [self scheduleHuddleStateExpiry];
}

- (void)scheduleHuddleStateExpiry {
    SNHuddleBook *book = self.book;
    [book.stateTimer invalidate];
    book.stateTimer = nil;
    NSTimeInterval soonest = 0;
    for (NSString *userID in book.expiring) {
        NSTimeInterval expiration = self.users[userID].huddleStateExpiration;
        if (!soonest || expiration < soonest) soonest = expiration;
    }
    if (!soonest) return;
    __weak SNStore *weakSelf = self;
    book.stateTimer = SNHuddleTimer([NSDate dateWithTimeIntervalSince1970:soonest], ^{
        SNStore *store = weakSelf;
        if (!store) return;
        NSDate *date = NSDate.date;
        NSSet *expired = [store.book.expiring objectsPassingTest:^BOOL(NSString *userID, BOOL *stop) { return ![store.users[userID] isInHuddleAt:date]; }];
        [store.book.expiring minusSet:expired];
        [store performChanges:^{
            for (NSString *userID in expired) [store changed:SNChangeUsers value:userID];
        }];
        [store scheduleHuddleStateExpiry];
    });
}

@end
