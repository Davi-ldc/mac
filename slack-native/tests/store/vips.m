// The VIPs against a fake API with made-up, API-shaped answers: the boot's users.priority.list on
// a paid plan only, vip_users_updated, the toggle's requests and its undo, and the cache.
#import "../net/stub.h"
#import "model/json.h"
#import "store/fixture.h"
#import "sync/sync.h"
#import "test.h"

static NSDictionary *Boot(NSString *plan) {
    NSMutableDictionary *team = [@{@"id" : @"T0NORTHWND", @"name" : @"Northwind Studio", @"domain" : @"northwind-studio"} mutableCopy];
    if (plan) team[@"plan"] = plan;
    return @{@"ok" : @YES, @"self" : @{@"id" : @"U01ALEX", @"name" : @"alex"}, @"team" : team, @"channels" : @[], @"ims" : @[]};
}

static SNSync *SyncOnPlan(SNTestAPI *api, NSString *plan) {
    api.answer = ^NSDictionary *(NSString *method, NSDictionary *params) {
        if ([method isEqualToString:@"client.userBoot"]) return Boot(plan);
        if ([method isEqualToString:@"users.priority.list"]) return @{@"ok" : @YES, @"users" : @{@"manual_provenance" : @[ @"U02SAM", @"U03PRIYA" ]}};
        return @{@"ok" : @YES};
    };
    return [[SNSync alloc] initWithStore:[[SNStore alloc] initWithDatabase:nil api:api] api:api];
}

SN_TEST(StoreAsksForTheVIPsOnBootOfAPaidPlan) {
    SNTestAPI *api = [SNTestAPI new];
    SNSync *sync = SyncOnPlan(api, @"std");
    __block BOOL booted = NO;
    [sync bootWithCompletion:^(BOOL ok) { booted = ok; }];
    SNExpect(SNWaitUntil(2, ^BOOL { return booted && sync.store.vipUserIDs.count == 2; }), "users.priority.list's manual_provenance are the VIPs");
    SNExpect(sync.store.offersVIPs, "a plan offers VIPs");
    SNExpect(([sync.store.vipUserIDs isEqualToArray:@[ @"U02SAM", @"U03PRIYA" ]]), "in Slack's order");
    NSUInteger index = [api.methods indexOfObject:@"users.priority.list"];
    SNExpect([api.calls[index][1][@"_x_reason"] isEqualToString:@"fetch-priority-users-on-boot-render"], "with the web client's reason");

    SNTestAPI *freeAPI = [SNTestAPI new];
    SNSync *free = SyncOnPlan(freeAPI, @"");
    booted = NO;
    [free bootWithCompletion:^(BOOL ok) { booted = ok; }];
    SNExpect(SNWaitUntil(2, ^BOOL { return booted && [freeAPI.methods containsObject:@"users.prefs.get"]; }), "a free workspace boots");
    SNSettle(0.2);
    SNExpect(!free.store.offersVIPs && ![freeAPI.methods containsObject:@"users.priority.list"], "without a plan, no VIPs are asked for");
}

static SNStore *Store(SNTestAPI *api, SNDatabase *database) {
    SNStore *store = [[SNStore alloc] initWithDatabase:database api:api];
    [store performChanges:^{
        [store applyWorkspace:@{@"id" : @"T0NORTHWND", @"name" : @"Northwind Studio", @"domain" : @"northwind-studio", @"plan" : @"std"}];
        [store applySelfUserID:@"U01ALEX"];
        [store applyUsers:@[ @{@"id" : @"U01ALEX", @"name" : @"alex"}, @{@"id" : @"U02SAM", @"name" : @"sam"}, @{@"id" : @"U03PRIYA", @"name" : @"priya"} ]];
    }];
    return store;
}

SN_TEST(StoreTakesTheVIPsFromTheirEvent) {
    SNStore *store = Store([SNTestAPI new], nil);
    __block NSUInteger notes = 0;
    id observer = SNObserveChanges(store, ^(SNChange *change) {
        if (change.vips) notes++;
    });
    [store applyEvent:@{@"type" : @"vip_users_updated", @"vip_users" : @[ @"U03PRIYA" ], @"event_ts" : @"1795400000.000100"}];
    SNExpect(([store.vipUserIDs isEqualToArray:@[ @"U03PRIYA" ]]) && notes == 1, "vip_users_updated replaces the list and says so");
    [store applyEvent:@{@"type" : @"vip_users_updated", @"vip_users" : @[ @"U03PRIYA" ], @"event_ts" : @"1795400001.000100"}];
    SNExpect(notes == 1, "the same list again changes nothing");
    [store applyEvent:@{@"type" : @"vip_users_updated", @"vip_users" : @[], @"event_ts" : @"1795400002.000100"}];
    SNExpect(store.vipUserIDs.count == 0 && notes == 2, "an empty list clears them");
    SNStopObserving(observer);
}

