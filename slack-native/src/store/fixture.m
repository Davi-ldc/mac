// Owns reading a fixture folder into a store and answering the store's calls from it.
#import "model/json.h"
#import "store/fixture.h"
#import "store/internal.h"

static NSDictionary *Read(NSURL *url) {
    NSData *data = [NSData dataWithContentsOfURL:url];
    id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [json isKindOfClass:NSDictionary.class] ? json : nil;
}

/// Answers for the source it serves, which owns it.
@interface SNFixtureAPI : NSObject <SNAPI>
@property (nonatomic, weak) SNFixtureSource *source;
@end

@interface SNFixtureSource ()
- (NSDictionary *)answer:(NSString *)method params:(NSDictionary *)params;
- (void)record:(NSString *)method params:(NSDictionary *)params;
- (void)sendEventsAfter:(NSString *)method params:(NSDictionary *)params;
@end

@implementation SNFixtureAPI

- (void)call:(NSString *)method params:(NSDictionary<NSString *, NSString *> *)params priority:(SNCallPriority)priority completion:(SNAPICompletion)completion {
    SNFixtureSource *source = self.source;
    [source record:method params:params];
    NSDictionary *response = source.failsRequests ? nil : [source answer:method params:params];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(source.latency * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (completion) completion(response, response ? nil : SNAPIMakeError(SNAPIErrorNetwork, nil));
        if (response) [source sendEventsAfter:method params:params];
    });
}

- (dispatch_block_t)upload:(NSURL *)file name:(NSString *)name mimeType:(NSString *)mimeType to:(NSURL *)url
                  progress:(void (^)(double))progress completion:(void (^)(NSInteger))completion {
    SNFixtureSource *source = self.source;
    [source record:@"upload" params:@{@"name" : name, @"mimeType" : mimeType}];
    __block BOOL cancelled = NO;
    BOOL fails = source.failsRequests;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(source.latency * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!cancelled && !fails && progress) progress(1);
        completion(cancelled || fails ? 0 : 200);
    });
    return ^{ cancelled = YES; };
}

- (void)callEdge:(NSString *)path body:(NSDictionary *)body priority:(SNCallPriority)priority completion:(SNAPICompletion)completion {
    SNFixtureSource *source = self.source;
    [source record:path params:body];
    // A folder says nothing of huddles beyond its messages: every conversation asked is unknown.
    NSDictionary *answer = [path isEqualToString:@"huddles/info"] ? @{@"ok" : @YES, @"huddles" : @[], @"failed_ids" : SNJSONStrings(body, @"channel_ids")} : @{@"ok" : @YES, @"results" : @[]};
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(source.latency * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (completion) completion(answer, nil);
    });
}

@end

@implementation SNFixtureSource {
    NSMutableArray<NSArray *> *_calls;
    SNFixtureAPI *_fixtureAPI;
    SNConnectionState _fixtureConnection;
}

+ (instancetype)sourceWithFolder:(NSURL *)folder {
    SNFixtureSource *source = [[self alloc] initWithDatabase:nil api:nil];
    source->_fixtureAPI = [SNFixtureAPI new];
    source->_fixtureAPI.source = source;
    source.api = source->_fixtureAPI;
    source->_folder = folder;
    source->_calls = [NSMutableArray new];
    source->_fixtureConnection = SNConnectionConnected;
    NSURL * (^file)(NSString *) = ^(NSString *name) { return [folder URLByAppendingPathComponent:name]; };
    NSString *meID = SNJSONString(Read(file(@"auth.test.json")), @"user_id");
    NSDictionary *team = SNJSONObject(Read(file(@"team.info.json")), @"team");
    if (!meID || !team) return nil;
    [source performChanges:^{
        [source applyWorkspace:team];
        [source applySelfUserID:meID];
        [source applyPreferences:SNJSONObject(Read(file(@"users.prefs.get.json")), @"prefs") ?: @{}];
        [source applyUsers:SNJSONArray(Read(file(@"users.list.json")), @"members") ?: @[]];
        [source applyDoNotDisturb:SNJSONObject(Read(file(@"dnd.teamInfo.json")), @"users") ?: @{}];
        [source applyConversations:SNJSONArray(Read(file(@"conversations.list.json")), @"channels") ?: @[]];
        [source applyCounts:Read(file(@"client.counts.json")) ?: @{}];
        [source applySections:SNJSONArray(Read(file(@"users.channelSections.list.json")), @"channel_sections") ?: @[]];
        [source applyEmoji:SNJSONObject(Read(file(@"emoji.list.json")), @"emoji") ?: @{}];
        [source applyUsergroups:SNJSONArray(Read(file(@"usergroups.list.json")), @"usergroups") ?: @[]];
        [source applyVIPUserIDs:SNJSONArray(SNJSONObject(Read(file(@"users.priority.list.json")), @"users"), @"manual_provenance") ?: @[]];
        NSURL *history = file(@"conversations.history");
        for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:history.path error:nil]) {
            NSString *conversationID = name.stringByDeletingPathExtension;
            [source applyNewestHistory:[source historyPage:conversationID params:@{}] inConversation:conversationID];
        }
        NSURL *replies = file(@"conversations.replies");
        for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:replies.path error:nil]) {
            NSArray<NSString *> *parts = [name.stringByDeletingPathExtension componentsSeparatedByString:@"-"];
            if (parts.count != 2) continue;
            [source applyReplies:Read([replies URLByAppendingPathComponent:name]) ?: @{} thread:parts[1] inConversation:parts[0]];
        }
    }];
    return source.hasState ? source : nil;
}

