// Owns autocomplete lookups and search.
#import "model/json.h"
#import "store/internal.h"

// Implements part of SNSource, which the primary class adopts (see internal.h).
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

/// Lowercased without accents, for matching what the user types.
static NSString *Fold(NSString *text) {
    return [text stringByFoldingWithOptions:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch locale:nil] ?: @"";
}

/// How well `query` (folded) starts a word of `text`: 0 for the whole start, 1 for a later
/// word, NSNotFound when it does not.
static NSUInteger WordMatch(NSString *text, NSString *query) {
    NSString *folded = Fold(text);
    if ([folded hasPrefix:query]) return 0;
    NSCharacterSet *separators = [NSCharacterSet characterSetWithCharactersInString:@" -_.()"];
    for (NSString *word in [folded componentsSeparatedByCharactersInSet:separators])
        if (word.length && [word hasPrefix:query]) return 1;
    return NSNotFound;
}

@implementation SNStore (Lookup)

- (NSArray<SNUser *> *)usersMatching:(NSString *)query limit:(NSUInteger)limit {
    if (self.usersCachePending) [self finishLoadingCache];
    NSString *folded = Fold([query stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]);
    NSMutableArray<NSArray *> *ranked = [NSMutableArray new];
    for (SNUser *user in self.users.allValues) {
        if (user.deleted) continue;
        NSUInteger best = NSNotFound;
        NSArray<NSString *> *names = @[ user.displayName, user.realName, user.handle ];
        for (NSUInteger i = 0; i < names.count; i++) {
            NSUInteger match = folded.length ? WordMatch(names[i], folded) : 0;
            if (match != NSNotFound) best = MIN(best, match * 3 + i);
        }
        if (best != NSNotFound) [ranked addObject:@[ @(best), user ]];
    }
    [ranked sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) {
        NSComparisonResult order = [a[0] compare:b[0]];
        return order != NSOrderedSame ? order : [[a[1] visibleName] localizedCaseInsensitiveCompare:[b[1] visibleName]];
    }];
    NSMutableArray<SNUser *> *users = [NSMutableArray new];
    for (NSArray *entry in ranked) {
        if (users.count == limit) break;
        [users addObject:entry[1]];
    }
    if (users.count < limit && folded.length >= 2) [self searchUsersRemotely:query];
    return users;
}

- (SNUser *)userWithHandle:(NSString *)handle {
    NSString *userID = self.userIDsByHandle[handle];
    SNUser *user = userID ? self.users[userID] : [self loadUserByHandleFromDB:handle];
    if (!user && handle.length) [self searchUsersRemotely:handle];
    return user;
}

/// Edge users/search for people this device has not met; they arrive as a users change.
- (void)searchUsersRemotely:(NSString *)query {
    if (!self.api || !self.workspace) return;
    NSString *key = Fold(query);
    if ([self.remoteUserQueries containsObject:key]) return;
    [self.remoteUserQueries addObject:key];
    NSDictionary *body = @{@"query" : query, @"count" : @25, @"fuzz" : @1, @"filter" : @"NOT deactivated"};
    [self.api callEdge:@"users/search" body:body priority:SNCallUserFacing completion:^(NSDictionary *response, NSError *error) {
        NSArray *results = SNJSONArray(response, @"results");
        if (results.count) [self applyUsers:results];
    }];
}

- (NSArray<SNConversation *> *)channelsMatching:(NSString *)query limit:(NSUInteger)limit {
    NSString *folded = Fold([[query stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"#"]]);
    NSMutableArray<NSArray *> *ranked = [NSMutableArray new];
    for (SNConversation *conversation in self.conversationsByID.allValues) {
        if (conversation.isDirect || conversation.isArchived) continue;
        NSUInteger match = folded.length ? WordMatch(conversation.name, folded) : 0;
        if (match == NSNotFound) continue;
        [ranked addObject:@[ @((conversation.isMember ? 0 : 2) + match), conversation ]];
    }
    [ranked sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) {
        NSComparisonResult order = [a[0] compare:b[0]];
        if (order != NSOrderedSame) return order;
        NSString *nameA = [a[1] name], *nameB = [b[1] name];
        return nameA.length != nameB.length ? (nameA.length < nameB.length ? NSOrderedAscending : NSOrderedDescending) : [nameA compare:nameB];
    }];
    NSMutableArray<SNConversation *> *channels = [NSMutableArray new];
    for (NSArray *entry in ranked) {
        if (channels.count == limit) break;
        [channels addObject:entry[1]];
    }
    return channels;
}

