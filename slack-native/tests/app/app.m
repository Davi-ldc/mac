// The signed-in launch's parts that need no window: one copy per session, the defaults each kind
// of run keeps, and the account's boot retries, end of session, sign-out and quit, against a URL
// protocol stub and an in-memory secret store (nothing reaches Slack or the real Keychain).
#import "../net/stub.h"
#import "app/account.h"
#import "app/instance.h"
#import "net/switches.h"
#import "test.h"

static NSURL *Temporary(NSString *name) {
    NSURL *folder = [NSFileManager.defaultManager.temporaryDirectory URLByAppendingPathComponent:@"slack-native-tests" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *url = [folder URLByAppendingPathComponent:name];
    for (NSString *suffix in @[ @"", @"-wal", @"-shm" ]) [NSFileManager.defaultManager removeItemAtPath:[url.path stringByAppendingString:suffix] error:nil];
    return url;
}

static SNSession *MadeUpSession(void) {
    NSHTTPCookie *d = [NSHTTPCookie cookieWithProperties:@{NSHTTPCookieName : @"d", NSHTTPCookieValue : @"xoxd-made-up", NSHTTPCookieDomain : @".slack.com",
                                                           NSHTTPCookiePath : @"/", NSHTTPCookieSecure : @"TRUE"}];
    SNSessionTeam *team = [SNSessionTeam teamWithJSON:@{@"id" : @"T0NORTHWND", @"token" : @"xoxc-made-up", @"url" : @"https://northwind-studio.slack.com/",
                                                        @"user_id" : @"U01ALEX"}];
    SNSession *session = [[SNSession alloc] initWithCookies:@[ d ] teams:@[ team ] userAgent:@"SlackNativeTest/1"];
    // Fetched just now: no request for the web client's page.
    session.version = @{@"version_ts" : @"1795000000", @"fetched_at" : @((long long)NSDate.date.timeIntervalSince1970).stringValue};
    return session;
}

static SNStubAnswer *JSON(NSDictionary *json) { return [SNStubAnswer status:200 headers:@{@"Content-Type" : @"application/json"} json:json]; }

/// An account over a stubbed URLSession and a cache file of the test's own, with short waits.
static SNAccount *Account(SNSession *session, id<SNSecretStore> secrets, NSString *name, SNStubHandler handler) {
    SNDatabase *database = [SNDatabase databaseAtURL:Temporary([name stringByAppendingPathExtension:@"sqlite"])];
    SNAccount *account = [[SNAccount alloc] initWithSession:session secrets:secrets urlSession:SNStubURLSession(handler) database:database];
    account.client.retryDelays = @[];
    account.client.scheduler.backgroundInterval = 0;
    account.bootRetryDelay = 0.05;
    account.notifier.showBadge = ^(NSString *label) {};
    return account;
}

static NSUInteger Requests(NSString *method) {
    NSUInteger count = 0;
    for (SNStubRequest *request in SNStubRequests()) count += [request.method isEqualToString:method];
    return count;
}

SN_TEST(AppHoldsOneLockPerSession) {
    NSURL *file = Temporary(@"instance.lock");
    SNExpect(SNHoldInstanceLock(file), "the first copy takes the lock");
    SNExpect(!SNHoldInstanceLock(file), "another is refused while the first runs");
    NSURL *real = SNInstanceLockFile();
    SNExpect([real.lastPathComponent isEqualToString:[NSBundle.mainBundle.bundleIdentifier stringByAppendingString:@".session.lock"]] &&
                 [real.URLByDeletingLastPathComponent.path isEqualToString:SNDatabase.folder.path],
             "one lock per bundle identifier's session, in the app's folder");
}

SN_TEST(AppKeepsFixtureDefaultsApart) {
    NSUserDefaults *fixture = SNAppDefaults(nil);
    [fixture setObject:@"C01GENERAL" forKey:@"SNTestLocation"];
    SNExpect(![SNAppDefaults(@"T0NORTHWND") objectForKey:@"SNTestLocation"] && ![NSUserDefaults.standardUserDefaults objectForKey:@"SNTestLocation"],
             "what a fixture run leaves is never read by a signed-in one");
    [fixture removeObjectForKey:@"SNTestLocation"];
}

SN_TEST(AppBootsAgainInTheSameAccount) {
    NSDictionary *boot = @{@"ok" : @YES, @"self" : @{@"id" : @"U01ALEX", @"name" : @"alex"}, @"team" : @{@"id" : @"T0NORTHWND", @"name" : @"Northwind Studio"}};
    __block NSInteger boots = 0;
    SNAccount *account = Account(MadeUpSession(), [SNMemorySecretStore new], @"boot", ^SNStubAnswer *(SNStubRequest *request) {
        if (![request.method isEqualToString:@"client.userBoot"]) return JSON(@{@"ok" : @YES});
        @synchronized(boot) {
            return ++boots < 3 ? nil : JSON(boot);
        }
    });
    __block NSInteger ready = 0;
    [account startWithReady:^{ ready++; }];
    SNExpect(SNWaitUntil(3, ^BOOL { return ready == 1; }), "ready once a boot answers");
    SNExpect(Requests(@"client.userBoot") == 3 && ready == 1, "two boots without an answer tried again by the same client and URLSession");
    SNExpect([account.store.workspace.name isEqualToString:@"Northwind Studio"], "the store has the workspace");
    [account stop];
    // Tasks already handed to the loading system when it stopped are cancelled, not counted.
    SNSettle(0.1);
    NSUInteger sent = SNStubRequests().count;
    __block NSError *refused;
    [account.client call:@"client.counts" params:@{} priority:SNCallUserFacing completion:^(NSDictionary *response, NSError *error) { refused = error; }];
    SNExpect(SNWaitUntil(1, ^BOOL { return refused != nil; }), "a call after stopping is refused");
    SNSettle(0.3);
    SNExpect(SNStubRequests().count == sent, "and nothing goes out any more");
    SNExpect(account.live.state == SNConnectionOffline, "the websocket is down");
}

SN_TEST(AppFollowsTheMacsTimeZoneWhileRunning) {
    SNAccount *account = Account(MadeUpSession(), [SNMemorySecretStore new], @"timezone", ^SNStubAnswer *(SNStubRequest *request) { return JSON(@{@"ok" : @YES}); });
    // Where the Mac was; the system's notification says it moved (back to where it is).
    account.store.macTimeZone = [NSTimeZone timeZoneWithName:@"Europe/Lisbon"];
    SNExpect([NSTimeZone.defaultTimeZone.name isEqualToString:@"Europe/Lisbon"], "times follow the Mac's zone (set_tz_automatically, on by default)");
    [NSNotificationCenter.defaultCenter postNotificationName:NSSystemTimeZoneDidChangeNotification object:nil];
    SNExpect([account.store.macTimeZone isEqualToTimeZone:NSTimeZone.systemTimeZone] && [NSTimeZone.defaultTimeZone isEqualToTimeZone:NSTimeZone.systemTimeZone],
             "NSSystemTimeZoneDidChangeNotification: the store reads the Mac's zone again, and times follow");
    [account stop];
}

SN_TEST(AppKeepsTheSessionWhenItEnds) {
    SNSession *session = MadeUpSession();
    SNMemorySecretStore *secrets = [SNMemorySecretStore new];
    SNSaveSession(session, secrets);
    __block NSInteger refreshes = 0;
    SNAccount *account = Account(session, secrets, @"ended", ^SNStubAnswer *(SNStubRequest *request) {
        if ([request.request.URL.path isEqualToString:@"/auth"]) {
            @synchronized(secrets) {
                refreshes++;
            }
            // The token just refused, handed back.
            return JSON(@{@"ok" : @YES, @"teams" : @{@"T0NORTHWND" : @{@"token" : @"xoxc-made-up"}}});
        }
        return JSON(@{@"ok" : @NO, @"error" : @"invalid_auth"});
    });
    __block NSInteger ended = 0;
    account.onSignedOut = ^{ ended++; };
    [account startWithReady:^{}];
    SNExpect(SNWaitUntil(2, ^BOOL { return ended == 1; }), "the app is told the session ended");
    SNSettle(0.2);
    SNExpect(refreshes == 1 && ended == 1 && account.client.isSignedOut, "after one refresh that brought no new token");
    SNExpect(SNLoadSession(secrets) && [secrets.accounts isEqualToArray:@[ session.account ]], "the stored session stays");
    NSUInteger sent = SNStubRequests().count;
    SNSettle(0.3);
    SNExpect(SNStubRequests().count == sent && Requests(@"client.userBoot") == 1, "and nothing more reaches Slack, boot included");
}

SN_TEST(AppSendsReadMarksBeforeQuittingWithinABound) {
    __block NSTimeInterval answerAfter = 0;
    __block NSInteger marks = 0;
    NSObject *lock = [NSObject new];
    SNAccount *account = Account(MadeUpSession(), [SNMemorySecretStore new], @"quit", ^SNStubAnswer *(SNStubRequest *request) {
        if ([request.method isEqualToString:@"conversations.mark"]) {
            NSTimeInterval wait;
            @synchronized(lock) {
                marks++;
                wait = answerAfter;
            }
            [NSThread sleepForTimeInterval:wait];
        }
        return JSON(@{@"ok" : @YES});
    });
    SNStore *store = account.store;
    NSDictionary *counts = @{@"channels" : @[ @{@"id" : @"C01GENERAL", @"last_read" : @"1795400000.000100", @"latest" : @"1795400100.000100", @"has_unreads" : @YES} ]};
    [store performChanges:^{
        [store applyWorkspace:@{@"id" : @"T0NORTHWND", @"name" : @"Northwind Studio"}];
        [store applySelfUserID:@"U01ALEX"];
        [store applyConversations:@[ @{@"id" : @"C01GENERAL", @"name" : @"general", @"is_channel" : @YES, @"is_member" : @YES} ]];
        [store applyNewestHistory:@{@"messages" : @[ @{@"type" : @"message", @"ts" : @"1795400100.000100", @"user" : @"U02SAM", @"text" : @"hi"} ], @"has_more" : @NO}
                   inConversation:@"C01GENERAL"];
        [store applyCounts:counts];
    }];
    [store markConversation:@"C01GENERAL" readThrough:@"1795400100.000100"];
    __block BOOL finished = NO;
    [account finishWithin:2 completion:^{ finished = YES; }];
    SNExpect(SNWaitUntil(1.5, ^BOOL { return finished; }) && marks == 1, "a mark still waiting goes out, and quitting goes on once it is answered");

    @synchronized(lock) {
        answerAfter = 1.5;
    }
    [store applyCounts:counts];
    [store markConversation:@"C01GENERAL" readThrough:@"1795400100.000100"];
    finished = NO;
    NSDate *start = NSDate.date;
    [account finishWithin:0.3 completion:^{ finished = YES; }];
    SNExpect(SNWaitUntil(1, ^BOOL { return finished; }) && -start.timeIntervalSinceNow < 0.7, "a slow answer is not waited for past the bound");
    [account stop];
}

SN_TEST(AppForgetsEverythingWhenSigningOut) {
    SNSession *session = MadeUpSession();
    SNMemorySecretStore *secrets = [SNMemorySecretStore new];
    SNSaveSession(session, secrets);
    NSURL *cache = Temporary(@"signout.sqlite");
    SNAccount *account = Account(session, secrets, @"signout", ^SNStubAnswer *(SNStubRequest *request) {
        // Slack rotates a cookie in the answer.
        return [SNStubAnswer status:200 headers:@{@"Content-Type" : @"application/json", @"Set-Cookie" : @"d-s=1800000000; Domain=.slack.com; Path=/; Secure"}
                                   json:@{@"ok" : @YES}];
    });
    [account.store applyWorkspace:@{@"id" : @"T0NORTHWND", @"name" : @"Northwind Studio"}];
    SNExpect([NSFileManager.defaultManager fileExistsAtPath:cache.path], "a cache on disk");
    __block NSInteger ended = 0;
    account.onSignedOut = ^{ ended++; };
    [account signOutWithin:1];
    SNExpect(!SNLoadSession(secrets) && ![NSFileManager.defaultManager fileExistsAtPath:cache.path], "the session and the cache are gone at once");
    SNExpect(SNWaitUntil(1, ^BOOL { return Requests(@"auth.signout") == 1; }), "Slack is told");
    SNSettle(0.1);
    __block NSError *refused;
    [account.client call:@"client.counts" params:@{} priority:SNCallUserFacing completion:^(NSDictionary *response, NSError *error) { refused = error; }];
    SNExpect(SNWaitUntil(1, ^BOOL { return refused != nil; }), "then the account stops, once Slack answered");
    SNSettle(1.2);
    SNExpect(!SNLoadSession(secrets) && secrets.accounts.count == 0 && ended == 0, "nothing writes the session back, and it is not a session that ended");
    SNExpect(SNIsMutatingMethod(@"auth.signout"), "read-only mode refuses telling Slack; this Mac still forgets");
}
