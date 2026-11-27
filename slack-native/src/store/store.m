// Owns the store's state: loading the cache, changes, the decoded-memory bound, and
// history and threads (reading, paging, merging Slack's pages with the cache).
#import "model/json.h"
#import "model/timezone.h"
#import "render/emoji.h"
#import "store/internal.h"

// SNSource's other methods live in writes.m, events.m and lookup.m (see internal.h).
#pragma clang diagnostic ignored "-Wprotocol"
#pragma clang diagnostic ignored "-Wobjc-protocol-property-synthesis"

static NSComparisonResult OrderMessages(SNMessage *a, SNMessage *b) { return SNCompareTS(a.ts, b.ts); }

@implementation SNHistory {
    NSMutableArray<SNMessage *> *_messages;
    NSMutableDictionary<NSString *, SNMessage *> *_byTS, *_byIdentifier;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _messages = [NSMutableArray new];
    _byTS = [NSMutableDictionary new];
    _byIdentifier = [NSMutableDictionary new];
    return self;
}

- (NSArray<SNMessage *> *)messages { return _messages; }
- (SNMessage *)messageWithTS:(NSString *)ts { return _byTS[ts]; }
- (SNMessage *)messageWithIdentifier:(NSString *)identifier { return _byIdentifier[identifier]; }

- (void)remember:(SNMessage *)message {
    _byTS[message.ts] = message;
    _byIdentifier[message.identifier] = message;
    if (message.sendState == SNMessagePending) _pendingCount++;
}

- (void)forget:(SNMessage *)message {
    if (_byTS[message.ts] == message) [_byTS removeObjectForKey:message.ts];
    if (_byIdentifier[message.identifier] == message) [_byIdentifier removeObjectForKey:message.identifier];
    if (message.sendState == SNMessagePending) _pendingCount--;
}

- (NSUInteger)indexOf:(SNMessage *)held {
    NSUInteger count = _messages.count;
    NSUInteger index = [_messages indexOfObject:held inSortedRange:NSMakeRange(0, count) options:NSBinarySearchingFirstEqual
                                usingComparator:^NSComparisonResult(id a, id b) { return OrderMessages(a, b); }];
    while (index < count && _messages[index] != held && OrderMessages(_messages[index], held) == NSOrderedSame) index++;
    return index < count && _messages[index] == held ? index : [_messages indexOfObjectIdenticalTo:held];
}

- (void)insertSorted:(SNMessage *)message {
    NSUInteger at = [_messages indexOfObject:message inSortedRange:NSMakeRange(0, _messages.count)
                                     options:NSBinarySearchingInsertionIndex | NSBinarySearchingLastEqual
                             usingComparator:^NSComparisonResult(id a, id b) { return OrderMessages(a, b); }];
    [_messages insertObject:message atIndex:at];
    [self remember:message];
}

- (SNMessage *)put:(SNMessage *)message {
    SNMessage *old = _byIdentifier[message.identifier] ?: _byTS[message.ts];
    if (old) [self replace:old with:nil];
    [self insertSorted:message];
    return old;
}

- (void)replace:(SNMessage *)held with:(SNMessage *)message {
    NSUInteger index = [self indexOf:held];
    if (index == NSNotFound) return;
    [self forget:held];
    if (message && [message.ts isEqualToString:held.ts]) {
        _messages[index] = message;
        [self remember:message];
        return;
    }
    [_messages removeObjectAtIndex:index];
    if (message) [self insertSorted:message];
}

- (void)setMessages:(NSArray<SNMessage *> *)messages {
    _messages = [messages sortedArrayUsingComparator:^NSComparisonResult(id a, id b) { return OrderMessages(a, b); }].mutableCopy;
    [_byTS removeAllObjects];
    [_byIdentifier removeAllObjects];
    _pendingCount = 0;
    for (SNMessage *message in _messages) [self remember:message];
}

- (void)insertOlder:(NSArray<SNMessage *> *)messages {
    [_messages insertObjects:messages atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, messages.count)]];
    for (SNMessage *message in messages) [self remember:message];
}

@end

NSString *SNLocalTS(NSString *after) {
    double now = NSDate.date.timeIntervalSince1970;
    double floor = after.doubleValue + 0.000001;
    return [NSString stringWithFormat:@"%.6f", MAX(now, floor)];
}

NSString *SNJSONText(id object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"";
}

@implementation SNStore {
    NSInteger _depth;
    SNChangeQueue *_changes;
    SNConnectionState _connectionState;
}

@synthesize workspace = _workspace;

- (instancetype)initWithDatabase:(SNDatabase *)database api:(id<SNAPI>)api {
    return [self initWithDatabase:database api:api deferred:NO];
}

- (instancetype)initWithDatabase:(SNDatabase *)database api:(id<SNAPI>)api deferred:(BOOL)deferred {
    if (!(self = [super init])) return nil;
    _database = database;
    _api = api;
    _markDelay = 5;
    _decodedLimit = 8;
    _storedMessageLimit = 1000;
    _missingDelay = 60;
    _changes = [SNChangeQueue new];
    self.users = [NSMutableDictionary new];
    self.userIDsByHandle = [NSMutableDictionary new];
    self.presences = [NSMutableDictionary new];
    self.doNotDisturbIDs = [NSMutableSet new];
    self.conversationsByID = [NSMutableDictionary new];
    self.sectionJSON = [NSMutableArray new];
    self.sectionList = @[];
    self.dmList = [NSMutableArray new];
    self.dmOrder = [NSMutableDictionary new];
    self.peoplelessDMs = [NSMutableSet new];
    self.channelList = [NSMutableArray new];
    self.prefs = @{};
    self.emojiList = @{};
    self.usergroupHandles = [NSMutableDictionary new];
    self.threadCounts = @{};
    self.histories = [NSMutableDictionary new];
    self.threads = [NSMutableDictionary new];
    self.recent = [NSMutableArray new];
    self.typing = [NSMutableDictionary new];
    self.typingSent = [NSMutableDictionary new];
    self.drafts = [NSMutableDictionary new];
    self.expandables = [NSMutableDictionary new];
    self.sending = [NSMutableSet new];
    self.marks = [NSMutableDictionary new];
    self.readKnown = [NSMutableSet new];
    self.missing = [NSMutableSet new];
    self.missingAsked = [NSMutableDictionary new];
    self.conversationsAsked = [NSMutableDictionary new];
    self.bots = [NSMutableDictionary new];
    self.botsAsked = [NSMutableDictionary new];
    self.missingHandles = [NSMutableSet new];
    self.storedWritesSinceTrim = [NSMutableDictionary new];
    self.unavailableConversations = [NSMutableSet new];
    self.remoteUserQueries = [NSMutableSet new];
    self.latestMessages = [NSMutableDictionary new];
    self.latestRequested = [NSMutableSet new];
    self.activityJSON = @[];
    self.activity = @[];
    self.activityMessages = [NSMutableDictionary new];
    self.activityMessageOrder = [NSMutableArray new];
    self.savedChanges = [NSMutableDictionary new];
    self.savedChangeOrder = [NSMutableArray new];
    self.profileOrder = [NSMutableArray new];
    self.activityMessagesAsked = [NSMutableSet new];
    self.activityMessagesWanted = [NSMutableSet new];
    self.uploads = [NSMutableDictionary new];
    self.attachedUploads = [NSMutableDictionary new];
    self.uploadQueue = [NSMutableArray new];
    self.retriedUploads = [NSMutableSet new];
    self.waitingShares = [NSMutableDictionary new];
    self.commands = @[];
    _macTimeZone = NSTimeZone.systemTimeZone;
    if (database) [self loadCacheDeferred:deferred];
    return self;
}

- (void)loadCacheDeferred:(BOOL)deferred {
    SNDatabase *db = self.database;
    NSDictionary *team = [db jsonForKey:@"workspace"];
    if ([team isKindOfClass:NSDictionary.class]) _workspace = [SNWorkspace workspaceWithJSON:team];
    NSString *me = [db jsonForKey:@"me"];
    self.meID = [me isKindOfClass:NSString.class] ? me : nil;
    if (deferred) {
        if (self.meID.length) {
            NSDictionary *meJSON = [db objectWithID:self.meID inTable:@"users"];
            SNUser *meUser = [meJSON isKindOfClass:NSDictionary.class] ? [SNUser userWithJSON:meJSON] : nil;
            if (meUser) [self holdUser:meUser];
        }
        self.usersCachePending = YES;
        self.botsCachePending = YES;
        self.usergroupsCachePending = YES;
        self.activityCachePending = YES;
        self.commandsCachePending = YES;
    } else {
        for (NSDictionary *json in [db allObjectsInTable:@"users"]) {
            SNUser *user = [json isKindOfClass:NSDictionary.class] ? [SNUser userWithJSON:json] : nil;
            if (user) [self holdUser:user];
        }
    }
    for (NSDictionary *json in [db allObjectsInTable:@"conversations"]) {
        SNConversation *conversation = [json isKindOfClass:NSDictionary.class] ? [SNConversation conversationWithJSON:json] : nil;
        if (!conversation) continue;
        self.conversationsByID[conversation.conversationID] = conversation;
        [self placeInLists:conversation was:nil];
    }
    NSArray *sections = [db jsonForKey:@"sections"];
    if ([sections isKindOfClass:NSArray.class]) {
        self.sectionJSON = [sections mutableCopy];
        self.sectionList = DecodeSections(self.sectionJSON);
    }
    NSDictionary *prefs = [db jsonForKey:@"prefs"];
    if ([prefs isKindOfClass:NSDictionary.class]) self.prefs = prefs;
    NSDictionary *emoji = [db jsonForKey:@"emoji"];
    if ([emoji isKindOfClass:NSDictionary.class]) {
        if (deferred) self->_emojiList = [emoji copy];
        else self.emojiList = emoji;
    }
    NSDictionary *threadCounts = [db jsonForKey:@"threads"];
    if ([threadCounts isKindOfClass:NSDictionary.class]) self.threadCounts = threadCounts;
    [[db jsonWithKeyPrefix:@"draft:"] enumerateKeysAndObjectsUsingBlock:^(NSString *key, id text, BOOL *stop) {
        if ([text isKindOfClass:NSString.class]) self.drafts[[key substringFromIndex:6]] = text;
    }];
    [[db jsonWithKeyPrefix:SNExpandablePrefix] enumerateKeysAndObjectsUsingBlock:^(NSString *key, id expanded, BOOL *stop) {
        if ([expanded isKindOfClass:NSNumber.class]) self.expandables[[key substringFromIndex:SNExpandablePrefix.length]] = expanded;
    }];
    if (!deferred) {
        [self loadRestOfCache];
        [self attachToMainThread];
    }
}

