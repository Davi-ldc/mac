// Owns the requests about Slack and the workspace rather than a conversation: the Feedback panel's
// and the workspace invitations Slack's invite dialog sends.
#import "model/json.h"
#import "store/internal.h"

// Implements part of SNSource, which the primary class adopts (see internal.h).
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

static NSString *Outcome(NSError *error) { return error ? SNAPIErrorName(error) ?: @"" : nil; }

@implementation SNStore (Slack)

- (void)submitFeedback:(NSString *)text completion:(void (^)(NSString *))completion {
    NSDictionary *params = @{@"custom_input" : text, @"attachments" : @"[]", @"_x_reason" : @"flexpane/feedback"};
    [self request:@"feedback.submitFeedback" params:params priority:SNCallUserFacing completion:^(NSDictionary *response, NSError *error) {
        if (completion) completion(Outcome(error));
    }];
}

// InviteBulkApiInvite: an email typed by hand ("manual") invited as a full member; the source and
// name Slack leaves undefined are left out of the JSON as JSON.stringify does.
- (void)invitePeopleByEmail:(NSArray<NSString *> *)emails channels:(NSArray<NSString *> *)channelIDs message:(NSString *)message
                 completion:(void (^)(NSDictionary<NSString *, id> *, NSString *))completion {
    NSMutableArray *invites = [NSMutableArray new];
    for (NSString *email in emails) [invites addObject:@{@"email" : email, @"mode" : @"manual", @"type" : @"regular"}];
    NSMutableDictionary *params = [@{@"invites" : SNJSONText(invites), @"restricted" : @"false", @"ultra_restricted" : @"false",
                                     @"campaign" : @"invite_people_slash_command", @"channels" : [channelIDs componentsJoinedByString:@","],
                                     @"_x_reason" : @"submit-invite-to-workspace-invites"} mutableCopy];
    if (self.workspace.workspaceID) params[@"team_id"] = self.workspace.workspaceID;
    if (message.length) params[@"extra_message"] = message;
    [self request:@"users.admin.inviteBulk" params:params priority:SNCallUserFacing completion:^(NSDictionary *response, NSError *error) {
        if (error) return completion(nil, Outcome(error));
        NSMutableDictionary<NSString *, id> *results = [NSMutableDictionary new];
        for (NSDictionary *invite in SNJSONArray(response, @"invites") ?: @[]) {
            NSString *email = SNJSONString(invite, @"email");
            if (!email) continue;
            results[email] = SNJSONBool(invite, @"ok") ? NSNull.null : SNJSONString(invite, @"error") ?: @"fatal_error";
        }
        completion(results, nil);
    }];
}

// The GIF picker's searches: Slack's proxy (Tenor's v2 shapes), 50 at a time; without words, the
// featured ones.
- (void)searchGIFs:(NSString *)query reason:(NSString *)reason completion:(void (^)(NSArray<NSDictionary *> *, NSString *))completion {
    BOOL featured = ![query stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].length;
    NSDictionary *params = featured ? @{@"limit" : @"50", @"_x_reason" : @"gif-picker:featured"} : @{@"query" : query, @"limit" : @"50", @"_x_reason" : reason};
    [self request:featured ? @"gif.featured" : @"gif.search" params:params priority:SNCallUserFacing completion:^(NSDictionary *response, NSError *error) {
        NSArray *gifs = SNJSONArray(response, @"gifs");
        completion(gifs, gifs ? nil : Outcome(error) ?: @"invalid_response");
    }];
}

@end
