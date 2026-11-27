// Owns wiring a signed-in workspace's parts together, their start order and their end.
#import "app/account.h"
#import "auth/reauth.h"
#import "net/switches.h"

/// The web client's version values are fetched again after a day.
static const NSTimeInterval SNVersionMaxAge = 24 * 3600;

@interface SNAccount () <SNChangeObserver>
@end

@implementation SNAccount {
    id<SNSecretStore> _secrets;
    SNSessionSaver *_saver;
    void (^_ready)(void);
    NSInteger _bootAttempts;
    BOOL _stopped;
    id _zoneObserver;
}

- (instancetype)initWithSession:(SNSession *)session secrets:(id<SNSecretStore>)secrets urlSession:(NSURLSession *)urlSession database:(SNDatabase *)database {
    return [self initWithSession:session secrets:secrets urlSession:urlSession database:database store:nil];
}

- (instancetype)initWithSession:(SNSession *)session secrets:(id<SNSecretStore>)secrets urlSession:(NSURLSession *)urlSession database:(SNDatabase *)database store:(SNStore *)preloaded {
    if (!(self = [super init])) return nil;
    _session = session;
    _bootRetryDelay = 2;
    _secrets = secrets;
    NSString *teamID = session.teams.firstObject.teamID;
    _saver = [[SNSessionSaver alloc] initWithSession:session store:secrets delay:1];
    __weak SNSessionSaver *weakSaver = _saver;
    session.onChange = ^(SNSession *changed) { [weakSaver sessionChanged]; };
    _client = [[SNClient alloc] initWithSession:session teamID:teamID urlSession:urlSession];
    __weak SNAccount *weakSelf = self;
    _client.refreshToken = ^(NSString *team, void (^completion)(BOOL)) { SNRefreshToken(session, team, urlSession, completion); };
    _client.onSignedOut = ^{
        SNAccount *account = weakSelf;
        if (!account || account->_stopped) return;
        [account stop];
        if (account.onSignedOut) account.onSignedOut();
    };
    if (preloaded) {
        _store = preloaded;
        _store.api = _client;
        [_store attachToMainThread];
    } else {
        SNDatabase *opened = database ?: [SNDatabase databaseAtURL:[SNDatabase URLForWorkspace:teamID]];
        SNTraceLaunch(@"database");
        _store = [[SNStore alloc] initWithDatabase:opened api:_client];
        SNTraceLaunch(@"cache");
    }
    _sync = [[SNSync alloc] initWithStore:_store api:_client];
    _live = [[SNLiveClient alloc] initWithAPI:_client session:session teamID:teamID urlSession:urlSession];
    _notifier = [[SNNotifier alloc] initWithStore:_store];
    NSURL *recovery = [[[SNDatabase URLForWorkspace:teamID] URLByDeletingPathExtension] URLByAppendingPathExtension:@"call.json"];
    _calls = [[SNCallController alloc] initWithAPI:_client urlSession:urlSession userID:session.teams.firstObject.userID ?: _store.me.userID ?: @"" recoveryFile:recovery];
    if (SNCallMedia.isAvailable) _calls.makeMedia = ^SNCallMedia *(NSArray<SNICEServer *> *servers) { return [[SNCallMedia alloc] initWithICEServers:servers audioDevice:nil]; };
    _calls.regionDefaults = NSUserDefaults.standardUserDefaults;
    _store.callController = _calls;

    SNStore *store = _store;
    SNSync *sync = _sync;
    SNLiveClient *live = _live;
    SNCallController *calls = _calls;
    __weak SNLiveClient *weakLive = live;
    __weak SNStore *weakStore = store;
    calls.onChange = ^{ [weakStore callChanged]; };
    calls.preferences = ^NSDictionary * { return weakStore.preferences; };
    live.onEvent = ^(NSDictionary *event) { [store applyEvent:event]; };
    live.onConnect = ^(BOOL fastReconnect) { [sync connectedWithFastReconnect:fastReconnect]; };
    live.onStateChange = ^(SNConnectionState state) { store.connectionState = state; };
    live.presenceUserIDs = ^NSArray<NSString *> * { return sync.presenceUserIDs; };
    store.frameSender = ^(NSDictionary *frame) { [weakLive sendFrame:frame]; };
    sync.presenceChanged = ^(NSArray<NSString *> *userIDs) { [weakLive sendFrame:@{@"type" : @"presence_sub", @"ids" : userIDs}]; };
    [store addChangeObserver:self];
    // Automatic mode (set_tz_automatically) follows the Mac's zone while running, too.
    _zoneObserver = [NSNotificationCenter.defaultCenter addObserverForName:NSSystemTimeZoneDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        [NSTimeZone resetSystemTimeZone];
        store.macTimeZone = NSTimeZone.systemTimeZone;
    }];
    return self;
}