- (void)attachToMainThread {
    SNSetCustomEmoji(self.emojiList);
    [self performChanges:^{
        [self applyNameStyle];
        [self applyTimeZone];
    }];
}

- (void)ensureBotsCacheLoaded {
    if (!self.botsCachePending) return;
    self.botsCachePending = NO;
    NSDictionary *bots = [self.database jsonForKey:@"bots"];
    if ([bots isKindOfClass:NSDictionary.class])
        for (id json in bots.allValues) {
            SNBot *bot = [json isKindOfClass:NSDictionary.class] ? [SNBot botWithJSON:json] : nil;
            if (bot && !self.bots[bot.botID]) self.bots[bot.botID] = bot;
        }
}

- (void)ensureUsergroupsCacheLoaded {
    if (!self.usergroupsCachePending) return;
    self.usergroupsCachePending = NO;
    NSDictionary *usergroups = [self.database jsonForKey:@"usergroups"];
    if ([usergroups isKindOfClass:NSDictionary.class]) {
        for (NSString *key in usergroups)
            if (!self.usergroupHandles[key]) self.usergroupHandles[key] = usergroups[key];
    }
}

- (void)loadRestOfCache {
    self.botsCachePending = YES;
    self.usergroupsCachePending = YES;
    self.activityCachePending = YES;
    self.commandsCachePending = YES;
    [self ensureBotsCacheLoaded];
    [self loadActivityCache];
    [self loadCommandsCache];
    [self ensureUsergroupsCacheLoaded];
}

- (void)finishLoadingCache {
    if (self.usersCachePending) {
        self.usersCachePending = NO;
        [self.missingHandles removeAllObjects];
        SNDatabase *db = self.database;
        for (NSDictionary *json in [db allObjectsInTable:@"users"]) {
            SNUser *user = [json isKindOfClass:NSDictionary.class] ? [SNUser userWithJSON:json] : nil;
            if (user && !self.users[user.userID]) [self holdUser:user];
        }
    }
    [self ensureBotsCacheLoaded];
    [self loadActivityCache];
    [self loadCommandsCache];
    [self ensureUsergroupsCacheLoaded];
}

- (BOOL)hasState { return self.workspace && self.me; }

#pragma mark Changes

- (void)performChanges:(void (^)(void))changes {
    _depth++;
    if (self.database) [self.database transaction:changes];
    else changes();
    if (--_depth > 0) return;
    if (self.missing.count && self.usersMissing) {
        NSSet *missing = [self.missing copy];
        [self.missing removeAllObjects];
        // After the turn, so a burst of unknown authors is one request.
        dispatch_async(dispatch_get_main_queue(), ^{ self.usersMissing(missing); });
    }
}

- (void)changed:(SNChangeKind)kind value:(NSString *)value { [_changes note:kind value:value]; }

- (void)addChangeObserver:(id<SNChangeObserver>)observer { [_changes addObserver:observer]; }

- (SNConnectionState)connectionState { return _connectionState; }

- (void)setConnectionState:(SNConnectionState)connectionState {
    if (_connectionState == connectionState) return;
    [self performChanges:^{
        self->_connectionState = connectionState;
        [self changed:SNChangeConnection value:nil];
    }];
    // Slack's client checks the zone at every connection.
    if (connectionState == SNConnectionConnected) [self saveMacTimeZone];
}

#pragma mark Reads

- (SNUser *)me { return self.users[self.meID ?: @""]; }

- (SNUser *)loadUserFromDB:(NSString *)userID {
    if (!self.usersCachePending || !userID.length) return nil;
    NSDictionary *json = [self.database objectWithID:userID inTable:@"users"];
    SNUser *user = [json isKindOfClass:NSDictionary.class] ? [SNUser userWithJSON:json] : nil;
    if (user) [self holdUser:user];
    return user;
}

- (SNUser *)loadUserByHandleFromDB:(NSString *)handle {
    if (!self.usersCachePending || !handle.length || [self.missingHandles containsObject:handle]) return nil;
    NSDictionary *json = [self.database userWithHandle:handle];
    SNUser *user = [json isKindOfClass:NSDictionary.class] ? [SNUser userWithJSON:json] : nil;
    if (user) {
        if (!self.users[user.userID]) [self holdUser:user];
        return self.users[user.userID];
    }
    [self.missingHandles addObject:handle];
    return nil;
}

- (SNUser *)userWithID:(NSString *)userID {
    SNUser *user = self.users[userID] ?: [self loadUserFromDB:userID];
    if (!user) [self noteUser:userID];
    return user;
}

- (SNUser *)knownUserWithID:(NSString *)userID { return self.users[userID] ?: [self loadUserFromDB:userID]; }
- (SNPresence)presenceOfUser:(NSString *)userID { return (SNPresence)self.presences[userID].integerValue; }
- (BOOL)doNotDisturbOfUser:(NSString *)userID { return [self.doNotDisturbIDs containsObject:userID]; }
- (BOOL)isDecoded:(NSString *)conversationID { return self.histories[conversationID] != nil; }

- (void)noteUser:(NSString *)userID {
    if (!userID.length || [self knownUserWithID:userID] || !self.usersMissing) return;
    // Asked already: again only once the wait since then has passed, doubling each time, so a
    // user Slack never resolves (deleted, external, a bot) costs a lookup now and then, not one
    // per read.
    NSArray *asked = self.missingAsked[userID];
    if (asked && [asked[1] timeIntervalSinceNow] > 0) return;
    NSUInteger times = [asked[0] unsignedIntegerValue] + 1;
    self.missingAsked[userID] = @[ @(times), [self askAgainAfter:times] ];
    [self.missing addObject:userID];
    // Reads outside a change still get their users fetched.
    if (_depth == 0) [self performChanges:^{}];
}

- (NSDate *)askAgainAfter:(NSUInteger)times {
    return [NSDate dateWithTimeIntervalSinceNow:MIN(self.missingDelay * pow(2, (double)MIN(times - 1, 10)), 6 * 3600)];
}

/// A DM or group DM that does not say who is in it: client.dms answered without channel objects
/// before it was asked for them, and caches from then hold such DMs. conversations.info has it.
static BOOL LacksPeople(SNConversation *conversation) {
    if (conversation.kind == SNConversationDirect) return !conversation.userID.length;
    return conversation.kind == SNConversationGroupDirect && !conversation.name.length;
}

- (SNConversation *)conversationWithID:(NSString *)conversationID {
    SNConversation *conversation = self.conversationsByID[conversationID];
    if (!conversation || LacksPeople(conversation)) [self askForConversation:conversationID];
    return conversation;
}

- (SNConversation *)knownConversationWithID:(NSString *)conversationID { return self.conversationsByID[conversationID]; }
- (BOOL)isConversationUnavailable:(NSString *)conversationID { return [self.unavailableConversations containsObject:conversationID]; }

/// Slack errors about Slack itself rather than the conversation: asked again later.
static BOOL SlackFailed(NSString *error) {
    return [@[ @"internal_error", @"fatal_error", @"request_timeout", @"service_unavailable" ] containsObject:error ?: @""];
}

