// Owns the full profiles the profile panel shows, fetched as the official flexpane fetches them
// each time it opens: users.profile.getSections (reason "profiles"), users.profile.getExtras for
// the shared DMs, and users.profile.get only while the user's profile lacks its fields. In memory
// for the session, as the client's query cache.
#import "model/json.h"
#import "store/internal.h"

// Implements part of SNSource, which the primary class adopts (see internal.h).
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

@implementation SNStore (Profiles)

static const NSUInteger kProfileCacheLimit = 50;

- (NSMutableDictionary *)profileOf:(NSString *)userID {
    if (!self.profiles) self.profiles = [NSMutableDictionary new];
    NSMutableDictionary *profile = self.profiles[userID];
    if (!profile) {
        self.profiles[userID] = profile = [NSMutableDictionary new];
        [self.profileOrder addObject:userID];
        while (self.profileOrder.count > kProfileCacheLimit) {
            NSString *oldest = self.profileOrder.firstObject;
            [self.profileOrder removeObjectAtIndex:0];
            [self.profiles removeObjectForKey:oldest];
        }
    } else {
        [self.profileOrder removeObject:userID];
        [self.profileOrder addObject:userID];
    }
    return profile;
}

- (NSArray<NSDictionary *> *)profileSectionsOfUser:(NSString *)userID { return self.profiles[userID][@"sections"]; }

- (NSArray<NSString *> *)recentConversationsWithUser:(NSString *)userID more:(BOOL *)more {
    NSDictionary *profile = self.profiles[userID];
    if (more) *more = [profile[@"more"] boolValue];
    return profile[@"conversations"];
}

- (void)noteProfile:(NSString *)userID changes:(NSDictionary *)changes {
    [self performChanges:^{
        [[self profileOf:userID] addEntriesFromDictionary:changes];
        [self changed:SNChangeProfiles value:userID];
    }];
}

- (void)loadProfileOfUser:(NSString *)userID {
    [self request:@"users.profile.getSections" params:@{@"user" : userID, @"_x_reason" : @"profiles"} priority:SNCallUserFacing
       completion:^(NSDictionary *response, NSError *error) {
           NSArray *sections = SNJSONArray(SNJSONObject(SNJSONObject(SNJSONObject(response, @"result"), @"data"), @"user"), @"profileSections");
           NSMutableArray *kept = [NSMutableArray new];
           for (id section in sections)
               if ([section isKindOfClass:NSDictionary.class]) [kept addObject:section];
           if (sections) [self noteProfile:userID changes:@{@"sections" : kept}];
       }];
    [self request:@"users.profile.getExtras" params:@{@"keys" : @"im_mpim_ids", @"user" : userID, @"_x_reason" : @"useProfileExtras"} priority:SNCallUserFacing
       completion:^(NSDictionary *response, NSError *error) {
           if (!response) return;
           [self noteProfile:userID changes:@{@"conversations" : SNJSONStrings(response, @"im_mpim_ids"), @"more" : @(SNJSONBool(response, @"has_more_mpims"))}];
       }];
    SNUser *user = [self knownUserWithID:userID];
    if (!user || [SNJSONObject(SNJSONObject(user.json, @"profile"), @"fields") count]) return;
    [self request:@"users.profile.get" params:@{@"user" : userID, @"_x_reason" : @"MemberProfileFlexpane"} priority:SNCallUserFacing
       completion:^(NSDictionary *response, NSError *error) {
           NSDictionary *profile = SNJSONObject(response, @"profile");
           SNUser *known = [self knownUserWithID:userID];
           if (!profile || !known) return;
           // The flexpane takes these from users.profile.get into the member it holds.
           NSMutableDictionary *picked = [NSMutableDictionary new];
           for (NSString *key in @[ @"email", @"fields", @"display_name", @"real_name", @"title", @"pronouns" ])
               if (profile[key]) picked[key] = profile[key];
           NSDictionary *merged = SNJSONMerge(SNJSONObject(known.json, @"profile") ?: @{}, picked);
           [self applyUsers:@[ SNJSONMerge(known.json, @{@"profile" : merged}) ]];
       }];
}

@end
