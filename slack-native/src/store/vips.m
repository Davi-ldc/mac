// Owns the user's VIPs (Slack's "priority" people) as the official client keeps them: the IDs
// users.priority.list's manual_provenance gives at boot, replaced by every vip_users_updated, and
// the profile's VIP button changing them at once. Kept in the cache so a launch shows them before
// any network.
#import "model/json.h"
#import "store/internal.h"

// Implements part of SNSource, which the primary class adopts (see internal.h).
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

static NSString *const kVIPsKey = @"vip_users";

@implementation SNStore (VIPs)

static NSArray<NSString *> *StringsIn(NSArray *items) {
    NSMutableOrderedSet *ids = [NSMutableOrderedSet new];
    for (id item in items)
        if ([item isKindOfClass:NSString.class] && [item length]) [ids addObject:item];
    return ids.array;
}

- (NSArray<NSString *> *)vipUserIDs {
    if (!self.vipIDs) {
        NSArray *saved = [self.database jsonForKey:kVIPsKey];
        self.vipIDs = [saved isKindOfClass:NSArray.class] ? StringsIn(saved) : @[];
    }
    return self.vipIDs;
}

// isPriorityVipAvailableForCurrentTeam: a paid plan (team.plan set).
- (BOOL)offersVIPs { return SNJSONString(self.workspace.json, @"plan").length > 0; }

- (void)applyVIPUserIDs:(NSArray *)userIDs {
    NSArray<NSString *> *ids = StringsIn(userIDs);
    if ([ids isEqualToArray:self.vipUserIDs]) return;
    [self performChanges:^{
        self.vipIDs = ids;
        [self.database setJSON:ids forKey:kVIPsKey];
        [self changed:SNChangeVIPs value:nil];
    }];
}

// togglePriorityUserById: the list changes first, then users.priority.add / .remove with the
// client's reasons; Slack's own answer is the vip_users_updated event.
- (void)setUser:(NSString *)userID VIP:(BOOL)vip completion:(void (^)(NSString *, NSInteger))completion {
    NSArray<NSString *> *was = self.vipUserIDs;
    if ([was containsObject:userID] == vip) {
        if (completion) completion(nil, 0);
        return;
    }
    NSMutableArray *ids = [was mutableCopy];
    if (vip) [ids addObject:userID];
    else [ids removeObject:userID];
    [self applyVIPUserIDs:ids];
    NSDictionary *params = @{@"user" : userID, @"_x_reason" : vip ? @"add-user-to-priority" : @"remove-user-from-priority"};
    [self request:vip ? @"users.priority.add" : @"users.priority.remove" params:params priority:SNCallUserFacing completion:^(NSDictionary *response, NSError *error) {
        if (error) {
            NSMutableArray *reverted = [self.vipUserIDs mutableCopy];
            if (vip) [reverted removeObject:userID];
            else if (![reverted containsObject:userID]) [reverted addObject:userID];
            [self applyVIPUserIDs:reverted];
        }
        if (completion) completion(error ? SNAPIErrorName(error) ?: @"" : nil, SNJSONInteger(SNAPIErrorResponse(error), @"max_vip_limit"));
    }];
}

// The VIP preferences ask for 99 and show the first ones that are not VIPs yet.
- (void)fetchVIPRecommendations:(void (^)(NSArray<NSDictionary *> *))completion {
    NSDictionary *params = @{@"limit" : @"99", @"_x_reason" : @"vip-list-preferences-modal"};
    [self request:@"users.priority.getRecommendations" params:params priority:SNCallUserFacing completion:^(NSDictionary *response, NSError *error) {
        NSMutableArray *users = response ? [NSMutableArray new] : nil;
        for (id item in SNJSONArray(response, @"users"))
            if ([item isKindOfClass:NSDictionary.class] && SNJSONString(item, @"user_id")) [users addObject:item];
        completion(users);
    }];
}

@end