// conversations.info, one call at a time per ID: the UI reads conversations on every draw, so a
// call that gets no answer is repeated only after missingDelay, doubling, like users. Any other
// answer is final: the conversation, or unavailable for the session.
- (void)askForConversation:(NSString *)conversationID {
    if (!conversationID.length || !self.api || [self.unavailableConversations containsObject:conversationID]) return;
    NSArray *asked = self.conversationsAsked[conversationID];
    if (asked && [asked[1] timeIntervalSinceNow] > 0) return;
    NSUInteger times = [asked[0] unsignedIntegerValue] + 1;
    self.conversationsAsked[conversationID] = @[ @(times), NSDate.distantFuture ];
    [self request:@"conversations.info" params:@{@"channel" : conversationID, @"_x_reason" : @"conversation-info"} priority:SNCallUserFacing
       completion:^(NSDictionary *response, NSError *error) {
           NSDictionary *channel = SNJSONObject(response, @"channel");
           if (channel) [self applyConversations:@[ channel ]];
           SNConversation *known = self.conversationsByID[conversationID];
           // A DM known without its people is asked again on failure, like an unknown one.
           if (known && (channel || !LacksPeople(known))) {
               [self.conversationsAsked removeObjectForKey:conversationID];
               return;
           }
           if (!response && (error.code != SNAPIErrorSlack || SlackFailed(SNAPIErrorName(error)))) {
               self.conversationsAsked[conversationID] = @[ @(times), [self askAgainAfter:times] ];
               return;
           }
           [self.conversationsAsked removeObjectForKey:conversationID];
           [self performChanges:^{
               [self.unavailableConversations addObject:conversationID];
               [self changed:SNChangeConversations value:conversationID];
           }];
       }];
}

// bots.info, one call at a time per bot, asked again after a failure like users are.
- (SNBot *)botWithID:(NSString *)botID {
    if (!self.bots[botID] && self.botsCachePending && botID.length) [self ensureBotsCacheLoaded];
    SNBot *bot = self.bots[botID];
    if (bot || !botID.length || !self.api) return bot;
    NSArray *asked = self.botsAsked[botID];
    if (asked && [asked[1] timeIntervalSinceNow] > 0) return nil;
    NSUInteger times = [asked[0] unsignedIntegerValue] + 1;
    self.botsAsked[botID] = @[ @(times), NSDate.distantFuture ];
    [self request:@"bots.info" params:@{@"bot" : botID, @"_x_reason" : @"bots-info"} priority:SNCallBackground
       completion:^(NSDictionary *response, NSError *error) {
           SNBot *answer = [SNBot botWithJSON:SNJSONObject(response, @"bot") ?: @{}];
           if (!answer) {
               self.botsAsked[botID] = @[ @(times), [self askAgainAfter:times] ];
               return;
           }
           [self.botsAsked removeObjectForKey:botID];
           [self performChanges:^{
               [self ensureBotsCacheLoaded];
               self.bots[botID] = answer;
               NSMutableDictionary *saved = [NSMutableDictionary new];
               for (SNBot *known in self.bots.allValues) saved[known.botID] = known.json;
               [self.database setJSON:saved forKey:@"bots"];
               [self changed:SNChangeUsers value:botID];
           }];
       }];
    return nil;
}

- (NSString *)usergroupHandleWithID:(NSString *)groupID {
    if (!self.usergroupHandles[groupID] && self.usergroupsCachePending && groupID.length) [self ensureUsergroupsCacheLoaded];
    return self.usergroupHandles[groupID];
}

- (NSArray<SNSection *> *)sections { return self.sectionList; }
- (NSArray<SNConversation *> *)directMessages {
    for (NSString *conversationID in [self.peoplelessDMs copy]) [self askForConversation:conversationID];
    return [self.dmList copy];
}
- (NSArray<SNConversation *> *)memberChannels { return [self.channelList copy]; }

static NSArray<SNSection *> *DecodeSections(NSArray<NSDictionary *> *json) {
    return [SNSection orderedSections:SNJSONMap(@{@"s" : json}, @"s", ^id(NSDictionary *item) { return [SNSection sectionWithJSON:item]; })];
}

- (void)saveSections {
    [self.database setJSON:self.sectionJSON forKey:@"sections"];
    self.sectionList = DecodeSections(self.sectionJSON);
    [self changed:SNChangeLists value:nil];
}

#pragma mark Lists

/// The DM list's order: newest first, by conversation ID among equals.
- (NSComparator)dmComparator {
    NSDictionary<NSString *, NSString *> *order = self.dmOrder;
    return ^NSComparisonResult(SNConversation *a, SNConversation *b) {
        NSComparisonResult result = SNCompareTS(order[b.conversationID], order[a.conversationID]);
        return result != NSOrderedSame ? result : [a.conversationID compare:b.conversationID];
    };
}

static NSComparisonResult ByName(SNConversation *a, SNConversation *b) {
    NSComparisonResult result = [a.name compare:b.name];
    return result != NSOrderedSame ? result : [a.conversationID compare:b.conversationID];
}

static BOOL ListsChannel(SNConversation *conversation) { return conversation && !conversation.isDirect && conversation.isMember && !conversation.isArchived; }

/// `held`'s place in a list sorted by `order`, which still sorts it as when it was put.
static NSUInteger PlaceOf(NSArray *list, id held, NSComparator order) {
    return [list indexOfObject:held inSortedRange:NSMakeRange(0, list.count) options:NSBinarySearchingFirstEqual usingComparator:order];
}

static NSUInteger InsertionPlace(NSArray *list, id item, NSComparator order) {
    return [list indexOfObject:item inSortedRange:NSMakeRange(0, list.count) options:NSBinarySearchingInsertionIndex usingComparator:order];
}

- (void)placeDirectMessage:(NSString *)conversationID {
    SNConversation *conversation = self.conversationsByID[conversationID];
    NSString *was = self.dmOrder[conversationID], *order = nil;
    if (!conversation) return;
    if (conversation.isDirect && conversation.isOpen) {
        // A decoded history may hold a send newer than the conversation's latest.
        NSString *decoded = self.histories[conversationID].messages.lastObject.ts, *known = conversation.latest ?: @"0";
        order = decoded && SNCompareTS(decoded, known) == NSOrderedDescending ? decoded : known;
    }
    if (order && LacksPeople(conversation)) [self.peoplelessDMs addObject:conversationID];
    else [self.peoplelessDMs removeObject:conversationID];
    if (!was && !order) return;
    NSComparator comparator = self.dmComparator;
    NSUInteger index = was ? PlaceOf(self.dmList, conversation, comparator) : NSNotFound;
    if (index != NSNotFound && [order isEqualToString:was]) {
        self.dmList[index] = conversation;
        return;
    }
    if (index != NSNotFound) [self.dmList removeObjectAtIndex:index];
    [self.dmOrder removeObjectForKey:conversationID];
    if (order) {
        self.dmOrder[conversationID] = order;
        NSUInteger at = InsertionPlace(self.dmList, conversation, comparator);
        [self.dmList insertObject:conversation atIndex:at];
        if (at == index) return;
    }
    [self changed:SNChangeLists value:nil];
}

/// Keeps the DM and channel lists with a conversation that is new or changed (`was` before).
- (void)placeInLists:(SNConversation *)conversation was:(SNConversation *)was {
    [self placeDirectMessage:conversation.conversationID];
    BOOL listed = ListsChannel(conversation), wasListed = ListsChannel(was);
    if (!listed && !wasListed) return;
    NSUInteger index = wasListed ? PlaceOf(self.channelList, was, ^NSComparisonResult(id a, id b) { return ByName(a, b); }) : NSNotFound;
    if (index != NSNotFound && listed && [was.name isEqualToString:conversation.name]) {
        self.channelList[index] = conversation;
        return;
    }
    if (index != NSNotFound) [self.channelList removeObjectAtIndex:index];
    if (listed)
        [self.channelList insertObject:conversation atIndex:InsertionPlace(self.channelList, conversation, ^NSComparisonResult(id a, id b) { return ByName(a, b); })];
    [self changed:SNChangeLists value:nil];
}

- (SNMessage *)latestMessageInConversation:(NSString *)conversationID {
    // A decoded history holds no plain replies; reading it does not count as using it.
    SNMessage *latest = self.histories[conversationID].messages.lastObject ?: self.latestMessages[conversationID];
    if (latest) return latest;
    NSDictionary *json = [self.database messagesInConversation:conversationID thread:nil before:nil limit:1].firstObject;
    latest = [json isKindOfClass:NSDictionary.class] ? [SNMessage messageWithJSON:json conversationID:conversationID] : nil;
    if (latest) {
        self.latestMessages[conversationID] = latest;
        return latest;
    }
    if ([self.latestRequested containsObject:conversationID]) return nil;
    [self.latestRequested addObject:conversationID];
    [self request:@"conversations.history" params:@{@"channel" : conversationID, @"limit" : @"1", @"_x_reason" : @"latest-message"}
         priority:SNCallBackground
       completion:^(NSDictionary *response, NSError *error) {
           NSDictionary *newest = SNJSONArray(response, @"messages").firstObject;
           if ([newest isKindOfClass:NSDictionary.class]) [self applyLatestMessages:@{conversationID : newest}];
       }];
    return nil;
}

- (void)applyLatestMessages:(NSDictionary<NSString *, NSDictionary *> *)messages {
    [self performChanges:^{
        [messages enumerateKeysAndObjectsUsingBlock:^(NSString *conversationID, NSDictionary *json, BOOL *stop) {
            SNMessage *message = [json isKindOfClass:NSDictionary.class] ? [SNMessage messageWithJSON:json conversationID:conversationID] : nil;
            if (!message || self.histories[conversationID].messages.count) return;
            self.latestMessages[conversationID] = message;
            [self changed:SNChangeMessages value:conversationID];
        }];
    }];
}

