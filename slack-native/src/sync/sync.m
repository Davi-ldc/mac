// Owns the boot sequence, counts and gap fill, prefetch, users to fetch and presence targets.
#import "model/json.h"
#import "sync/sync.h"

@interface SNSync () <SNChangeObserver>
@end

@implementation SNSync {
    id<SNAPI> _api;
    NSMutableSet<NSString *> *_usersWanted;
    BOOL _usersScheduled, _countsScheduled;
    NSSet<NSString *> *_presence;
    /// The counts' latest each conversation was last fetched for: a latest the cache never
    /// reaches (a reply, a hidden or deleted message) is fetched once, not on every counts call.
    NSMutableDictionary<NSString *, NSString *> *_fetchedLatest;
}

- (instancetype)initWithStore:(SNStore *)store api:(id<SNAPI>)api {
    if (!(self = [super init])) return nil;
    _store = store;
    _api = api;
    _prefetchLimit = 12;
    _usersWanted = [NSMutableSet new];
    _fetchedLatest = [NSMutableDictionary new];
    __weak SNSync *weakSelf = self;
    store.usersMissing = ^(NSSet<NSString *> *userIDs) { [weakSelf fetchUsers:userIDs]; };
    store.countsNeeded = ^{ [weakSelf refreshCounts]; };
    [store addChangeObserver:self];
    return self;
}

#pragma mark Boot

- (void)bootWithCompletion:(void (^)(BOOL))completion {
    NSString *since = [self.store.database jsonForKey:@"boot_ms"];
    NSMutableDictionary *params = [@{@"version_all_channels" : @"false", @"omit_channels" : @"false", @"_x_reason" : @"initial-data"} mutableCopy];
    if ([since isKindOfClass:NSString.class] && self.store.hasState) {
        params[@"min_channel_updated"] = since;
        params[@"_x_reason"] = @"deferred-data";
    }
    NSString *started = @((long long)(NSDate.date.timeIntervalSince1970 * 1000)).stringValue;
    [_api call:@"client.userBoot" params:params priority:SNCallUserFacing completion:^(NSDictionary *response, NSError *error) {
        if (response) {
            [self applyBoot:response];
            [self.store.database setJSON:started forKey:@"boot_ms"];
        }
        BOOL ok = response && self.store.hasState;
        if (completion) completion(ok);
        if (ok) [self loadTheRest];
    }];
}

- (void)applyBoot:(NSDictionary *)boot {
    SNStore *store = self.store;
    [store performChanges:^{
        NSDictionary *team = SNJSONObject(boot, @"team");
        if (team) [store applyWorkspace:team];
        NSDictionary *me = SNJSONObject(boot, @"self");
        NSString *meID = SNJSONString(me, @"id");
        if (meID) [store applySelfUserID:meID];
        // self may come without a profile; the user is known by handle until the edge API answers.
        if (meID && (SNJSONObject(me, @"profile") || ![store knownUserWithID:meID])) [store applyUsers:@[ SNJSONMerge(me, @{@"prefs" : NSNull.null}) ]];
        NSDictionary *prefs = SNJSONObject(me, @"prefs");
        if (prefs) [store applyPreferences:prefs];
        NSMutableArray *conversations = [NSMutableArray new];
        // userBoot lists the user's own channels, which may leave is_member out.
        for (NSString *key in @[ @"channels", @"groups", @"ims", @"mpims" ])
            for (id item in SNJSONArray(boot, key))
                if ([item isKindOfClass:NSDictionary.class]) [conversations addObject:item[@"is_member"] ? item : SNJSONMerge(item, @{@"is_member" : @YES})];
        [store applyConversations:conversations];
        NSDictionary *dnd = SNJSONObject(boot, @"dnd");
        if (dnd && meID) [store applyDoNotDisturb:@{meID : dnd}];
    }];
}

