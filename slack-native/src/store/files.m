// Owns the files explorer's requests (search.modules.files), a conversation's links
// (conversations.searchLinks) and the Files tab's recently viewed files.
#import "model/json.h"
#import "store/internal.h"

// Implements part of SNSource, which the primary class adopts (see internal.h).
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

static NSString *const kRecentFilesKey = @"recent_files";
/// filesOpenInSessionStore keeps its first 10 for the sidebar.
static const NSUInteger kRecentFiles = 10;

@implementation SNStore (Files)

#pragma mark Explorer

/// How a search token names the conversation (the in: token's formatChannel, formatMpim and
/// formatMember): a channel with its name (sanitizeChannelRefName drops what would end the
/// reference), a group DM by its ID, a DM by the other person.
- (NSString *)searchReferenceOf:(NSString *)conversationID {
    SNConversation *conversation = conversationID ? [self knownConversationWithID:conversationID] : nil;
    if (!conversation) return nil;
    if (conversation.kind == SNConversationDirect && conversation.userID) return [NSString stringWithFormat:@"<@%@>", conversation.userID];
    if (conversation.kind == SNConversationGroupDirect) return [NSString stringWithFormat:@"<#%@>", conversationID];
    NSString *name = [[conversation.name ?: @"" componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"<>|"]] componentsJoinedByString:@""];
    return name.length ? [NSString stringWithFormat:@"<#%@|%@>", conversationID, name] : [NSString stringWithFormat:@"<#%@>", conversationID];
}

// requestSearchModule with getSearchAPIParams for the files module. The filters are words of the
// query, so a page in a channel or of chosen types searches (highlight, extracts) where an empty
// query would browse; last_engaged has no direction.
- (void)searchFiles:(SNFileSearch *)search page:(NSInteger)page completion:(void (^)(NSArray<SNFile *> *, NSInteger, NSString *))completion {
    static NSString *session;
    if (!session) session = NSUUID.UUID.UUIDString.lowercaseString;
    NSString *query = [search requestQueryWithReference:[self searchReferenceOf:search.conversationID]];
    NSMutableDictionary *params = [@{@"module" : @"files", @"query" : query, @"page" : @(MAX(page, 1)).stringValue,
                                     @"client_req_id" : NSUUID.UUID.UUIDString.lowercaseString, @"browse_session_id" : session,
                                     @"no_user_profile" : @"1", @"count" : @(search.count).stringValue, @"file_title_only" : @"false",
                                     @"include_files_shares" : @"1", @"search_context" : search.context, @"max_filter_suggestions" : @"10",
                                     @"search_exclude_bots" : @"false", @"search_only_my_channels" : search.sharedWithYou ? @"true" : @"false",
                                     @"shared_with_you" : search.sharedWithYou ? @"1" : @"0", @"sort" : search.sort,
                                     @"_x_reason" : @"fetch-current-browser"} mutableCopy];
    if (![search.sort isEqualToString:@"last_engaged"]) params[@"sort_dir"] = search.ascending ? @"asc" : @"desc";
    if (self.workspace.workspaceID) params[@"team"] = self.workspace.workspaceID;
    if (query.length) [params addEntriesFromDictionary:@{@"highlight" : @"1", @"extracts" : @"1", @"max_extract_len" : @"200", @"extra_message_data" : @"1"}];
    else [params addEntriesFromDictionary:@{@"highlight" : @"0", @"extracts" : @"0", @"browse" : @"standard"}];
    [self request:@"search.modules.files" params:params priority:SNCallUserFacing completion:^(NSDictionary *response, NSError *error) {
        NSArray *items = SNJSONArray(response, @"items");
        if (!items) return completion(nil, 0, error ? SNAPIErrorName(error) ?: @"" : @"invalid_response");
        NSArray<SNFile *> *files = SNJSONMap(response, @"items", ^id(NSDictionary *item) { return [SNFile fileWithJSON:item]; });
        completion(files, MAX(1, SNJSONInteger(SNJSONObject(response, @"pagination"), @"page_count")), nil);
    }];
}

// fetchChannelLinks: newest first by default, by relevance while searching.
- (void)searchLinksInConversation:(NSString *)conversationID
                            query:(NSString *)query
                      oldestFirst:(BOOL)oldestFirst
                             page:(NSInteger)page
                       completion:(void (^)(NSArray<SNChannelLink *> *, NSInteger, NSString *))completion {
    NSString *sort = query.length && !oldestFirst ? @"relevant" : @"timestamp";
    NSDictionary *params = @{@"channel_id" : conversationID, @"page" : @(MAX(page, 1)).stringValue, @"query" : query, @"sort" : sort,
                             @"sort_dir" : oldestFirst ? @"asc" : @"desc", @"_x_reason" : @"fetch-channel-links"};
    [self request:@"conversations.searchLinks" params:params priority:SNCallUserFacing completion:^(NSDictionary *response, NSError *error) {
        if (!SNJSONArray(response, @"items")) return completion(nil, 0, error ? SNAPIErrorName(error) ?: @"" : @"invalid_response");
        NSArray<SNChannelLink *> *links = SNJSONMap(response, @"items", ^id(NSDictionary *item) { return [SNChannelLink linkWithJSON:item]; });
        completion(links, MAX(1, SNJSONInteger(SNJSONObject(response, @"pagination"), @"page_count")), nil);
    }];
}

#pragma mark Recently viewed

- (NSArray<SNFile *> *)recentFiles {
    if (!self.recentFileList) {
        id saved = [self.database jsonForKey:kRecentFilesKey];
        self.recentFileList = [saved isKindOfClass:NSArray.class] ? SNJSONMap(@{@"files" : saved}, @"files", ^id(NSDictionary *item) {
            return [SNFile fileWithJSON:item];
        })
                                                                 : @[];
    }
    return self.recentFileList;
}

- (void)setRecentFiles:(NSArray<SNFile *> *)files {
    [self performChanges:^{
        self.recentFileList = files;
        [self.database setJSON:[files valueForKey:@"json"] forKey:kRecentFilesKey];
        [self changed:SNChangeRecentFiles value:nil];
    }];
}

- (void)noteFileViewed:(SNFile *)file {
    NSMutableArray<SNFile *> *files = [NSMutableArray arrayWithObject:file];
    for (SNFile *recent in self.recentFiles)
        if (![recent.fileID isEqualToString:file.fileID] && files.count < kRecentFiles) [files addObject:recent];
    [self setRecentFiles:files];
}

- (void)forgetRecentFile:(NSString *)fileID {
    NSArray<SNFile *> *files = [self.recentFiles filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"fileID != %@", fileID]];
    if (files.count != self.recentFiles.count) [self setRecentFiles:files];
}

@end