- (SNMessage *)cachedMessageWithTS:(NSString *)ts inConversation:(NSString *)conversationID threadTS:(NSString *)threadTS {
    return [self messageWithTS:ts inConversation:conversationID threadTS:threadTS];
}

- (NSString *)cachedLatestInConversation:(NSString *)conversationID {
    SNHistory *history = self.histories[conversationID];
    if (history) return history.messages.lastObject.ts;
    return SNJSONString([self.database messagesInConversation:conversationID thread:nil before:nil limit:1].firstObject, @"ts");
}

- (NSArray<NSString *> *)cachedConversationIDs {
    NSMutableSet *ids = [NSMutableSet setWithArray:self.histories.allKeys];
    for (NSString *key in [self.database jsonWithKeyPrefix:@"history:"])
        if (![key containsString:@"/"]) [ids addObject:[key substringFromIndex:8]];
    return ids.allObjects;
}

- (NSArray<NSString *> *)recentThreadKeys {
    NSMutableArray *keys = [NSMutableArray new];
    for (NSString *key in self.recent)
        if ([key containsString:@"/"]) [keys addObject:key];
    return keys;
}

- (NSUInteger)decodedCount { return self.histories.count + self.threads.count; }

- (NSArray<SNMessage *> *)messagesInConversation:(NSString *)conversationID {
    SNHistory *history = [self historyOf:conversationID];
    if (!history) return @[];
    // Reading is using: what the UI shows stays decoded.
    [self touch:conversationID];
    return [history.messages copy];
}

- (SNMessage *)messageWithIdentifier:(NSString *)identifier inConversation:(NSString *)conversationID {
    return [self.histories[conversationID] messageWithIdentifier:identifier];
}

- (NSArray<SNMessage *> *)threadInConversation:(NSString *)conversationID ts:(NSString *)threadTS {
    NSString *key = SNThreadKey(conversationID, threadTS);
    SNHistory *thread = [self threadOf:key];
    if (thread) [self touch:key];
    if (thread.messages.count) return [thread.messages copy];
    SNMessage *parent = [self messageWithTS:threadTS inConversation:conversationID];
    return parent ? @[ parent ] : @[];
}

- (BOOL)hasOlderMessagesInConversation:(NSString *)conversationID {
    SNHistory *history = [self historyOf:conversationID];
    return history.olderOnDisk || history.olderOnServer;
}

- (BOOL)hasNewerMessagesInConversation:(NSString *)conversationID { return [self historyOf:conversationID].newerOnServer; }
- (BOOL)isLoadingMessagesInConversation:(NSString *)conversationID { return self.histories[conversationID].loads > 0; }

- (BOOL)hasUnreadThreads { return SNJSONBool(self.threadCounts, @"has_unreads"); }
- (NSInteger)threadMentionCount { return SNJSONInteger(self.threadCounts, @"mention_count"); }
- (NSDictionary<NSString *, id> *)preferences { return self.prefs; }

#pragma mark Decoded memory

static NSString *HistoryFlagsKey(NSString *key) { return [@"history:" stringByAppendingString:key]; }

/// A run read from the database: the newest page, and whether more of it is on disk.
- (SNHistory *)readHistory:(NSString *)conversationID thread:(NSString *)threadTS {
    if (!self.database) return nil;
    NSString *key = threadTS ? SNThreadKey(conversationID, threadTS) : conversationID;
    NSDictionary *flags = [self.database jsonForKey:HistoryFlagsKey(key)];
    // Threads are read whole; histories a page at a time.
    NSInteger limit = threadTS ? 1000 : SNHistoryPage * 2;
    NSArray *rows = [self.database messagesInConversation:conversationID thread:threadTS before:nil limit:limit + 1];
    if (!rows.count && !flags) return nil;
    SNHistory *history = [SNHistory new];
    BOOL more = (NSInteger)rows.count > limit;
    NSMutableArray<SNMessage *> *messages = [NSMutableArray new];
    for (NSDictionary *json in more ? [rows subarrayWithRange:NSMakeRange(1, (NSUInteger)limit)] : rows) {
        SNMessage *message = [json isKindOfClass:NSDictionary.class] ? [SNMessage messageWithJSON:json conversationID:conversationID] : nil;
        if (!message) continue;
        // A send that was in flight when the app last quit never got its answer.
        if (message.sendState == SNMessagePending && ![self.sending containsObject:message.identifier])
            message = [message messageWithSendState:SNMessageFailed];
        [messages addObject:message];
        [self noteUser:message.userID];
    }
    [history setMessages:messages];
    history.olderOnDisk = more;
    history.olderOnServer = SNJSONBool(flags, @"older");
    history.newerOnServer = SNJSONBool(flags, @"newer");
    return history;
}

- (void)saveFlags:(SNHistory *)history key:(NSString *)key {
    [self.database setJSON:@{@"older" : @(history.olderOnServer), @"newer" : @(history.newerOnServer)} forKey:HistoryFlagsKey(key)];
}

- (SNHistory *)historyOf:(NSString *)conversationID {
    SNHistory *history = self.histories[conversationID];
    if (history) return history;
    history = [self readHistory:conversationID thread:nil];
    if (!history) return nil;
    self.histories[conversationID] = history;
    [self touch:conversationID];
    return history;
}

- (SNHistory *)threadOf:(NSString *)threadKey {
    SNHistory *thread = self.threads[threadKey];
    if (thread) return thread;
    NSRange slash = [threadKey rangeOfString:@"/"];
    if (slash.location == NSNotFound) return nil;
    thread = [self readHistory:[threadKey substringToIndex:slash.location] thread:[threadKey substringFromIndex:NSMaxRange(slash)]];
    if (!thread) return nil;
    self.threads[threadKey] = thread;
    [self touch:threadKey];
    return thread;
}

- (void)touch:(NSString *)key {
    [self.recent removeObject:key];
    [self.recent insertObject:key atIndex:0];
    // Without a database an evicted history could not come back without the network.
    if (!self.database) return;
    for (NSInteger i = (NSInteger)self.recent.count - 1; i >= (NSInteger)self.decodedLimit; i--) {
        NSString *old = self.recent[(NSUInteger)i];
        SNHistory *history = self.histories[old] ?: self.threads[old];
        // What is on screen stays, with every page loaded; so does a run loading or waiting
        // for a send's answer, which replaces its pending message in place.
        if ([old isEqualToString:self.shownConversation] || [old isEqualToString:self.shownThread] || history.loads || history.pendingCount) continue;
        [self evict:old];
    }
}

/// Takes a history or thread out of decoded memory; the database keeps it.
- (void)evict:(NSString *)key {
    [self.recent removeObject:key];
    if ([key containsString:@"/"]) {
        [self.threads removeObjectForKey:key];
        return;
    }
    [self.histories removeObjectForKey:key];
    // The run kept the newest message while in memory; it is read from the database again.
    [self.latestMessages removeObjectForKey:key];
    [self trimStored:key];
    [self placeDirectMessage:key];
}

- (void)trimStored:(NSString *)conversationID {
    if (![self.database trimConversation:conversationID keeping:(NSInteger)self.storedMessageLimit]) return;
    NSDictionary *flags = [self.database jsonForKey:HistoryFlagsKey(conversationID)] ?: @{};
    [self.database setJSON:SNJSONMerge(flags, @{@"older" : @YES}) forKey:HistoryFlagsKey(conversationID)];
}

#pragma mark Messages in place

- (void)persist:(SNMessage *)message replacing:(SNMessage *)old thread:(NSString *)threadTS {
    if (old && ![old.ts isEqualToString:message.ts]) [self.database deleteMessageWithTS:old.ts inConversation:message.conversationID thread:threadTS];
    [self.database putMessage:message.json ts:message.ts inConversation:message.conversationID thread:threadTS];
}

// Live events and answers about conversations not in memory go to the database row by row:
// decoding a cached page for each would cost the main thread, and would push what is shown out
// of decoded memory.
- (void)putMessage:(SNMessage *)message {
    NSString *conversationID = message.conversationID;
    if (!conversationID) return;
    [self noteUser:message.userID];
    if (!message.isReply) {
        SNHistory *history = self.histories[conversationID];
        if (history) {
            BOOL beyondRun = history.newerOnServer && history.messages.count && SNCompareTS(message.ts, history.messages.lastObject.ts) == NSOrderedDescending;
            if (!beyondRun) {
                SNMessage *old = [history put:message];
                [self persist:message replacing:old thread:nil];
                if (!old) [self saveFlags:history key:conversationID];
                [self changed:SNChangeMessages value:conversationID];
                [self changed:SNChangeMessageKeys value:SNMessageKey(message)];
                [self placeDirectMessage:conversationID];
            }
        } else if (self.database) [self storeMessage:message];
        else {
            history = [SNHistory new];
            // Nothing held: the conversation's older messages are still on the server.
            history.olderOnServer = YES;
            [history put:message];
            self.histories[conversationID] = history;
            [self touch:conversationID];
            [self changed:SNChangeMessages value:conversationID];
            [self changed:SNChangeMessageKeys value:SNMessageKey(message)];
        }
    }
    if (message.threadTS) {
        NSString *key = SNThreadKey(conversationID, message.threadTS);
        SNHistory *thread = self.threads[key];
        if (thread) {
            SNMessage *old = [thread put:message];
            [self persist:message replacing:old thread:message.threadTS];
        } else {
            // Threads are cached with their parent first; a reply to one never cached starts it
            // from the parent the history holds.
            BOOL cached = [self.database messageWithTS:message.threadTS inConversation:conversationID thread:message.threadTS] != nil;
            if (message.isThreadParent && !cached) return;
            SNMessage *parent = cached ? nil : [self messageWithTS:message.threadTS inConversation:conversationID];
            if (!cached && !parent) return;
            if (self.database) {
                if (parent) [self.database putMessage:parent.json ts:parent.ts inConversation:conversationID thread:message.threadTS];
                [self.database putMessage:message.json ts:message.ts inConversation:conversationID thread:message.threadTS];
            } else {
                thread = [SNHistory new];
                [thread put:parent];
                [thread put:message];
                self.threads[key] = thread;
                [self touch:key];
            }
        }
        [self changed:SNChangeThreads value:key];
        [self changed:SNChangeMessageKeys value:SNMessageKey(message)];
    }
}