/// What boot leaves to separate calls, in the order the sidebar needs them.
- (void)loadTheRest {
    SNStore *store = self.store;
    [self refreshCountsNow];
    [_api call:@"users.channelSections.list" params:@{@"_x_reason" : @"initial-data"} priority:SNCallUserFacing completion:^(NSDictionary *response, NSError *error) {
        NSArray *sections = SNJSONArray(response, @"channel_sections");
        if (sections) [store applySections:sections];
    }];
    [_api call:@"users.prefs.get" params:@{@"_x_reason" : @"initial-data"} priority:SNCallUserFacing completion:^(NSDictionary *response, NSError *error) {
        NSDictionary *prefs = SNJSONObject(response, @"prefs");
        if (prefs) [store applyPreferences:prefs];
    }];
    // The web client asks for the VIPs on boot where the plan offers them.
    if (store.offersVIPs)
        [_api call:@"users.priority.list" params:@{@"_x_reason" : @"fetch-priority-users-on-boot-render"} priority:SNCallBackground
            completion:^(NSDictionary *response, NSError *error) {
                NSArray *vips = SNJSONArray(SNJSONObject(response, @"users"), @"manual_provenance");
                if (vips) [store applyVIPUserIDs:vips];
            }];
    [_api call:@"client.dms" params:@{@"count" : @"250", @"include_channel" : @"true", @"_x_reason" : @"dms-tab-populate"} priority:SNCallUserFacing completion:^(NSDictionary *response, NSError *error) {
        [self applyDMs:response];
    }];
    [_api call:@"emoji.list" params:@{@"_x_reason" : @"initial-data"} priority:SNCallBackground completion:^(NSDictionary *response, NSError *error) {
        NSDictionary *emoji = SNJSONObject(response, @"emoji");
        if (emoji) [store applyEmoji:emoji];
    }];
    // Disabled groups too: old messages still mention them.
    [_api call:@"usergroups.list" params:@{@"include_disabled" : @"true", @"_x_reason" : @"initial-data"} priority:SNCallBackground
        completion:^(NSDictionary *response, NSError *error) {
            NSArray *usergroups = SNJSONArray(response, @"usergroups");
            if (usergroups) [store applyUsergroups:usergroups];
        }];
    NSMutableSet *people = [NSMutableSet setWithArray:self.presenceUserIDs];
    [self fetchUsers:people];
    // The user is known from boot by handle only.
    if (store.me) [self want:[NSSet setWithObject:store.me.userID] force:YES];
    if (people.count)
        [_api call:@"dnd.teamInfo" params:@{@"users" : [people.allObjects componentsJoinedByString:@","]} priority:SNCallBackground
            completion:^(NSDictionary *response, NSError *error) {
                NSDictionary *users = SNJSONObject(response, @"users");
                if (users) [store applyDoNotDisturb:users];
            }];
}

/// client.dms lists DMs as {id, latest, message, channel} under ims, mpims and dms (Slack's DMs
/// tab). Only include_channel brings the channel object, the one part that says whose DM it is
/// (user, or the mpdm name): an entry without it gives its newest message and no conversation,
/// as the DMs tab does.
- (void)applyDMs:(NSDictionary *)response {
    NSMutableArray *conversations = [NSMutableArray new];
    NSMutableDictionary<NSString *, NSDictionary *> *latest = [NSMutableDictionary new];
    for (NSString *key in @[ @"ims", @"mpims", @"dms" ])
        for (id item in SNJSONArray(response, key)) {
            NSString *conversationID = SNJSONString(item, @"id");
            NSDictionary *message = SNJSONObject(item, @"message");
            if (conversationID && SNJSONString(message, @"ts")) latest[conversationID] = message;
            NSDictionary *channel = SNJSONObject(item, @"channel");
            if (!SNJSONString(channel, @"id")) continue;
            NSMutableDictionary *json = [channel mutableCopy];
            if (!json[@"is_open"]) json[@"is_open"] = @YES;
            if ([key isEqualToString:@"ims"]) json[@"is_im"] = @YES;
            if ([key isEqualToString:@"mpims"]) json[@"is_mpim"] = @YES;
            NSString *newest = SNJSONString(message, @"ts") ?: SNJSONString(item, @"latest");
            if (newest) json[@"latest"] = newest;
            [conversations addObject:json];
        }
    if (conversations.count) [self.store applyConversations:conversations];
    if (latest.count) [self.store applyLatestMessages:latest];
    [self fetchUsers:[NSSet setWithArray:self.presenceUserIDs]];
}

#pragma mark Counts and gap fill

- (void)refreshCounts {
    if (_countsScheduled) return;
    _countsScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        self->_countsScheduled = NO;
        [self refreshCountsNow];
    });
}

- (void)refreshCountsNow {
    NSDictionary *params = @{@"thread_counts_by_channel" : @"true", @"org_wide_aware" : @"true", @"include_file_channels" : @"true",
                             @"_x_reason" : @"client-counts-api/fetchClientCounts"};
    [_api call:@"client.counts" params:params priority:SNCallUserFacing completion:^(NSDictionary *response, NSError *error) {
        if (!response) return;
        [self.store applyCounts:response];
        [self fillGaps];
        [self prefetch];
    }];
}

/// Whether the conversation's newest message (by the counts) is past what the cache holds and
/// was not fetched for already.
- (BOOL)hasMoved:(NSString *)conversationID {
    NSString *latest = [self.store knownConversationWithID:conversationID].latest;
    if (!latest || [_fetchedLatest[conversationID] isEqualToString:latest]) return NO;
    NSString *cached = [self.store cachedLatestInConversation:conversationID];
    return !cached || SNCompareTS(latest, cached) == NSOrderedDescending;
}

- (void)refresh:(NSString *)conversationID priority:(SNCallPriority)priority {
    _fetchedLatest[conversationID] = [self.store knownConversationWithID:conversationID].latest;
    [self.store refreshConversation:conversationID priority:priority];
}

- (void)fillGaps {
    for (NSString *conversationID in self.store.cachedConversationIDs) {
        // Decoded means shown or just used: those come back first.
        if ([self hasMoved:conversationID]) [self refresh:conversationID priority:[self.store isDecoded:conversationID] ? SNCallUserFacing : SNCallBackground];
    }
}