- (NSArray<NSArray *> *)calls { return [_calls copy]; }

// A folder answers every call, as a connected workspace would; tests take the connection down.
// Kept apart from the store's, whose arrival at Connected saves the Mac's time zone to Slack.
- (SNConnectionState)connectionState { return _fixtureConnection; }

- (void)setConnectionState:(SNConnectionState)connectionState {
    if (_fixtureConnection == connectionState) return;
    [self performChanges:^{
        self->_fixtureConnection = connectionState;
        [self changed:SNChangeConnection value:nil];
    }];
}

- (NSURL *)imageFileForURL:(NSURL *)url {
    NSString *name = url.lastPathComponent;
    if (!name.length) return nil;
    NSURL *file = [[self.folder URLByAppendingPathComponent:@"images"] URLByAppendingPathComponent:name];
    return [NSFileManager.defaultManager fileExistsAtPath:file.path] ? file : nil;
}

#pragma mark Answering calls

/// conversations.history over the file: newest first, within latest/oldest, a page of `limit`
/// with the cursor being the offset.
- (NSDictionary *)historyPage:(NSString *)conversationID params:(NSDictionary *)params {
    NSURL *url = [[self.folder URLByAppendingPathComponent:@"conversations.history"] URLByAppendingPathComponent:[conversationID stringByAppendingPathExtension:@"json"]];
    NSArray *all = SNJSONArray(Read(url), @"messages") ?: @[];
    NSString *latest = params[@"latest"], *oldest = params[@"oldest"];
    BOOL inclusive = [params[@"inclusive"] isEqualToString:@"true"];
    NSMutableArray *range = [NSMutableArray new];
    for (NSDictionary *message in all) {
        NSString *ts = SNJSONString(message, @"ts");
        if (!ts) continue;
        NSComparisonResult toLatest = latest ? SNCompareTS(ts, latest) : NSOrderedAscending;
        NSComparisonResult toOldest = oldest ? SNCompareTS(ts, oldest) : NSOrderedDescending;
        if (toLatest == NSOrderedDescending || toOldest == NSOrderedAscending) continue;
        if (!inclusive && (toLatest == NSOrderedSame || toOldest == NSOrderedSame)) continue;
        [range addObject:message];
    }
    NSInteger limit = [params[@"limit"] integerValue] ?: SNHistoryPage;
    NSInteger offset = [params[@"cursor"] integerValue];
    NSInteger end = MIN((NSInteger)range.count, offset + limit);
    NSArray *page = offset < end ? [range subarrayWithRange:NSMakeRange((NSUInteger)offset, (NSUInteger)(end - offset))] : @[];
    BOOL more = end < (NSInteger)range.count;
    return @{@"ok" : @YES, @"messages" : page, @"has_more" : @(more), @"response_metadata" : @{@"next_cursor" : more ? @(end).stringValue : @""}};
}