/// A message of a conversation not in memory, into the cached run on disk.
- (void)storeMessage:(SNMessage *)message {
    NSString *conversationID = message.conversationID;
    NSDictionary *flags = [self.database jsonForKey:HistoryFlagsKey(conversationID)];
    // The run on disk stops before the newest message: one past it would hide the gap.
    if (SNJSONBool(flags, @"newer")) return;
    // Nothing cached yet: older messages are on the server.
    if (!flags) [self.database setJSON:@{@"older" : @YES, @"newer" : @NO} forKey:HistoryFlagsKey(conversationID)];
    [self.database putMessage:message.json ts:message.ts inConversation:conversationID thread:nil];
    NSInteger writes = self.storedWritesSinceTrim[conversationID].integerValue + 1;
    if (writes >= 50) {
        self.storedWritesSinceTrim[conversationID] = @0;
        [self trimStored:conversationID];
    } else self.storedWritesSinceTrim[conversationID] = @(writes);
    SNMessage *latest = self.latestMessages[conversationID];
    if (latest && SNCompareTS(message.ts, latest.ts) != NSOrderedAscending) self.latestMessages[conversationID] = message;
    [self changed:SNChangeMessages value:conversationID];
    [self changed:SNChangeMessageKeys value:SNMessageKey(message)];
}

- (SNMessage *)messageWithTS:(NSString *)ts inConversation:(NSString *)conversationID {
    return [self messageWithTS:ts inConversation:conversationID threadTS:nil];
}

- (SNMessage *)messageWithTS:(NSString *)ts inConversation:(NSString *)conversationID threadTS:(NSString *)threadTS {
    SNMessage *held = [self.histories[conversationID] messageWithTS:ts] ?: [self.threads[SNThreadKey(conversationID, threadTS ?: ts)] messageWithTS:ts];
    if (held) return held;
    // A reply asked for without its thread (a reaction names only the message): in any thread of
    // the conversation decoded memory holds, a few at most.
    NSString *prefix = [conversationID stringByAppendingString:@"/"];
    for (NSString *key in self.threads)
        if ([key hasPrefix:prefix] && (held = [self.threads[key] messageWithTS:ts])) return held;
    NSDictionary *json = [self.database messageWithTS:ts inConversation:conversationID thread:nil];
    if (!json && threadTS) json = [self.database messageWithTS:ts inConversation:conversationID thread:threadTS];
    return json ? [SNMessage messageWithJSON:json conversationID:conversationID] : nil;
}

- (void)updateMessage:(NSString *)ts inConversation:(NSString *)conversationID transform:(SNMessage * (^)(SNMessage *))transform {
    [self updateMessage:ts inConversation:conversationID threadTS:nil transform:transform];
}

- (void)updateMessage:(NSString *)ts inConversation:(NSString *)conversationID threadTS:(NSString *)threadTS transform:(SNMessage * (^)(SNMessage *))transform {
    SNMessage *found = [self messageWithTS:ts inConversation:conversationID threadTS:threadTS];
    if (!found) return;
    SNMessage *updated = transform(found);
    NSMutableArray<NSString *> *threadTSs = [NSMutableArray arrayWithObject:@""];
    if (found.threadTS) [threadTSs addObject:found.threadTS];
    for (NSString *threadTS in threadTSs) {
        NSString *thread = threadTS.length ? threadTS : nil;
        SNHistory *run = thread ? self.threads[SNThreadKey(conversationID, thread)] : self.histories[conversationID];
        SNMessage *copy = [run messageWithIdentifier:found.identifier] ?: [run messageWithTS:found.ts];
        if (copy) {
            SNMessage *result = copy == found ? updated : transform(copy);
            [run replace:copy with:result];
            if (result) [self.database putMessage:result.json ts:result.ts inConversation:conversationID thread:thread];
            else [self.database deleteMessageWithTS:ts inConversation:conversationID thread:thread];
        } else if ([self.database messageWithTS:ts inConversation:conversationID thread:thread]) {
            if (updated) [self.database putMessage:updated.json ts:ts inConversation:conversationID thread:thread];
            else [self.database deleteMessageWithTS:ts inConversation:conversationID thread:thread];
            // Taken away, the newest is the database's next one, read when next asked for.
            if (!thread && [self.latestMessages[conversationID].ts isEqualToString:ts]) self.latestMessages[conversationID] = updated;
        } else continue;
        [self changed:thread ? SNChangeThreads : SNChangeMessages value:thread ? SNThreadKey(conversationID, thread) : conversationID];
    }
    [self changed:SNChangeMessageKeys value:SNMessageKey(found)];
    [self placeDirectMessage:conversationID];
}

#pragma mark History paging

- (void)request:(NSString *)method params:(NSDictionary *)params priority:(SNCallPriority)priority completion:(SNAPICompletion)completion {
    if (!self.api) {
        if (completion) completion(nil, SNAPIMakeError(SNAPIErrorNetwork, nil));
        return;
    }
    [self.api call:method params:params priority:priority completion:completion];
}

/// conversations.history from `params`, following the cursor for up to `pages` pages; the
/// messages come newest first, with whether Slack has more beyond the last.
- (void)fetchHistory:(NSString *)conversationID params:(NSDictionary *)params pages:(NSInteger)pages priority:(SNCallPriority)priority
          completion:(void (^)(NSArray<NSDictionary *> *messages, BOOL more, NSError *error))completion {
    NSDictionary *query = SNJSONMerge(@{@"limit" : @(SNHistoryPage).stringValue}, SNJSONMerge(params, @{@"channel" : conversationID}));
    [self fetch:@"conversations.history" params:query cursor:nil pages:pages priority:priority into:[NSMutableArray new] completion:completion];
}

/// One page of `method`, then the next through its cursor while Slack has more and `pages`
/// allow, gathering the messages into `all`. On an error, what came so far with the error.
- (void)fetch:(NSString *)method params:(NSDictionary *)params cursor:(NSString *)cursor pages:(NSInteger)pages priority:(SNCallPriority)priority
          into:(NSMutableArray<NSDictionary *> *)all completion:(void (^)(NSArray<NSDictionary *> *messages, BOOL more, NSError *error))completion {
    NSDictionary *query = cursor ? SNJSONMerge(params, @{@"cursor" : cursor}) : params;
    [self request:method params:query priority:priority completion:^(NSDictionary *response, NSError *error) {
        if (!response) return completion(all, YES, error ?: SNAPIMakeError(SNAPIErrorNetwork, nil));
        for (id item in SNJSONArray(response, @"messages"))
            if ([item isKindOfClass:NSDictionary.class]) [all addObject:item];
        BOOL more = SNJSONBool(response, @"has_more");
        NSString *next = SNJSONString(SNJSONObject(response, @"response_metadata"), @"next_cursor");
        if (more && next.length && pages > 1) [self fetch:method params:params cursor:next pages:pages - 1 priority:priority into:all completion:completion];
        else completion(all, more, nil);
    }];
}

- (SNHistory *)ensureHistory:(NSString *)conversationID {
    SNHistory *history = [self historyOf:conversationID];
    if (history) return history;
    history = [SNHistory new];
    self.histories[conversationID] = history;
    [self touch:conversationID];
    return history;
}

- (void)beginLoad:(SNHistory *)history key:(NSString *)key thread:(BOOL)thread {
    history.loads++;
    [self performChanges:^{ [self changed:thread ? SNChangeThreads : SNChangeMessages value:key]; }];
}

- (void)endLoad:(SNHistory *)history key:(NSString *)key thread:(BOOL)thread {
    history.loads--;
    [self changed:thread ? SNChangeThreads : SNChangeMessages value:key];
}

- (void)loadConversation:(NSString *)conversationID {
    self.shownConversation = conversationID;
    SNHistory *history = [self historyOf:conversationID];
    if (history) [self touch:conversationID];
    if (history.fresh || history.loads) return;
    // Opening refetches the newest page whole, so edits and reactions made while away show.
    [self refresh:conversationID priority:SNCallUserFacing since:nil passing:NO];
}

