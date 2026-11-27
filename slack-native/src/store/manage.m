// Owns the requests that change a conversation itself, as Slack's client sends them from its slash
// commands and dialogs: leave, join, topic, invite, remove, rename and archive.
#import "model/json.h"
#import "store/internal.h"

// Implements part of SNSource, which the primary class adopts (see internal.h).
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

/// What a completion is told: nil when Slack did it, its error, or "" without an answer.
static NSString *Outcome(NSError *error) { return error ? SNAPIErrorName(error) ?: @"" : nil; }

@implementation SNStore (Manage)

- (void)call:(NSString *)method params:(NSDictionary *)params completion:(SNSourceCompletion)completion {
    [self request:method params:params priority:SNCallUserFacing completion:^(NSDictionary *response, NSError *error) {
        if (completion) completion(Outcome(error));
    }];
}

// leaveConversationApi: the channel leaves the sidebar before Slack answers and comes back when it
// refuses, unless something else (a channel_left event) took it away meanwhile.
- (void)leaveConversation:(NSString *)conversationID completion:(SNSourceCompletion)completion {
    SNConversation *conversation = self.conversationsByID[conversationID];
    if (conversation.isMember) [self performChanges:^{ [self setConversation:[conversation conversationByMergingJSON:@{@"is_member" : @NO}]]; }];
    [self request:@"conversations.leave" params:@{@"channel" : conversationID} priority:SNCallUserFacing completion:^(NSDictionary *response, NSError *error) {
        SNConversation *now = self.conversationsByID[conversationID];
        if (error && conversation.isMember && now && !now.isMember)
            [self performChanges:^{ [self setConversation:[now conversationByMergingJSON:@{@"is_member" : @YES}]]; }];
        if (completion) completion(Outcome(error));
    }];
}

- (void)joinConversation:(NSString *)conversationID completion:(SNSourceCompletion)completion {
    [self request:@"conversations.join" params:@{@"channel" : conversationID} priority:SNCallUserFacing completion:^(NSDictionary *response, NSError *error) {
        NSDictionary *channel = SNJSONObject(response, @"channel");
        if (channel) [self applyConversations:@[ SNJSONMerge(channel, @{@"is_member" : @YES}) ]];
        if (completion) completion(Outcome(error));
    }];
}

- (void)setTopic:(NSString *)topic ofConversation:(NSString *)conversationID completion:(SNSourceCompletion)completion {
    [self call:@"conversations.setTopic" params:@{@"channel" : conversationID, @"topic" : topic, @"_x_reason" : @"submitChannelTopic"} completion:completion];
}

// A user group goes as subteams with force, which invites its members who are not in yet.
- (void)inviteUsers:(NSArray<NSString *> *)userIDs usergroups:(NSArray<NSString *> *)groupIDs toConversation:(NSString *)conversationID
         completion:(SNSourceCompletion)completion {
    NSDictionary *params = @{@"channel" : conversationID, @"users" : [userIDs componentsJoinedByString:@","], @"invite_all" : @"false",
                             @"subteams" : [groupIDs componentsJoinedByString:@","], @"force" : groupIDs.count ? @"true" : @"false",
                             @"_x_reason" : @"submit-invite-slash-command"};
    [self call:@"conversations.invite" params:params completion:completion];
}

- (void)removeUser:(NSString *)userID fromConversation:(NSString *)conversationID completion:(SNSourceCompletion)completion {
    [self call:@"conversations.kick" params:@{@"channel" : conversationID, @"user" : userID, @"_x_reason" : @"submitKickFromChannel"} completion:completion];
}

- (void)renameConversation:(NSString *)conversationID to:(NSString *)name completion:(SNSourceCompletion)completion {
    [self request:@"conversations.rename" params:@{@"channel" : conversationID, @"name" : name, @"validate" : @"true"} priority:SNCallUserFacing
       completion:^(NSDictionary *response, NSError *error) {
           NSDictionary *channel = SNJSONObject(response, @"channel");
           SNConversation *now = self.conversationsByID[conversationID];
           NSString *renamed = SNJSONString(channel, @"name");
           if (now && renamed) [self performChanges:^{ [self setConversation:[now conversationByMergingJSON:@{@"name" : renamed}]]; }];
           if (completion) completion(Outcome(error));
       }];
}

- (void)archiveConversation:(NSString *)conversationID completion:(SNSourceCompletion)completion {
    [self request:@"conversations.archive" params:@{@"channel" : conversationID} priority:SNCallUserFacing completion:^(NSDictionary *response, NSError *error) {
        SNConversation *now = self.conversationsByID[conversationID];
        if (!error && now) [self performChanges:^{ [self setConversation:[now conversationByMergingJSON:@{@"is_archived" : @YES}]]; }];
        if (completion) completion(Outcome(error));
    }];
}

// addUsersAndGroupsToChannel: everyone at once with force; with force Slack answers ok and lists
// the people it refused under "errors". The ones already in count as added, as in Slack.
- (void)addUsers:(NSArray<NSString *> *)userIDs toChannel:(NSString *)channelID completion:(void (^)(NSDictionary<NSString *, NSString *> *, NSString *))completion {
    NSDictionary *params = @{@"channel" : channelID, @"users" : [userIDs componentsJoinedByString:@","], @"subteams" : @"", @"invite_all" : @"false", @"force" : @"true",
                             @"_x_reason" : @"submit-invite-channel-invite-modal"};
    [self request:@"conversations.invite" params:params priority:SNCallUserFacing completion:^(NSDictionary *response, NSError *error) {
        NSMutableDictionary<NSString *, NSString *> *refused = [NSMutableDictionary new];
        NSSet *fine = [NSSet setWithArray:@[ @"already_in_channel", @"cant_invite_self", @"already_in_channel_ug" ]];
        for (NSDictionary *entry in SNJSONArray(response, @"errors") ?: @[]) {
            NSString *user = SNJSONString(entry, @"user"), *name = SNJSONString(entry, @"error");
            if (user && name && ![fine containsObject:name]) refused[user] = name;
        }
        NSString *name = Outcome(error);
        if (name && [fine containsObject:name]) name = nil;
        if (name)
            for (NSString *user in userIDs) refused[user] = name;
        if (completion) completion(refused, name);
    }];
}

// createChildChannel: the group DM of the conversation's people and the new ones, with its
// history from `start` (omitted for none).
- (void)createGroupFromConversation:(NSString *)conversationID addingUsers:(NSArray<NSString *> *)userIDs historyFrom:(NSString *)start
                         completion:(void (^)(NSString *, NSString *))completion {
    NSMutableDictionary *params = [@{@"channel" : conversationID, @"user_ids" : [userIDs componentsJoinedByString:@","], @"_x_reason" : @"add-to-mpdm"} mutableCopy];
    if (start) params[@"migrate_history_start_ts"] = start;
    [self request:@"conversations.createChild" params:params priority:SNCallUserFacing completion:^(NSDictionary *response, NSError *error) {
        NSDictionary *channel = SNJSONObject(response, @"channel");
        NSString *created = SNJSONString(channel, @"id");
        if (channel && created) [self applyConversations:@[ channel ]];
        if (completion) completion(created, created ? nil : Outcome(error) ?: @"");
    }];
}

@end