/// The call follows its huddle as the store hears of it.
- (void)sourceChanged:(SNChange *)change {
    NSString *conversationID = _calls.call.conversationID;
    if (conversationID && [change.huddles containsObject:conversationID]) [_calls huddleChanged:[_store huddleInConversation:conversationID]];
}

- (void)startWithReady:(void (^)(void))ready {
    _ready = [ready copy];
    double fetched = [self.session.version[@"fetched_at"] doubleValue];
    BOOL stale = NSDate.date.timeIntervalSince1970 - fetched > SNVersionMaxAge;
    // Kick off network boot before building the UI so TLS + client.userBoot overlap with window
    // construction and the first frame.
    if (stale && !self.session.version.count) [self.client refreshWebClientVersion:^(BOOL ok) { [self boot]; }];
    else {
        if (stale) [self.client refreshWebClientVersion:nil];
        [self boot];
    }
    if (self.store.hasState) [self becameReady];
}

- (void)becameReady {
    void (^ready)(void) = _ready;
    _ready = nil;
    if (ready) ready();
}

- (void)boot {
    if (_stopped) return;
    __weak SNAccount *weakSelf = self;
    [self.sync bootWithCompletion:^(BOOL ok) {
        SNAccount *account = weakSelf;
        if (!account || account->_stopped) return;
        if (ok) {
            SNTraceLaunch(@"boot");
            [account becameReady];
            [account.live start];
            [account.calls recover];
            // Slack's ChimeRegionProvider looks the region up 5 s into a launch.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [weakSelf.calls prefetchRegion]; });
            return;
        }
        // No answer (offline, Slack down): the same account, client and URLSession try again,
        // further apart each time.
        NSTimeInterval delay = SNLiveBackoff(account->_bootAttempts++, account.bootRetryDelay, 120);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [weakSelf boot]; });
    }];
}

- (void)finishWithin:(NSTimeInterval)timeout completion:(void (^)(void))completion {
    __block void (^pending)(void) = [completion copy];
    void (^finish)(void) = ^{
        void (^once)(void) = pending;
        pending = nil;
        if (once) once();
    };
    __block NSInteger waiting = 2;
    void (^done)(void) = ^{
        if (--waiting == 0) finish();
    };
    [self.store flushReadMarks:done];
    [self.calls leaveWithin:timeout completion:done];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)), dispatch_get_main_queue(), finish);
}

- (void)signOutWithin:(NSTimeInterval)timeout { [self signOutWithin:timeout completion:nil]; }

- (void)signOutWithin:(NSTimeInterval)timeout completion:(void (^)(void))completion {
    if (_stopped) {
        if (completion) completion();
        return;
    }
    // Stop live traffic and notifications immediately so nothing arrives while sign-out finishes.
    [self.live stop];
    [self.notifier stop];
    // Forgotten first, so quitting right away leaves nothing behind; no saver is left to write
    // the session back (auth.signout's answer rotates cookies, and stop flushes). Calls failing
    // on the revoked token are not a session that ended.
    self.onSignedOut = nil;
    self.session.onChange = nil;
    [_saver cancel];
    _saver = nil;
    [_secrets deleteAccount:self.session.account];
    [self.store.database deleteFile];
    __block void (^pending)(void) = [completion copy];
    void (^done)(void) = ^{
        [self stop];
        void (^once)(void) = pending;
        pending = nil;
        if (once) once();
    };
    // rooms.leave needs the token auth.signout revokes.
    [self.calls leaveWithin:timeout completion:^{
        [self.client call:@"auth.signout" params:@{@"_x_reason" : @"signout"} priority:SNCallUserFacing completion:^(NSDictionary *response, NSError *error) { done(); }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)), dispatch_get_main_queue(), done);
    }];
}

- (void)stop {
    if (_stopped) return;
    _stopped = YES;
    _ready = nil;
    // Normally left already (quit, sign-out); with the session gone (signed out) rooms.leave fails
    // and the next launch leaves the call.
    [self.calls leaveWithin:self.calls.leaveTimeout completion:^{}];
    [self.live stop];
    [self.notifier stop];
    [self.client invalidate];
    [NSNotificationCenter.defaultCenter removeObserver:_zoneObserver];
    self.session.onChange = nil;
    [_saver flush];
}

@end