- (void)connectedWithFastReconnect:(BOOL)fastReconnect {
    if (fastReconnect) return;
    [self refreshCountsNow];
    [self.store forgetHuddleAnswers];
    for (NSString *key in self.store.recentThreadKeys) {
        NSRange slash = [key rangeOfString:@"/"];
        [self.store refreshThread:[key substringFromIndex:NSMaxRange(slash)] inConversation:[key substringToIndex:slash.location]];
    }
}

#pragma mark Prefetch

- (NSArray<NSString *> *)prefetchOrder {
    NSMutableArray<SNConversation *> *dms = [NSMutableArray new], *groups = [NSMutableArray new], *mentions = [NSMutableArray new], *unread = [NSMutableArray new];
    NSMutableSet *seen = [NSMutableSet new];
    NSMutableArray<SNConversation *> *candidates = [self.store.directMessages mutableCopy];
    for (SNSection *section in self.store.sections)
        for (NSString *conversationID in section.conversationIDs) {
            SNConversation *conversation = [self.store knownConversationWithID:conversationID];
            if (conversation) [candidates addObject:conversation];
        }
    for (SNConversation *conversation in candidates) {
        if ([seen containsObject:conversation.conversationID] || !conversation.hasUnreads || conversation.isArchived) continue;
        [seen addObject:conversation.conversationID];
        if (conversation.kind == SNConversationDirect) [dms addObject:conversation];
        else if (conversation.kind == SNConversationGroupDirect) [groups addObject:conversation];
        else if (conversation.mentionCount > 0) [mentions addObject:conversation];
        else if (!conversation.isMuted && conversation.isMember) [unread addObject:conversation];
    }
    NSComparator newest = ^NSComparisonResult(SNConversation *a, SNConversation *b) { return SNCompareTS(b.latest ?: @"0", a.latest ?: @"0"); };
    NSMutableArray *order = [NSMutableArray new];
    for (NSMutableArray *group in @[ dms, groups, mentions, unread ]) {
        [group sortUsingComparator:newest];
        [order addObjectsFromArray:[group valueForKey:@"conversationID"]];
    }
    return order;
}

- (void)prefetch {
    NSUInteger fetched = 0;
    for (NSString *conversationID in self.prefetchOrder) {
        if (fetched == self.prefetchLimit) break;
        if (![self hasMoved:conversationID]) continue;
        [self refresh:conversationID priority:SNCallBackground];
        fetched++;
    }
}

#pragma mark Users and presence

- (void)fetchUsers:(NSSet<NSString *> *)userIDs { [self want:userIDs force:NO]; }

- (void)want:(NSSet<NSString *> *)userIDs force:(BOOL)force {
    for (NSString *userID in userIDs)
        if (force || ![self.store knownUserWithID:userID]) [_usersWanted addObject:userID];
    if (!_usersWanted.count || _usersScheduled) return;
    _usersScheduled = YES;
    // Gathered for a moment: a page of history names its authors one by one.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        self->_usersScheduled = NO;
        NSArray *wanted = self->_usersWanted.allObjects;
        [self->_usersWanted removeAllObjects];
        for (NSUInteger start = 0; start < wanted.count; start += 100) {
            NSArray *batch = [wanted subarrayWithRange:NSMakeRange(start, MIN(100, wanted.count - start))];
            [self fetchBatch:batch];
        }
    });
}

- (void)fetchBatch:(NSArray<NSString *> *)userIDs {
    NSMutableDictionary *updated = [NSMutableDictionary new];
    for (NSString *userID in userIDs) updated[userID] = @0;
    NSDictionary *body = @{@"check_interaction" : @YES, @"include_profile_only_users" : @YES, @"updated_ids" : updated};
    [_api callEdge:@"users/info" body:body priority:SNCallUserFacing completion:^(NSDictionary *response, NSError *error) {
        NSArray *users = SNJSONArray(response, @"results");
        if (users.count) [self.store applyUsers:users];
        // Users it does not return wait for the store's next ask. Only without the edge API at
        // all, one documented call per user.
        if (error.code != SNAPIErrorDisabled || ![error.domain isEqualToString:SNAPIErrorDomain]) return;
        for (NSString *userID in userIDs)
            [self->_api call:@"users.info" params:@{@"user" : userID} priority:SNCallBackground completion:^(NSDictionary *info, NSError *infoError) {
                NSDictionary *user = SNJSONObject(info, @"user");
                if (user) [self.store applyUsers:@[ user ]];
            }];
    }];
}

- (NSArray<NSString *> *)presenceUserIDs {
    NSMutableOrderedSet *ids = [NSMutableOrderedSet new];
    if (self.store.me) [ids addObject:self.store.me.userID];
    for (SNConversation *conversation in self.store.directMessages) {
        if (ids.count >= 500) break;
        if (conversation.userID) [ids addObject:conversation.userID];
    }
    return ids.array;
}

- (void)sourceChanged:(SNChange *)change {
    if (!change.lists || !self.presenceChanged) return;
    NSArray *ids = self.presenceUserIDs;
    // The DM list reorders on every message; only who is in it matters.
    NSSet *people = [NSSet setWithArray:ids];
    if ([people isEqualToSet:_presence]) return;
    BOOL first = _presence == nil;
    _presence = people;
    if (!first) self.presenceChanged(ids);
}

@end