- (NSDictionary *)answer:(NSString *)method params:(NSDictionary *)params {
    if ([method isEqualToString:@"conversations.history"]) return [self historyPage:params[@"channel"] params:params];
    if ([method isEqualToString:@"conversations.replies"]) {
        NSString *name = [NSString stringWithFormat:@"%@-%@.json", params[@"channel"], params[@"ts"]];
        return Read([[self.folder URLByAppendingPathComponent:@"conversations.replies"] URLByAppendingPathComponent:name]) ?: @{@"ok" : @YES, @"messages" : @[]};
    }
    if ([method isEqualToString:@"chat.postMessage"]) {
        NSMutableDictionary *message = [@{@"type" : @"message", @"user" : self.me.userID, @"text" : params[@"text"] ?: @"",
                                          @"ts" : SNLocalTS(nil), @"client_msg_id" : params[@"client_msg_id"] ?: @""} mutableCopy];
        NSData *blocks = [params[@"blocks"] dataUsingEncoding:NSUTF8StringEncoding];
        if (blocks) message[@"blocks"] = [NSJSONSerialization JSONObjectWithData:blocks options:0 error:nil] ?: @[];
        if (params[@"thread_ts"]) message[@"thread_ts"] = params[@"thread_ts"];
        if (params[@"reply_broadcast"]) message[@"subtype"] = @"thread_broadcast";
        return @{@"ok" : @YES, @"channel" : params[@"channel"] ?: @"", @"ts" : message[@"ts"], @"message" : message};
    }
    if ([method isEqualToString:@"conversations.open"]) {
        NSArray *users = [params[@"users"] componentsSeparatedByString:@","];
        NSString *conversationID = [NSString stringWithFormat:@"%@FIX%lu", users.count > 1 ? @"G" : @"D", (unsigned long)[params[@"users"] hash] % 100000];
        NSDictionary *channel = users.count > 1 ? @{@"id" : conversationID, @"is_mpim" : @YES, @"name" : @"mpdm-fixture"}
                                                : @{@"id" : conversationID, @"is_im" : @YES, @"user" : users.firstObject ?: @""};
        return @{@"ok" : @YES, @"channel" : channel};
    }
    if ([method isEqualToString:@"search.messages"]) return [self search:params[@"query"] ?: @""];
    if ([method isEqualToString:@"search.modules.channels"]) return [self channelPage:params[@"query"] ?: @""];
    if ([method isEqualToString:@"search.modules.files"]) return [self filesPage:params];
    if ([method isEqualToString:@"conversations.searchLinks"]) return [self linksPage:params];
    if ([method isEqualToString:@"users.profile.getSections"] || [method isEqualToString:@"users.profile.getExtras"]) {
        NSURL *file = [[self.folder URLByAppendingPathComponent:method] URLByAppendingPathComponent:[(params[@"user"] ?: @"") stringByAppendingPathExtension:@"json"]];
        return Read(file) ?: @{@"ok" : @YES};
    }
    if ([method isEqualToString:@"bots.info"]) {
        NSURL *bot = [[self.folder URLByAppendingPathComponent:@"bots.info"] URLByAppendingPathComponent:[params[@"bot"] ?: @"" stringByAppendingPathExtension:@"json"]];
        return Read(bot) ?: @{@"ok" : @NO, @"error" : @"bot_not_found"};
    }
    if ([method isEqualToString:@"activity.feed"]) {
        NSString *name = params[@"cursor"] ? [NSString stringWithFormat:@"activity.feed-%@.json", params[@"cursor"]] : @"activity.feed.json";
        NSDictionary *page = Read([self.folder URLByAppendingPathComponent:name]) ?: @{@"ok" : @YES, @"items" : @[]};
        if (![params[@"mode"] isEqualToString:@"chrono_unreads"]) return page;
        NSPredicate *unread = [NSPredicate predicateWithBlock:^BOOL(id item, NSDictionary *bindings) { return SNJSONBool(item, @"is_unread"); }];
        return SNJSONMerge(page, @{@"items" : [SNJSONArray(page, @"items") ?: @[] filteredArrayUsingPredicate:unread]});
    }
    if ([method isEqualToString:@"messages.list"]) return [self listMessages:params[@"message_ids"]];
    if ([method isEqualToString:@"client.appCommands"]) return Read([self.folder URLByAppendingPathComponent:@"client.appCommands.json"]) ?: @{@"ok" : @YES, @"commands" : @[]};
    if ([method isEqualToString:@"files.getUploadURL"]) {
        NSString *fileID = [NSString stringWithFormat:@"F0FIX%05u", arc4random_uniform(100000)];
        return @{@"ok" : @YES, @"file" : fileID, @"upload_url" : [@"https://files.slack.com/upload/v1/fixture-" stringByAppendingString:fileID]};
    }
    return Read([self.folder URLByAppendingPathComponent:[method stringByAppendingPathExtension:@"json"]]) ?: @{@"ok" : @YES};
}