- (void)refreshConversation:(NSString *)conversationID priority:(SNCallPriority)priority {
    // A background refresh of something not in memory goes to the database and leaves memory
    // again, so it does not push what was in use out.
    BOOL passing = !self.histories[conversationID] && priority == SNCallBackground && self.database;
    NSString *since = nil;
    for (SNMessage *message in [self historyOf:conversationID].messages.reverseObjectEnumerator)
        if (message.sendState == SNMessageSent) {
            since = message.ts;
            break;
        }
    [self refresh:conversationID priority:priority since:since passing:passing];
}

/// The newest page, or (with `since`) what came after the cache's newest message, a few pages
/// at most; merged with the cache.
- (void)refresh:(NSString *)conversationID priority:(SNCallPriority)priority since:(NSString *)since passing:(BOOL)passing {
    if (!self.api) return;
    SNHistory *history = [self ensureHistory:conversationID];
    if (history.loads) return;
    [self beginLoad:history key:conversationID thread:NO];
    NSMutableDictionary *params = [@{@"_x_reason" : @"message-pane/requestHistory"} mutableCopy];
    if (since) params[@"oldest"] = since;
    [self fetchHistory:conversationID params:params pages:since ? 3 : 1 priority:priority completion:^(NSArray *messages, BOOL more, NSError *error) {
        [self performChanges:^{
            [self endLoad:history key:conversationID thread:NO];
            if (!error) [self mergeNewest:messages more:more since:since inConversation:conversationID];
            if (passing && self.histories[conversationID] == history && !history.loads && ![conversationID isEqualToString:self.shownConversation])
                [self evict:conversationID];
        }];
    }];
}

- (void)applyNewestHistory:(NSDictionary *)response inConversation:(NSString *)conversationID {
    NSMutableArray *messages = [NSMutableArray new];
    for (id item in SNJSONArray(response, @"messages"))
        if ([item isKindOfClass:NSDictionary.class]) [messages addObject:item];
    [self performChanges:^{ [self mergeNewest:messages more:SNJSONBool(response, @"has_more") since:nil inConversation:conversationID]; }];
}

- (NSArray<SNMessage *> *)decode:(NSArray<NSDictionary *> *)newestFirst conversation:(NSString *)conversationID {
    NSMutableArray<SNMessage *> *messages = [NSMutableArray new];
    for (NSDictionary *json in newestFirst.reverseObjectEnumerator) {
        SNMessage *message = [SNMessage messageWithJSON:json conversationID:conversationID];
        // Replies only show in the channel when broadcast; history lists them in some shapes.
        if (!message || message.isReply) continue;
        [messages addObject:message];
        [self noteUser:message.userID];
    }
    [messages sortUsingComparator:^NSComparisonResult(id a, id b) { return OrderMessages(a, b); }];
    return messages;
}

/// Records what differs between two runs of the same conversation for the notification.
- (void)noteDifferences:(NSArray<SNMessage *> *)before after:(NSArray<SNMessage *> *)after {
    NSMutableDictionary<NSString *, SNMessage *> *old = [NSMutableDictionary new];
    for (SNMessage *message in before) old[message.identifier] = message;
    for (SNMessage *message in after) {
        SNMessage *previous = old[message.identifier];
        if (!previous || ![previous.json isEqualToDictionary:message.json]) [self changed:SNChangeMessageKeys value:SNMessageKey(message)];
        [old removeObjectForKey:message.identifier];
    }
    for (SNMessage *message in old.allValues) [self changed:SNChangeMessageKeys value:SNMessageKey(message)];
}

/// `since`: the page holds what came after that ts (more: not all of it), else the newest messages.
- (void)mergeNewest:(NSArray<NSDictionary *> *)newestFirst more:(BOOL)more since:(NSString *)since inConversation:(NSString *)conversationID {
    SNHistory *history = [self ensureHistory:conversationID];
    NSArray<SNMessage *> *before = [history.messages copy];
    NSArray<SNMessage *> *page = [self decode:newestFirst conversation:conversationID];
    NSMutableSet<NSString *> *pageIDs = [NSMutableSet setWithArray:[page valueForKey:@"identifier"]];
    NSMutableArray<SNMessage *> *sent = [NSMutableArray new], *unsent = [NSMutableArray new];
    for (SNMessage *message in history.messages) {
        if (message.sendState == SNMessageSent) [sent addObject:message];
        else if (![pageIDs containsObject:message.identifier]) [unsent addObject:message];
    }
    NSString *pageOldest = page.firstObject.ts;
    BOOL overlaps = pageOldest && sent.count && SNCompareTS(sent.lastObject.ts, pageOldest) != NSOrderedAscending;
    NSMutableArray<SNMessage *> *kept = [NSMutableArray new];
    if (since && !more) {
        // Everything after the cache's newest message: the two join.
        for (SNMessage *message in sent)
            if (SNCompareTS(message.ts, since) != NSOrderedDescending && (!pageOldest || SNCompareTS(message.ts, pageOldest) == NSOrderedAscending))
                [kept addObject:message];
        if (pageOldest) [self.database deleteMessagesInConversation:conversationID thread:nil from:pageOldest];
    } else if (!more) {
        // The page is the whole conversation.
        [self.database deleteMessagesInConversation:conversationID thread:nil from:nil];
        history.olderOnDisk = history.olderOnServer = NO;
    } else if (overlaps) {
        for (SNMessage *message in sent)
            if (SNCompareTS(message.ts, pageOldest) == NSOrderedAscending) [kept addObject:message];
        [self.database deleteMessagesInConversation:conversationID thread:nil from:pageOldest];
    } else {
        // A gap between the cache and the page: the cache can no longer be trusted to be whole.
        [self.database deleteMessagesInConversation:conversationID thread:nil from:nil];
        history.olderOnDisk = NO;
        history.olderOnServer = YES;
    }
    if (!pageOldest && more && !since) kept = sent;
    [kept addObjectsFromArray:page];
    [kept addObjectsFromArray:unsent];
    for (SNMessage *message in page) [self.database putMessage:message.json ts:message.ts inConversation:conversationID thread:nil];
    for (SNMessage *message in unsent) [self.database putMessage:message.json ts:message.ts inConversation:conversationID thread:nil];
    [history setMessages:kept];
    history.newerOnServer = NO;
    history.fresh = history.fresh || !since;
    [self saveFlags:history key:conversationID];
    [self noteDifferences:before after:history.messages];
    [self changed:SNChangeMessages value:conversationID];
    [self noteRoomsIn:page ofConversation:conversationID];
    [self advanceLatest:page.lastObject inConversation:conversationID];
    [self placeDirectMessage:conversationID];
}

/// Keeps the conversation's latest in step with the newest message seen.
- (void)advanceLatest:(SNMessage *)message inConversation:(NSString *)conversationID {
    SNConversation *conversation = self.conversationsByID[conversationID];
    if (!message || message.sendState != SNMessageSent || !conversation) return;
    if (conversation.latest && SNCompareTS(conversation.latest, message.ts) != NSOrderedAscending) return;
    [self setConversation:[conversation conversationByMergingJSON:@{@"latest" : message.ts}]];
}

- (void)loadOlderMessagesInConversation:(NSString *)conversationID {
    SNHistory *history = [self historyOf:conversationID];
    if (!history || history.loads) return;
    [self touch:conversationID];
    NSString *oldest = nil;
    for (SNMessage *message in history.messages)
        if (message.sendState == SNMessageSent) {
            oldest = message.ts;
            break;
        }
    if (history.olderOnDisk && oldest) {
        NSArray *rows = [self.database messagesInConversation:conversationID thread:nil before:oldest limit:SNHistoryPage + 1];
        BOOL more = (NSInteger)rows.count > SNHistoryPage;
        NSArray *page = [self decode:(more ? [rows subarrayWithRange:NSMakeRange(1, SNHistoryPage)] : rows).reverseObjectEnumerator.allObjects
                        conversation:conversationID];
        [self performChanges:^{
            [history insertOlder:page];
            history.olderOnDisk = more;
            for (SNMessage *message in page) [self changed:SNChangeMessageKeys value:SNMessageKey(message)];
            [self changed:SNChangeMessages value:conversationID];
        }];
        return;
    }
    if (!history.olderOnServer || !oldest) return;
    [self beginLoad:history key:conversationID thread:NO];
    NSDictionary *params = @{@"latest" : oldest, @"_x_reason" : @"message-pane/requestHistory"};
    [self fetchHistory:conversationID params:params pages:1 priority:SNCallUserFacing completion:^(NSArray *messages, BOOL more, NSError *error) {
        [self performChanges:^{
            [self endLoad:history key:conversationID thread:NO];
            if (error) return;
            NSArray<SNMessage *> *page = [self decode:messages conversation:conversationID];
            for (SNMessage *message in page) {
                if ([history messageWithIdentifier:message.identifier] || [history messageWithTS:message.ts]) continue;
                [history put:message];
                [self.database putMessage:message.json ts:message.ts inConversation:conversationID thread:nil];
                [self changed:SNChangeMessageKeys value:SNMessageKey(message)];
            }
            [self noteRoomsIn:page ofConversation:conversationID];
            history.olderOnServer = more;
            [self saveFlags:history key:conversationID];
        }];
    }];
}