SN_TEST(StoreAddsAndRemovesVIPsAsTheWebClient) {
    SNTestAPI *api = [SNTestAPI new];
    api.holds = YES;
    SNStore *store = Store(api, nil);
    __block NSString *error = @"unset";
    __block NSInteger limit = -1;
    [store setUser:@"U02SAM" VIP:YES completion:^(NSString *failure, NSInteger max) {
        error = failure;
        limit = max;
    }];
    SNExpect(([store.vipUserIDs isEqualToArray:@[ @"U02SAM" ]]), "an addition shows at once");
    SNExpect(([api.calls.lastObject[0] isEqualToString:@"users.priority.add"]), "users.priority.add");
    SNExpect(([api.calls.lastObject[1] isEqualToDictionary:@{@"user" : @"U02SAM", @"_x_reason" : @"add-user-to-priority"}]), "with the user and the client's reason");
    for (dispatch_block_t answer in api.held) answer();
    [api.held removeAllObjects];
    SNExpect(SNWaitUntil(1, ^BOOL { return error == nil; }) && limit == 0, "Slack's ok answers nil");

    [store setUser:@"U02SAM" VIP:NO completion:nil];
    SNExpect(store.vipUserIDs.count == 0, "a removal shows at once");
    SNExpect(([api.calls.lastObject[1] isEqualToDictionary:@{@"user" : @"U02SAM", @"_x_reason" : @"remove-user-from-priority"}]) &&
             [api.calls.lastObject[0] isEqualToString:@"users.priority.remove"], "users.priority.remove");
    for (dispatch_block_t answer in api.held) answer();
    [api.held removeAllObjects];

    api.holds = NO;
    api.answer = ^NSDictionary *(NSString *method, NSDictionary *params) {
        return @{@"ok" : @NO, @"error" : @"too_many_vips", @"max_vip_limit" : @25};
    };
    error = nil;
    [store setUser:@"U03PRIYA" VIP:YES completion:^(NSString *failure, NSInteger max) {
        error = failure;
        limit = max;
    }];
    SNExpect([store.vipUserIDs containsObject:@"U03PRIYA"], "shown before Slack answers");
    SNExpect(SNWaitUntil(1, ^BOOL { return error != nil; }) && [error isEqualToString:@"too_many_vips"] && limit == 25, "the refusal with Slack's limit");
    SNExpect(store.vipUserIDs.count == 0, "and undone");

    api.answer = nil;
    __block BOOL answered = NO;
    [store setUser:@"U01ALEX" VIP:NO completion:^(NSString *failure, NSInteger max) { answered = failure == nil; }];
    SNExpect(answered && api.calls.count == 3, "asking for what already is calls nothing");
}

SN_TEST(StoreKeepsTheVIPsAcrossLaunches) {
    NSURL *file = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"vips-%@.sqlite", NSUUID.UUID.UUIDString]]];
    SNDatabase *database = [SNDatabase databaseAtURL:file];
    SNStore *store = Store([SNTestAPI new], database);
    [store applyVIPUserIDs:@[ @"U02SAM", @"U03PRIYA", @"U02SAM", @5 ]];
    SNExpect(([store.vipUserIDs isEqualToArray:@[ @"U02SAM", @"U03PRIYA" ]]), "IDs kept once each, anything else dropped");
    database = nil;
    store = nil;
    SNStore *again = [[SNStore alloc] initWithDatabase:[SNDatabase databaseAtURL:file] api:nil];
    SNExpect(([again.vipUserIDs isEqualToArray:@[ @"U02SAM", @"U03PRIYA" ]]), "the next launch shows them before any network");
    [NSFileManager.defaultManager removeItemAtURL:file error:nil];
}

SN_TEST(StoreFixtureHasItsVIPs) {
    SNFixtureSource *source = [SNFixtureSource sourceWithFolder:SNPublicFixture()];
    SNExpect(source.offersVIPs && source.vipUserIDs.count == 1 && [source userWithID:source.vipUserIDs.firstObject], "users.priority.list.json names a fixture person");
}