/// The channel browser's list from the fixture's channels: one page of those whose name holds the
/// query, by name.
- (NSDictionary *)channelPage:(NSString *)query {
    NSMutableArray *items = [NSMutableArray new];
    for (SNConversation *channel in [self.conversationsByID.allValues sortedArrayUsingComparator:^NSComparisonResult(SNConversation *a, SNConversation *b) { return [a.name compare:b.name]; }]) {
        if (channel.isDirect || channel.isArchived || (query.length && [channel.name rangeOfString:query options:NSCaseInsensitiveSearch].location == NSNotFound)) continue;
        [items addObject:@{@"id" : channel.conversationID, @"name" : channel.name, @"purpose" : @{@"value" : channel.purpose ?: @""}, @"member_count" : @(channel.memberCount),
                           @"is_member" : @(channel.isMember), @"is_archived" : @NO}];
    }
    return @{@"ok" : @YES, @"items" : items, @"pagination" : @{@"page" : @1, @"page_count" : @1, @"total_count" : @(items.count)}};
}

/// The explorer's type: words a file answers to, as Slack sorts its files into them.
static NSString *FileTypeOf(NSDictionary *file) {
    NSString *type = [SNJSONString(file, @"filetype") lowercaseString] ?: @"", *mime = SNJSONString(file, @"mimetype") ?: @"";
    if ([type isEqualToString:@"quip"] || [type isEqualToString:@"canvas"]) return SNFileTypeCanvases;
    if ([type isEqualToString:@"list"]) return SNFileTypeLists;
    if ([type isEqualToString:@"pdf"]) return SNFileTypePDFs;
    if ([@[ @"xls", @"xlsx", @"csv", @"gsheet" ] containsObject:type]) return SNFileTypeSpreadsheets;
    if ([@[ @"ppt", @"pptx", @"key", @"gpres" ] containsObject:type]) return SNFileTypePresentations;
    if ([@[ @"doc", @"docx", @"gdoc", @"pages" ] containsObject:type]) return SNFileTypeDocuments;
    if ([SNJSONString(file, @"mode") isEqualToString:@"snippet"]) return SNFileTypeSnippets;
    if ([mime hasPrefix:@"image/"]) return SNFileTypeImages;
    if ([mime hasPrefix:@"video/"]) return SNFileTypeVideos;
    if ([mime hasPrefix:@"audio/"]) return SNFileTypeAudio;
    return @"";
}