- (void)loadNewerMessagesInConversation:(NSString *)conversationID {
    SNHistory *history = [self historyOf:conversationID];
    if (!history.newerOnServer || history.loads) return;
    NSString *newest = history.messages.lastObject.ts;
    [self beginLoad:history key:conversationID thread:NO];
    // Slack pages backwards from the newest end, so reaching forward walks a few pages back.
    NSDictionary *params = newest ? @{@"oldest" : newest, @"_x_reason" : @"message-pane/requestHistory"} : @{};
    [self fetchHistory:conversationID params:params pages:4 priority:SNCallUserFacing completion:^(NSArray *messages, BOOL more, NSError *error) {
        [self performChanges:^{
            [self endLoad:history key:conversationID thread:NO];
            if (error) return;
            if (!more) {
                NSArray<SNMessage *> *page = [self decode:messages conversation:conversationID];
                for (SNMessage *message in page) {
                    [history put:message];
                    [self.database putMessage:message.json ts:message.ts inConversation:conversationID thread:nil];
                    [self changed:SNChangeMessageKeys value:SNMessageKey(message)];
                }
                [self noteRoomsIn:page ofConversation:conversationID];
                [self placeDirectMessage:conversationID];
                history.newerOnServer = NO;
                [self saveFlags:history key:conversationID];
                return;
            }
            [self mergeNewest:messages more:YES since:nil inConversation:conversationID];
        }];
    }];
}

- (void)loadMessagesAround:(NSString *)ts inConversation:(NSString *)conversationID {
    SNHistory *history = [self ensureHistory:conversationID];
    [self touch:conversationID];
    if ([history messageWithTS:ts] || history.loads) return;
    [self beginLoad:history key:conversationID thread:NO];
    NSDictionary *params = @{@"latest" : ts, @"inclusive" : @"true", @"_x_reason" : @"message-pane/requestHistory"};
    [self fetchHistory:conversationID params:params pages:1 priority:SNCallUserFacing completion:^(NSArray *messages, BOOL more, NSError *error) {
        [self performChanges:^{
            [self endLoad:history key:conversationID thread:NO];
            if (error) return;
            NSArray<SNMessage *> *before = [history.messages copy];
            NSArray<SNMessage *> *page = [self decode:messages conversation:conversationID];
            [self.database deleteMessagesInConversation:conversationID thread:nil from:nil];
            for (SNMessage *message in page) [self.database putMessage:message.json ts:message.ts inConversation:conversationID thread:nil];
            [history setMessages:page];
            [self noteRoomsIn:page ofConversation:conversationID];
            [self placeDirectMessage:conversationID];
            history.olderOnDisk = NO;
            history.olderOnServer = more;
            SNConversation *conversation = self.conversationsByID[conversationID];
            history.newerOnServer = !conversation.latest || SNCompareTS(conversation.latest, page.lastObject.ts ?: ts) == NSOrderedDescending;
            history.fresh = YES;
            [self saveFlags:history key:conversationID];
            [self noteDifferences:before after:page];
        }];
    }];
}

#pragma mark Threads

- (void)loadThread:(NSString *)threadTS inConversation:(NSString *)conversationID {
    NSString *key = SNThreadKey(conversationID, threadTS);
    self.shownThread = key;
    SNHistory *thread = [self threadOf:key];
    if (thread) [self touch:key];
    if (thread.fresh || thread.loads) return;
    [self refreshThread:threadTS inConversation:conversationID];
}

- (void)refreshThread:(NSString *)threadTS inConversation:(NSString *)conversationID {
    if (!self.api) return;
    NSString *key = SNThreadKey(conversationID, threadTS);
    SNHistory *thread = [self threadOf:key];
    if (!thread) {
        thread = [SNHistory new];
        self.threads[key] = thread;
        [self touch:key];
    }
    [self beginLoad:thread key:key thread:YES];
    NSDictionary *params = @{@"channel" : conversationID, @"ts" : threadTS, @"limit" : @"200", @"_x_reason" : @"history-api/fetchReplies"};
    [self fetch:@"conversations.replies" params:params cursor:nil pages:5 priority:SNCallUserFacing into:[NSMutableArray new]
        completion:^(NSArray<NSDictionary *> *messages, BOOL more, NSError *error) {
            [self performChanges:^{
                [self endLoad:thread key:key thread:YES];
                if (!error) [self replaceThread:thread key:key threadTS:threadTS conversation:conversationID with:messages];
            }];
        }];
}

- (void)applyReplies:(NSDictionary *)response thread:(NSString *)threadTS inConversation:(NSString *)conversationID {
    NSString *key = SNThreadKey(conversationID, threadTS);
    NSMutableArray *messages = [NSMutableArray new];
    for (id item in SNJSONArray(response, @"messages"))
        if ([item isKindOfClass:NSDictionary.class]) [messages addObject:item];
    [self performChanges:^{
        SNHistory *thread = [self threadOf:key];
        if (!thread) {
            thread = [SNHistory new];
            self.threads[key] = thread;
            [self touch:key];
        }
        [self replaceThread:thread key:key threadTS:threadTS conversation:conversationID with:messages];
    }];
}

- (void)replaceThread:(SNHistory *)thread key:(NSString *)key threadTS:(NSString *)threadTS conversation:(NSString *)conversationID with:(NSArray<NSDictionary *> *)json {
    NSArray<SNMessage *> *before = [thread.messages copy];
    NSMutableArray<SNMessage *> *messages = [NSMutableArray new];
    // Each page of replies may start with the parent again.
    NSMutableSet<NSString *> *seen = [NSMutableSet new];
    for (NSDictionary *item in json) {
        SNMessage *message = [SNMessage messageWithJSON:item conversationID:conversationID];
        if (!message || [seen containsObject:message.ts]) continue;
        [seen addObject:message.ts];
        [messages addObject:message];
        [self noteUser:message.userID];
    }
    NSSet *ids = [NSSet setWithArray:[messages valueForKey:@"identifier"]];
    for (SNMessage *message in before)
        if (message.sendState != SNMessageSent && ![ids containsObject:message.identifier]) [messages addObject:message];
    [thread setMessages:messages];
    [self.database deleteMessagesInConversation:conversationID thread:threadTS from:nil];
    for (SNMessage *message in thread.messages) [self.database putMessage:message.json ts:message.ts inConversation:conversationID thread:threadTS];
    thread.fresh = YES;
    [self saveFlags:thread key:key];
    [self noteDifferences:before after:thread.messages];
    [self changed:SNChangeThreads value:key];
    SNMessage *parent = thread.messages.firstObject;
    if ([parent.ts isEqualToString:threadTS])
        [self updateMessage:threadTS inConversation:conversationID transform:^SNMessage *(SNMessage *message) {
            return [message messageByMergingJSON:@{@"reply_count" : @(parent.replyCount), @"reply_users" : parent.replyUserIDs,
                                                   @"reply_users_count" : @(parent.replyUsersCount), @"latest_reply" : parent.latestReply ?: NSNull.null}];
        }];
}

#pragma mark What sync applies

- (void)applyWorkspace:(NSDictionary *)team {
    SNWorkspace *workspace = [SNWorkspace workspaceWithJSON:team];
    if (!workspace) return;
    [self performChanges:^{
        self->_workspace = workspace;
        [self.database setJSON:workspace.json forKey:@"workspace"];
        [self changed:SNChangeLists value:nil];
        [self applyNameStyle];
    }];
}

- (void)applySelfUserID:(NSString *)userID {
    [self performChanges:^{
        self.meID = userID;
        [self.database setJSON:userID forKey:@"me"];
        [self noteUser:userID];
        [self applyTimeZone];
    }];
}

/// Puts the user in `users` and its handle in the index.
- (void)holdUser:(SNUser *)user {
    NSString *oldHandle = self.users[user.userID].handle;
    if (oldHandle && ![oldHandle isEqualToString:user.handle] && [self.userIDsByHandle[oldHandle] isEqualToString:user.userID])
        [self.userIDsByHandle removeObjectForKey:oldHandle];
    self.users[user.userID] = user;
    if (user.handle.length) {
        self.userIDsByHandle[user.handle] = user.userID;
        [self.missingHandles removeObject:user.handle];
    }
}

- (void)setUser:(SNUser *)user {
    [self holdUser:user];
    [self.missingAsked removeObjectForKey:user.userID];
    [self.database putObject:user.json withID:user.userID inTable:@"users"];
    [self changed:SNChangeUsers value:user.userID];
    [self watchHuddleStateOf:user];
    if ([user.userID isEqualToString:self.meID]) [self applyTimeZone];
}

- (void)applyUsers:(NSArray<NSDictionary *> *)users {
    [self performChanges:^{
        for (NSDictionary *json in users) {
            SNUser *user = [json isKindOfClass:NSDictionary.class] ? [SNUser userWithJSON:json] : nil;
            if (!user) continue;
            SNPresence presence = SNPresenceNamed(SNJSONString(json, @"presence"));
            if (presence != SNPresenceUnknown) [self setPresence:presence ofUser:user.userID];
            SNUser *old = self.users[user.userID] ?: [self loadUserFromDB:user.userID];
            if (old && [old isEqualToUser:user]) continue;
            [self setUser:user];
        }
    }];
}

- (void)setPresence:(SNPresence)presence ofUser:(NSString *)userID {
    if ([self presenceOfUser:userID] == presence) return;
    self.presences[userID] = @(presence);
    [self changed:SNChangePresence value:userID];
}