#pragma mark Search

- (void)searchMessages:(NSString *)query page:(NSInteger)page completion:(void (^)(SNSearchResult *, NSError *))completion {
    NSDictionary *params = @{@"query" : query, @"page" : @(MAX(page, 1)).stringValue, @"count" : @"20", @"highlight" : @"true",
                             @"sort" : @"score", @"sort_dir" : @"desc", @"_x_reason" : @"search-messages"};
    [self request:@"search.messages" params:params priority:SNCallUserFacing completion:^(NSDictionary *response, NSError *error) {
        SNSearchResult *result = response ? [SNSearchResult resultWithJSON:response query:query] : nil;
        completion(result, result ? nil : error ?: SNAPIMakeError(SNAPIErrorSlack, @"invalid_response"));
    }];
}

#pragma mark Channel browser

// getSearchAPIParams for the Channels page: 50 a page; without a query, Slack's browse list of
// channels not archived; with one, highlighted matches. The channel's own fields come from what
// the store knows of it, the list's (name, purpose, members, membership) win.
- (void)browseChannels:(NSString *)query sort:(NSString *)sort ascending:(BOOL)ascending page:(NSInteger)page
            completion:(void (^)(NSArray<SNConversation *> *, NSInteger, NSString *))completion {
    static NSString *session;
    if (!session) session = NSUUID.UUID.UUIDString.lowercaseString;
    NSMutableDictionary *params = [@{@"module" : @"channels", @"query" : query, @"page" : @(MAX(page, 1)).stringValue, @"client_req_id" : NSUUID.UUID.UUIDString.lowercaseString,
                                     @"browse_session_id" : session, @"no_user_profile" : @"1", @"include_files_shares" : @"1", @"file_title_only" : @"false",
                                     @"search_context" : @"desktop_channel_browser", @"max_filter_suggestions" : @"10", @"count" : @"50", @"extra_message_data" : @"0",
                                     @"exclude_my_channels" : @"0", @"search_only_my_channels" : @"false", @"channel_type" : @"exclude_archived",
                                     @"_x_reason" : @"fetch-current-browser"} mutableCopy];
    if (self.workspace.workspaceID) params[@"team"] = self.workspace.workspaceID;
    if (query.length) [params addEntriesFromDictionary:@{@"highlight" : @"1", @"extracts" : @"1", @"max_extract_len" : @"200"}];
    else [params addEntriesFromDictionary:@{@"highlight" : @"0", @"extracts" : @"0", @"browse" : @"standard"}];
    params[@"sort"] = sort;
    if ([sort isEqualToString:@"recommended"]) params[@"recommend_source"] = @"channel-browser";
    else params[@"sort_dir"] = ascending ? @"asc" : @"desc";
    [self request:@"search.modules.channels" params:params priority:SNCallUserFacing completion:^(NSDictionary *response, NSError *error) {
        NSArray *items = SNJSONArray(response, @"items");
        if (!items) return completion(nil, 0, error ? SNAPIErrorName(error) ?: @"" : @"invalid_response");
        NSMutableArray<SNConversation *> *channels = [NSMutableArray new];
        for (NSDictionary *item in items) {
            if (![item isKindOfClass:NSDictionary.class] || !SNJSONString(item, @"id")) continue;
            NSMutableDictionary *json = [[self knownConversationWithID:item[@"id"]].json mutableCopy] ?: [NSMutableDictionary new];
            [json addEntriesFromDictionary:item];
            if (item[@"member_count"]) json[@"num_members"] = item[@"member_count"];
            SNConversation *channel = [SNConversation conversationWithJSON:json];
            if (channel) [channels addObject:channel];
        }
        NSInteger pages = SNJSONInteger(SNJSONObject(response, @"pagination"), @"page_count");
        completion(channels, MAX(pages, 1), nil);
    }];
}

- (void)joinChannelFromBrowser:(NSString *)conversationID completion:(SNSourceCompletion)completion {
    NSDictionary *params = @{@"channel" : conversationID, @"request_in_background" : @"true", @"_x_reason" : @"browse-channels-page"};
    [self request:@"conversations.join" params:params priority:SNCallUserFacing completion:^(NSDictionary *response, NSError *error) {
        NSDictionary *channel = SNJSONObject(response, @"channel");
        if (channel) [self applyConversations:@[ SNJSONMerge(channel, @{@"is_member" : @YES}) ]];
        if (completion) completion(error ? SNAPIErrorName(error) ?: @"" : nil);
    }];
}

@end