/// search.modules.files from the files of the fixture's histories (shared in their conversation)
/// and search.modules.files.json's items (in their "channels"), filtered by the query's in:,
/// type:, -type: and creator: words and its other words in the title, newest first.
- (NSDictionary *)filesPage:(NSDictionary *)params {
    NSMutableArray<NSDictionary *> *candidates = [NSMutableArray new];
    NSURL *history = [self.folder URLByAppendingPathComponent:@"conversations.history"];
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:history.path error:nil])
        for (NSDictionary *message in SNJSONArray(Read([history URLByAppendingPathComponent:name]), @"messages"))
            for (NSDictionary *file in SNJSONArray(message, @"files"))
                if ([file isKindOfClass:NSDictionary.class]) [candidates addObject:SNJSONMerge(file, @{@"channels" : @[ name.stringByDeletingPathExtension ]})];
    [candidates addObjectsFromArray:SNJSONArray(Read([self.folder URLByAppendingPathComponent:@"search.modules.files.json"]), @"items") ?: @[]];
    NSMutableArray<NSString *> *types = [NSMutableArray new], *excluded = [NSMutableArray new], *words = [NSMutableArray new];
    NSString *channel, *creator;
    NSRegularExpression *reference = [NSRegularExpression regularExpressionWithPattern:@"<[#@]([A-Z0-9]+)" options:0 error:nil];
    for (NSString *word in [params[@"query"] ?: @"" componentsSeparatedByString:@" "]) {
        NSTextCheckingResult *match = [reference firstMatchInString:word options:0 range:NSMakeRange(0, word.length)];
        NSString *entity = match ? [word substringWithRange:[match rangeAtIndex:1]] : nil;
        if ([word hasPrefix:@"in:"]) channel = entity;
        else if ([word hasPrefix:@"creator:"]) creator = entity;
        else if ([word hasPrefix:@"type:"]) [types addObject:[word substringFromIndex:5]];
        else if ([word hasPrefix:@"-type:"]) [excluded addObject:[word substringFromIndex:6]];
        else if (word.length) [words addObject:word];
    }
    // A DM is named by its person in the query.
    SNConversation *dm = nil;
    for (SNConversation *conversation in self.conversationsByID.allValues)
        if ([conversation.userID isEqualToString:channel]) dm = conversation;
    if (dm) channel = dm.conversationID;
    NSMutableArray *items = [NSMutableArray new];
    for (NSDictionary *file in candidates) {
        NSString *type = FileTypeOf(file), *title = SNJSONString(file, @"title") ?: SNJSONString(file, @"name") ?: @"";
        if (channel && ![SNJSONStrings(file, @"channels") containsObject:channel]) continue;
        if (creator && ![SNJSONString(file, @"user") isEqualToString:creator]) continue;
        BOOL anyType = !types.count || [types containsObject:type] || ([type isEqualToString:SNFileTypeCanvases] && [types containsObject:SNFileTypeDocuments]);
        if (!anyType || [excluded containsObject:type]) continue;
        BOOL matches = YES;
        for (NSString *word in words) matches = matches && [title localizedCaseInsensitiveContainsString:word];
        if (matches) [items addObject:file];
    }
    [items sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [@(SNJSONDouble(b, @"timestamp") ?: SNJSONDouble(b, @"created")) compare:@(SNJSONDouble(a, @"timestamp") ?: SNJSONDouble(a, @"created"))];
    }];
    return [self page:items params:params];
}

/// One page (count, page) of `items` with Slack's pagination block.
- (NSDictionary *)page:(NSArray *)items params:(NSDictionary *)params {
    NSInteger count = MAX(1, [params[@"count"] integerValue] ?: 50), page = MAX(1, [params[@"page"] integerValue]);
    NSInteger pages = MAX(1, ((NSInteger)items.count + count - 1) / count), start = MIN((NSInteger)items.count, (page - 1) * count);
    NSArray *slice = [items subarrayWithRange:NSMakeRange((NSUInteger)start, (NSUInteger)MIN(count, (NSInteger)items.count - start))];
    return @{@"ok" : @YES, @"items" : slice, @"pagination" : @{@"page" : @(page), @"page_count" : @(pages), @"total_count" : @(items.count), @"per_page" : @(count)}};
}

/// conversations.searchLinks from conversations.searchLinks/<conversation ID>.json, newest first
/// unless asked otherwise, its titles and addresses matching the query's words.
- (NSDictionary *)linksPage:(NSDictionary *)params {
    NSURL *file = [[self.folder URLByAppendingPathComponent:@"conversations.searchLinks"] URLByAppendingPathComponent:[params[@"channel_id"] ?: @"" stringByAppendingPathExtension:@"json"]];
    NSMutableArray *items = [NSMutableArray new];
    NSString *query = params[@"query"] ?: @"";
    for (NSDictionary *item in SNJSONArray(Read(file), @"items"))
        if (!query.length || [[NSString stringWithFormat:@"%@ %@", SNJSONString(item, @"title") ?: @"", SNJSONString(item, @"url") ?: @""] localizedCaseInsensitiveContainsString:query])
            [items addObject:item];
    BOOL ascending = [params[@"sort_dir"] isEqualToString:@"asc"];
    [items sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSComparisonResult order = [@(SNJSONDouble(a, @"timestamp")) compare:@(SNJSONDouble(b, @"timestamp"))];
        return ascending ? order : -order;
    }];
    return [self page:items params:@{@"page" : params[@"page"] ?: @"1", @"count" : @"50"}];
}