- (void)applyDoNotDisturb:(NSDictionary<NSString *, NSDictionary *> *)users {
    [self performChanges:^{
        [users enumerateKeysAndObjectsUsingBlock:^(NSString *userID, NSDictionary *status, BOOL *stop) {
            BOOL dnd = SNDoNotDisturbActive(status);
            if (dnd == [self.doNotDisturbIDs containsObject:userID]) return;
            if (dnd) [self.doNotDisturbIDs addObject:userID];
            else [self.doNotDisturbIDs removeObject:userID];
            [self changed:SNChangePresence value:userID];
        }];
    }];
}

BOOL SNDoNotDisturbActive(NSDictionary *status) {
    double now = NSDate.date.timeIntervalSince1970;
    if (SNJSONBool(status, @"snooze_enabled") && SNJSONDouble(status, @"snooze_endtime") > now) return YES;
    if (!SNJSONBool(status, @"dnd_enabled")) return NO;
    double start = SNJSONDouble(status, @"next_dnd_start_ts"), end = SNJSONDouble(status, @"next_dnd_end_ts");
    return start && end && start <= now && now < end;
}

- (void)setConversation:(SNConversation *)conversation {
    SNConversation *old = self.conversationsByID[conversation.conversationID];
    if (old && [old isEqualToConversation:conversation]) return;
    self.conversationsByID[conversation.conversationID] = conversation;
    [self.unavailableConversations removeObject:conversation.conversationID];
    [self.database putObject:conversation.json withID:conversation.conversationID inTable:@"conversations"];
    [self changed:SNChangeConversations value:conversation.conversationID];
    if (!old || old.hasUnreads != conversation.hasUnreads || old.mentionCount != conversation.mentionCount || old.isMuted != conversation.isMuted)
        [self changed:SNChangeCounts value:conversation.conversationID];
    // A section may list a conversation that only now arrived; a name re-sorts its section.
    if (!old || ![old.name isEqualToString:conversation.name]) [self changed:SNChangeLists value:nil];
    [self placeInLists:conversation was:old];
}

- (NSSet<NSString *> *)mutedIDs {
    NSString *muted = SNJSONString(self.prefs, @"muted_channels") ?: @"";
    NSMutableSet *ids = [NSMutableSet setWithArray:[muted componentsSeparatedByString:@","]];
    [ids removeObject:@""];
    return ids;
}

- (void)applyConversations:(NSArray<NSDictionary *> *)conversations {
    NSSet *muted = [self mutedIDs];
    [self performChanges:^{
        for (NSDictionary *json in conversations) {
            SNConversation *conversation = [json isKindOfClass:NSDictionary.class] ? [SNConversation conversationWithJSON:json] : nil;
            if (!conversation) continue;
            SNConversation *old = self.conversationsByID[conversation.conversationID];
            NSMutableDictionary *kept = [NSMutableDictionary new];
            if (old) {
                if (!json[@"last_read"] && old.lastRead) kept[@"last_read"] = old.lastRead;
                if (!json[@"latest"] && old.latest) kept[@"latest"] = old.latest;
                if (!json[@"has_unreads"] && old.hasUnreads) kept[@"has_unreads"] = @YES;
                if (!json[@"mention_count"] && old.mentionCount) kept[@"mention_count"] = @(old.mentionCount);
            }
            if (json[@"last_read"]) [self.readKnown addObject:conversation.conversationID];
            kept[@"sn_muted"] = @([muted containsObject:conversation.conversationID]);
            [self setConversation:[conversation conversationByMergingJSON:kept]];
        }
    }];
}

- (void)applyCounts:(NSDictionary *)counts {
    [self performChanges:^{
        for (NSString *kind in @[ @"channels", @"mpims", @"ims" ])
            for (NSDictionary *entry in SNJSONArray(counts, kind)) {
                NSString *conversationID = SNJSONString(entry, @"id");
                SNConversation *conversation = conversationID ? self.conversationsByID[conversationID] : nil;
                if (!conversation) continue;
                [self setConversation:[conversation conversationWithCounts:entry]];
                if (entry[@"last_read"]) [self.readKnown addObject:conversationID];
            }
        NSDictionary *threads = SNJSONObject(counts, @"threads");
        if (threads) [self setThreadCountsJSON:threads];
    }];
}

- (void)setThreadCountsJSON:(NSDictionary *)threads {
    if ([threads isEqualToDictionary:self.threadCounts]) return;
    self.threadCounts = threads;
    [self.database setJSON:threads forKey:@"threads"];
    [self changed:SNChangeCounts value:nil];
}

- (void)applySections:(NSArray<NSDictionary *> *)sections {
    [self performChanges:^{
        self.sectionJSON = [NSMutableArray new];
        for (id item in sections)
            if ([item isKindOfClass:NSDictionary.class]) [self.sectionJSON addObject:item];
        [self saveSections];
    }];
}

- (void)applyPreferences:(NSDictionary *)prefs {
    [self performChanges:^{
        NSSet *wasMuted = [self mutedIDs];
        self.prefs = SNJSONMerge(self.prefs, prefs);
        [self savePreferences];
        NSSet *muted = [self mutedIDs];
        NSMutableSet *changed = [muted mutableCopy], *both = [muted mutableCopy];
        [changed unionSet:wasMuted];
        [both intersectSet:wasMuted];
        [changed minusSet:both];
        for (NSString *conversationID in changed) {
            SNConversation *conversation = self.conversationsByID[conversationID];
            BOOL isMuted = [muted containsObject:conversationID];
            if (conversation && isMuted != conversation.isMuted) [self setConversation:[conversation conversationWithMuted:isMuted]];
        }
    }];
}

- (void)savePreferences {
    [self.database setJSON:self.prefs forKey:@"prefs"];
    [self changed:SNChangePreferences value:nil];
    [self changed:SNChangeEmoji value:nil];
    [self applyNameStyle];
    [self applyTimeZone];
}

/// set_tz_automatically, on unless Slack says otherwise.
- (BOOL)followsMacTimeZone { return SNPreferenceBool(self.prefs, @"set_tz_automatically", YES); }

/// Times show in one zone, set app-wide so every formatter and calendar follows it: the Mac's
/// while set_tz_automatically is on, else the user's (users.prefs tz, or users.info's tz until the
/// prefs arrive).
- (void)applyTimeZone {
    NSString *name = SNPreferenceString(self.prefs, @"tz") ?: self.me.timeZone;
    NSTimeZone *zone = (self.followsMacTimeZone || !name ? nil : [NSTimeZone timeZoneWithName:name]) ?: self.macTimeZone;
    if ([zone isEqualToTimeZone:NSTimeZone.defaultTimeZone]) return;
    NSTimeZone.defaultTimeZone = zone;
    [self changed:SNChangeTimeZone value:nil];
}

- (void)setMacTimeZone:(NSTimeZone *)macTimeZone {
    _macTimeZone = macTimeZone;
    [self performChanges:^{ [self applyTimeZone]; }];
    [self saveMacTimeZone];
}

/// While set_tz_automatically is on, Slack's tz follows the Mac's, named as Slack's client names
/// it (emails, reminders and other devices read it).
- (void)saveMacTimeZone {
    NSString *tz = SNTimeZoneChoiceForZone(self.macTimeZone);
    if (self.followsMacTimeZone && tz && ![tz isEqualToString:SNPreferenceString(self.prefs, @"tz")]) [self setPreference:@"tz" value:tz];
}

/// display_real_names_override: 1 full names, -1 display names, 0 (or none) the workspace's own
/// display_real_names. A change renames everyone shown.
- (void)applyNameStyle {
    NSInteger override = SNPreferenceString(self.prefs, @"display_real_names_override").integerValue;
    BOOL full = override == 1 || (override == 0 && SNJSONBool(SNJSONObject(self.workspace.json, @"prefs"), @"display_real_names"));
    if (full == SNShowsFullNames()) return;
    SNSetShowsFullNames(full);
    for (NSString *userID in self.users) [self changed:SNChangeUsers value:userID];
}

- (void)applyUsergroups:(NSArray<NSDictionary *> *)usergroups {
    [self performChanges:^{
        [self ensureUsergroupsCacheLoaded];
        BOOL changed = NO;
        for (NSDictionary *group in usergroups) {
            NSString *groupID = SNJSONString(group, @"id"), *handle = SNJSONString(group, @"handle");
            if (!groupID || !handle.length || [self.usergroupHandles[groupID] isEqualToString:handle]) continue;
            self.usergroupHandles[groupID] = handle;
            [self changed:SNChangeUsergroups value:groupID];
            changed = YES;
        }
        if (changed) [self.database setJSON:self.usergroupHandles forKey:@"usergroups"];
    }];
}

/// render/emoji.h owns custom emoji for everything that draws or looks them up.
- (void)setEmojiList:(NSDictionary<NSString *, NSString *> *)emojiList {
    _emojiList = emojiList;
    SNSetCustomEmoji(emojiList);
}

- (void)applyEmoji:(NSDictionary<NSString *, NSString *> *)emoji {
    [self performChanges:^{
        self.emojiList = emoji;
        [self.database setJSON:emoji forKey:@"emoji"];
        [self changed:SNChangeEmoji value:nil];
    }];
}

@end