/// What the websocket would send after a call: file_created once an upload completes, and the
/// message once files.share shared its files.
- (void)sendEventsAfter:(NSString *)method params:(NSDictionary *)params {
    if ([method isEqualToString:@"files.completeUpload"]) {
        NSArray *files = [NSJSONSerialization JSONObjectWithData:[params[@"files"] ?: @"" dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        for (NSDictionary *file in [files isKindOfClass:NSArray.class] ? files : @[])
            [self applyEvent:@{@"type" : @"file_created", @"file_id" : SNJSONString(file, @"id") ?: @"", @"file" : @{@"id" : SNJSONString(file, @"id") ?: @""}}];
        return;
    }
    if (![method isEqualToString:@"files.share"]) return;
    NSString *channel = params[@"channel"], *identifier = params[@"client_msg_id"], *threadTS = params[@"thread_ts"];
    NSArray<SNMessage *> *candidates = threadTS ? [self threadInConversation:channel ts:threadTS] : [self messagesInConversation:channel];
    SNMessage *pending = nil;
    for (SNMessage *message in candidates)
        if ([message.identifier isEqualToString:identifier]) pending = message;
    if (!pending) return;
    NSMutableDictionary *json = [pending.json mutableCopy];
    [json removeObjectsForKeys:@[ @"sn_send_state", @"sn_uploads" ]];
    NSArray<NSString *> *fileIDs = [params[@"files"] componentsSeparatedByString:@","];
    NSMutableArray *files = [NSMutableArray new];
    [SNJSONArray(pending.json, @"files") enumerateObjectsUsingBlock:^(NSDictionary *file, NSUInteger i, BOOL *stop) {
        [files addObject:SNJSONMerge(file, @{@"id" : i < fileIDs.count ? fileIDs[i] : @""})];
    }];
    json[@"files"] = files;
    json[@"ts"] = SNLocalTS(nil);
    json[@"channel"] = channel;
    [self applyEvent:json];
}

/// messages.list's answer from the fixture's histories, threads and messages.list.json (messages
/// found nowhere else, such as old ones the Activity feed points at).
- (NSDictionary *)listMessages:(NSString *)ids {
    NSMutableDictionary *data = [NSMutableDictionary new];
    NSArray *query = [NSJSONSerialization JSONObjectWithData:[ids ?: @"" dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    NSURL *replies = [self.folder URLByAppendingPathComponent:@"conversations.replies"], *listed = [self.folder URLByAppendingPathComponent:@"messages.list.json"];
    for (NSDictionary *wanted in [query isKindOfClass:NSArray.class] ? query : @[]) {
        NSString *conversationID = SNJSONString(wanted, @"channel");
        if (!conversationID) continue;
        NSMutableArray *candidates = [NSMutableArray arrayWithArray:SNJSONArray([self historyPage:conversationID params:@{@"limit" : @"100000"}], @"messages") ?: @[]];
        for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:replies.path error:nil])
            if ([name hasPrefix:[conversationID stringByAppendingString:@"-"]])
                [candidates addObjectsFromArray:SNJSONArray(Read([replies URLByAppendingPathComponent:name]), @"messages") ?: @[]];
        [candidates addObjectsFromArray:SNJSONArray(SNJSONObject(SNJSONObject(Read(listed), @"messages_data"), conversationID), @"messages") ?: @[]];
        NSSet *timestamps = [NSSet setWithArray:SNJSONStrings(wanted, @"timestamps")];
        NSMutableDictionary *found = [NSMutableDictionary new];
        for (NSDictionary *message in candidates)
            if ([timestamps containsObject:SNJSONString(message, @"ts") ?: @""]) found[SNJSONString(message, @"ts")] = message;
        data[conversationID] = @{@"messages" : found.allValues};
    }
    return @{@"ok" : @YES, @"messages_data" : data};
}

/// Messages of the fixture's histories whose text contains the query.
- (NSDictionary *)search:(NSString *)query {
    NSMutableArray *matches = [NSMutableArray new];
    NSURL *history = [self.folder URLByAppendingPathComponent:@"conversations.history"];
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:history.path error:nil]) {
        NSString *conversationID = name.stringByDeletingPathExtension;
        for (NSDictionary *message in SNJSONArray(Read([history URLByAppendingPathComponent:name]), @"messages"))
            if (query.length && [SNJSONString(message, @"text") localizedCaseInsensitiveContainsString:query])
                [matches addObject:SNJSONMerge(message, @{@"channel" : @{@"id" : conversationID}})];
    }
    return @{@"ok" : @YES, @"messages" : @{@"matches" : matches, @"total" : @(matches.count),
                                           @"paging" : @{@"count" : @20, @"total" : @(matches.count), @"page" : @1, @"pages" : @1}}};
}

- (void)record:(NSString *)method params:(NSDictionary *)params { [_calls addObject:@[ method, params ]]; }

@end
