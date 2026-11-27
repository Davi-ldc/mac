// Application lifecycle: overlapped Keychain+SQLite preload, first frame before network, menus, and window-close playback retention.
#import "app/app.h"
#import "app/trace.h"
#import "model/json.h"
#import "render/images.h"
#import "theme/theme.h"
#import "ui/auth/signin.h"

static NSString *const kSPEnginePrefKey = @"sp.audioEnginePreference";
static NSString *const kSPSongRadioKey = @"sp.songRadioEnabled";

#pragma mark - SPAppPreload

@interface SPAppPreload ()
@property (nonatomic, strong, readwrite) dispatch_group_t group;
@property (nonatomic, strong, readwrite) id<SPSecretStore> secretStore;
@property (nonatomic, strong, readwrite, nullable) SPSessionBlob *session;
@property (nonatomic, strong, readwrite, nullable) SPStore *store;
@end

@implementation SPAppPreload

+ (instancetype)startAsync {
    SPAppPreload *p = [SPAppPreload new];
    p.group = dispatch_group_create();
    p.secretStore = [SPKeychain sessionKeychain];

    dispatch_group_enter(p.group);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // Prime theme tokens in parallel with AppKit startup.
        (void)SPThemeDarkPalette();
        (void)SPThemeTypography();
        (void)SPThemeMetrics();

        // Single Keychain read off the main thread.
        SPSessionBlob *blob = SPLoadSessionBlob(p.secretStore);
        p.session = blob;
        SPTraceLaunch("launch:keychain");

        if (blob) {
            NSURL *dbURL = [SPDatabase URLForAccount:blob.accountKey];
            SPDatabase *db = [SPDatabase databaseAtURL:dbURL];
            p.store = [[SPStore alloc] initWithDatabase:db];
            SPTraceLaunch("launch:database");
        }
        dispatch_group_leave(p.group);
    });
    return p;
}

@end

#pragma mark - SPAppController

@implementation SPAppController {
    id<SPSecretStore> _secretStore;
    SPAuth *_auth;
    SPNetClient *_netClient;
    SPConnectClient *_connectClient;
    SPStore *_store;
    id<SPAudioEngine> _audioEngine;
    SPMediaKeysBridge *_mediaKeys;
    SPShell *_shell;
    SPPreferencesWindowController *_prefsController;
    NSWindow *_signInWindow;
    SPSignInView *_signInView;
    BOOL _bootedNetwork;
    uint64_t _loginGeneration;
    uint64_t _sessionGeneration;
    NSMutableArray<SPCancelToken *> *_bootTokens;
    NSMutableSet<NSString *> *_hydratingTrackIDs;
    dispatch_source_t _termSignal;
}

- (SPShell *)shell { return _shell; }
- (SPStore *)store { return _store; }
- (id<SPAudioEngine>)audioEngine { return _audioEngine; }
- (SPPreferencesWindowController *)prefsController { return _prefsController; }

- (void)attachAudioEngine:(id<SPAudioEngine>)engine
                    store:(SPStore *)store
                netClient:(SPNetClient *)netClient
            connectClient:(SPConnectClient *)connectClient
                mediaKeys:(SPMediaKeysBridge *)mediaKeys {
    _audioEngine = engine;
    _store = store;
    _netClient = netClient;
    _connectClient = connectClient;
    _mediaKeys = mediaKeys;
    if (!_hydratingTrackIDs) _hydratingTrackIDs = [NSMutableSet new];
    if (!_bootTokens) _bootTokens = [NSMutableArray new];
}

- (void)trackBootToken:(SPCancelToken *)token {
    if (!token) return;
    if (!_bootTokens) _bootTokens = [NSMutableArray new];
    [_bootTokens addObject:token];
}

- (void)cancelBootTokens {
    for (SPCancelToken *t in _bootTokens) [t cancel];
    [_bootTokens removeAllObjects];
}

#pragma mark - NSApplicationDelegate

- (void)applicationWillFinishLaunching:(NSNotification *)notification {
    (void)notification;
    SPApplySavedAppearancePreference();
    // Install the menu bar synchronously before finishLaunching completes; macOS ignores a
    // mainMenu assigned only in a post-frame run loop observer, leaving Cmd+Q/V/C broken.
    NSApp.mainMenu = [self buildMainMenu];
    signal(SIGTERM, SIG_IGN);
    _termSignal = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(_termSignal, ^{ [NSApp terminate:nil]; });
    dispatch_resume(_termSignal);

    SPAppPreload *preload = _preload;
    if (!preload) {
        [self showSignInWindow];
        return;
    }

    // Usually preload already finished while AppKit initialized; bounded wait avoids blocking if Keychain prompts.
    if (dispatch_group_wait(preload.group, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC))) == 0) {
        [self finishPreload:preload];
    } else {
        __weak typeof(self) weakSelf = self;
        dispatch_group_notify(preload.group, dispatch_get_main_queue(), ^{
            [weakSelf finishPreload:preload];
        });
    }
}

- (void)finishPreload:(SPAppPreload *)preload {
    if (_preload != preload) return;
    _secretStore = preload.secretStore;
    SPSessionBlob *session = preload.session;
    SPStore *store = preload.store;
    _preload = nil;

    if (!session) {
        NSApp.mainMenu = [self buildMainMenu];
        [self showSignInWindow];
        return;
    }

    [self openSignedInSession:session preloadedStore:store];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    (void)sender;
    // Closing window with Cmd+W keeps playback alive while releasing UI views/surfaces.
    return NO;
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag {
    (void)sender;
    if (!flag) {
        if (_shell) {
            [_shell showWindow];
        } else if (_signInWindow) {
            [_signInWindow makeKeyAndOrderFront:nil];
        }
    }
    return YES;
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [self cancelBootTokens];
    [_mediaKeys deactivate];
    if ([_audioEngine isKindOfClass:SPSoloistEngine.class]) {
        [(SPSoloistEngine *)_audioEngine stopAndWait];
    } else {
        [_audioEngine stop];
    }
    [_connectClient disconnect];
    [_store.database close];
}

#pragma mark - Sign-In Flow

- (void)showSignInWindow {
    if (!_signInWindow) {
        NSRect rect = NSMakeRect(0, 0, 500.0, 400.0);
        _signInWindow = [[NSWindow alloc] initWithContentRect:rect
                                                    styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskFullSizeContentView
                                                      backing:NSBackingStoreBuffered
                                                        defer:YES];
        _signInWindow.title = @"Spotify";
        _signInWindow.titleVisibility = NSWindowTitleHidden;
        _signInWindow.titlebarAppearsTransparent = YES;
        _signInWindow.backgroundColor = NSColor.windowBackgroundColor;
        _signInWindow.releasedWhenClosed = NO;

        _signInView = [[SPSignInView alloc] initWithFrame:rect];
        __weak typeof(self) weakSelf = self;
        _signInView.onSignIn = ^{ [weakSelf startBrowserOAuth]; };
        _signInView.onCancel = ^{
            SPAppController *s = weakSelf;
            if (!s) return;
            s->_loginGeneration++;
            [s->_auth cancelAuthorization];
            s->_auth = nil;
            s->_signInView.loading = NO;
            s->_signInView.statusMessage = nil;
        };
        _signInWindow.contentView = _signInView;
    }
    [_signInWindow center];
    [_signInWindow makeKeyAndOrderFront:nil];
    [NSApp activate];
}

- (void)startBrowserOAuth {
    if (!_secretStore) _secretStore = [SPKeychain sessionKeychain];
    [_auth cancelAuthorization];
    uint64_t loginGen = ++_loginGeneration;
    _auth = [[SPAuth alloc] initWithSecretStore:_secretStore];
    _signInView.loading = YES;
    _signInView.errorMessage = nil;
    _signInView.statusMessage = @"Complete sign-in in your browser...";

    __weak typeof(self) weakSelf = self;
    [_auth authorizeWithBrowserOpener:nil persist:YES timeout:180.0 completion:^(SPSessionBlob *blob, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            SPAppController *s = weakSelf;
            if (!s || s->_loginGeneration != loginGen) return;
            s->_signInView.loading = NO;
            if (error || !blob) {
                s->_signInView.errorMessage = error.localizedDescription ?: @"Sign-in failed. Please try again.";
                return;
            }
            [s->_signInWindow orderOut:nil];
            s->_signInWindow = nil;
            s->_signInView = nil;
            [s openSignedInSession:blob preloadedStore:nil];
        });
    }];
}

#pragma mark - Signed-In Session & First-Frame Boot

- (void)openSignedInSession:(SPSessionBlob *)session preloadedStore:(SPStore *)preloadedStore {
    _sessionGeneration++;
    [self cancelBootTokens];
    if (!_hydratingTrackIDs) _hydratingTrackIDs = [NSMutableSet new];
    else [_hydratingTrackIDs removeAllObjects];
    _bootedNetwork = NO;
    if (!_secretStore) _secretStore = [SPKeychain sessionKeychain];
    _auth = [[SPAuth alloc] initWithSecretStore:_secretStore session:session urlSession:nil];
    _netClient = [[SPNetClient alloc] initWithAuth:_auth];

    if (preloadedStore) {
        _store = preloadedStore;
    } else {
        SPDatabase *db = [SPDatabase databaseAtURL:[SPDatabase URLForAccount:session.accountKey]];
        _store = [[SPStore alloc] initWithDatabase:db];
        SPTraceLaunch("launch:database");
    }

    _connectClient = [[SPConnectClient alloc] initWithAuth:_auth netClient:_netClient store:_store];
    _connectClient.delegate = self;

    [self configureAudioEngineFromPreferences];

    _mediaKeys = [[SPMediaKeysBridge alloc] initWithEngine:_audioEngine];

    _shell = [[SPShell alloc] initWithStore:_store
                                audioEngine:_audioEngine
                                  netClient:_netClient
                              connectClient:_connectClient
                                   defaults:NSUserDefaults.standardUserDefaults];
    BOOL radioOn = ([NSUserDefaults.standardUserDefaults objectForKey:kSPSongRadioKey] != nil)
        ? [NSUserDefaults.standardUserDefaults boolForKey:kSPSongRadioKey]
        : YES;
    _shell.songRadioEnabled = radioOn;

    __weak typeof(self) weakSelf = self;
    _shell.onOpenPreferences = ^{ [weakSelf openPreferences:nil]; };
    _shell.onSignOut = ^{ [weakSelf signOutAction:nil]; };

    // First frame from SQLite BEFORE any network call!
    [_shell showWindow];
    SPTraceLaunch("launch:window");

    // Defer network boot until right after Core Animation commits the first frame (order 2000000).
    CFRunLoopObserverRef obs = CFRunLoopObserverCreateWithHandler(
        kCFAllocatorDefault,
        kCFRunLoopBeforeWaiting,
        false,
        3000000,
        ^(CFRunLoopObserverRef observer, CFRunLoopActivity activity) {
            (void)activity;
            SPTraceLaunch("launch:frame");
            CFRunLoopObserverInvalidate(observer);
            SPAppController *s = weakSelf;
            if (!s) return;
            [s bootNetworkAndMedia];
        });
    CFRunLoopAddObserver(CFRunLoopGetMain(), obs, kCFRunLoopCommonModes);
    CFRelease(obs);
}

- (void)configureAudioEngineFromPreferences {
    SPAudioEnginePreference pref = (SPAudioEnginePreference)[NSUserDefaults.standardUserDefaults integerForKey:kSPEnginePrefKey];
    [_audioEngine stop];
    if (pref == SPAudioEnginePrefSoloist) {
        SPSoloistEngine *solo = [[SPSoloistEngine alloc] initWithConnectClient:_connectClient netClient:_netClient store:_store];
        solo.executablePath = [SPSoloistEngine discoverExecutablePath];
        solo.soloistKey = _auth.session.soloistKey;
        solo.delegate = self;
        _audioEngine = solo;
        _connectClient.canBePlayer = NO;
        _connectClient.hidden = YES;
    } else {
        SPFairPlayEngine *fp = [[SPFairPlayEngine alloc] initWithNetClient:_netClient store:_store];
        fp.delegate = self;
        _audioEngine = fp;
        _connectClient.canBePlayer = YES;
        _connectClient.hidden = NO;
    }
    _shell.audioEngine = _audioEngine;
    _mediaKeys.engine = _audioEngine;
}

- (void)bootNetworkAndMedia {
    if (_bootedNetwork) return;
    _bootedNetwork = YES;
    uint64_t gen = _sessionGeneration;

    [_mediaKeys activate];
    [_audioEngine startWithCompletion:nil];
    [_connectClient connect];

    __weak typeof(self) weakSelf = self;
    [self trackBootToken:[_netClient fetchProfileWithCompletion:^(SPUserProfile *profile, NSError *err) {
        if (err || !profile) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            SPAppController *s = weakSelf;
            if (!s || s->_sessionGeneration != gen) return;
            [s->_store setUserProfile:profile];
        });
    }]];

    [self trackBootToken:[_netClient fetchHomeWithCompletion:^(SPHomePage *home, NSError *err) {
        if (err || !home) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            SPAppController *s = weakSelf;
            if (!s || s->_sessionGeneration != gen) return;
            [s->_store applyHomePage:home];
        });
    }]];

    [self syncLikedSongsPageAtOffset:0
                      accumulatedIDs:[NSMutableArray new]
                         addedAtByID:[NSMutableDictionary new]
                         incremental:(_store.libraryTracks.count == 0)
                          generation:gen];

    [self syncLibraryFilter:@"Playlists" offset:0 accumulatedIDs:[NSMutableArray new] generation:gen];
    [self syncLibraryFilter:@"Albums" offset:0 accumulatedIDs:[NSMutableArray new] generation:gen];
    [self syncLibraryFilter:@"Artists" offset:0 accumulatedIDs:[NSMutableArray new] generation:gen];

    SPTraceLaunch("launch:boot");
}

- (void)syncLikedSongsPageAtOffset:(NSInteger)offset
                    accumulatedIDs:(NSMutableArray<NSString *> *)accumulatedIDs
                       addedAtByID:(NSMutableDictionary<NSString *, NSNumber *> *)addedAtByID
                       incremental:(BOOL)incremental
                        generation:(uint64_t)gen {
    if (!_netClient || _sessionGeneration != gen) return;
    static const NSInteger kLikedPageSize = 50;
    static const NSInteger kLikedMaxItems = 50000;
    __weak typeof(self) weakSelf = self;
    [self trackBootToken:[_netClient fetchLikedSongsOffset:offset limit:kLikedPageSize completion:^(NSArray<SPTrack *> *tracks, NSArray<SPPlaylistItem *> *items, NSInteger total, NSInteger rawCount, NSError *err) {
        if (err) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            SPAppController *s = weakSelf;
            if (!s || s->_sessionGeneration != gen) return;
            if (tracks.count) {
                [s->_store upsertTracks:tracks];
            }
            NSMutableArray<NSString *> *pageIDs = [NSMutableArray arrayWithCapacity:tracks.count];
            NSMutableDictionary<NSString *, NSNumber *> *pageAdded = [NSMutableDictionary dictionaryWithCapacity:items.count];
            for (SPTrack *t in tracks) {
                [pageIDs addObject:t.trackID];
                [accumulatedIDs addObject:t.trackID];
            }
            for (SPPlaylistItem *it in items) {
                pageAdded[it.trackID] = @(it.addedAt);
                addedAtByID[it.trackID] = @(it.addedAt);
            }
            if (incremental) {
                if (offset == 0) {
                    [s->_store setLibraryTrackIDs:pageIDs addedAtByID:pageAdded];
                } else if (pageIDs.count) {
                    [s->_store appendLibraryTrackIDs:pageIDs addedAtByID:pageAdded];
                }
            }
            NSInteger nextOffset = offset + rawCount;
            BOOL hasMore = (rawCount > 0) && (nextOffset < kLikedMaxItems) &&
                           (total > 0 ? (nextOffset < total) : (rawCount >= kLikedPageSize));
            if (hasMore) {
                [s syncLikedSongsPageAtOffset:nextOffset
                               accumulatedIDs:accumulatedIDs
                                  addedAtByID:addedAtByID
                                  incremental:incremental
                                   generation:gen];
            } else if (!incremental || (offset == 0 && accumulatedIDs.count == 0)) {
                [s->_store setLibraryTrackIDs:accumulatedIDs addedAtByID:addedAtByID];
            }
        });
    }]];
}

- (void)syncLibraryFilter:(NSString *)filter
                   offset:(NSInteger)offset
           accumulatedIDs:(NSMutableArray<NSString *> *)accumulatedIDs
               generation:(uint64_t)gen {
    if (!_netClient || _sessionGeneration != gen) return;
    static const NSInteger kLibraryPageSize = 50;
    static const NSInteger kLibraryMaxItems = 20000;
    __weak typeof(self) weakSelf = self;
    [self trackBootToken:[_netClient fetchLibraryFilter:filter offset:offset limit:kLibraryPageSize order:nil completion:^(NSDictionary *dict, NSError *err) {
        if (err || !dict) return;
        NSArray *items = SPJSONArray(dict[@"items"]) ?: @[];
        NSInteger total = SPJSONInt(dict[@"totalCount"], -1);

        NSMutableArray<SPPlaylist *> *playlists = [filter isEqualToString:@"Playlists"] ? [NSMutableArray new] : nil;
        NSMutableArray<SPAlbum *> *albums = [filter isEqualToString:@"Albums"] ? [NSMutableArray new] : nil;
        NSMutableArray<SPArtist *> *artists = [filter isEqualToString:@"Artists"] ? [NSMutableArray new] : nil;
        NSMutableArray<NSString *> *pageIDs = [NSMutableArray arrayWithCapacity:items.count];

        for (id raw in items) {
            NSDictionary *entry = SPJSONDict(raw);
            NSDictionary *itemWrapper = SPJSONDict(entry[@"item"]);
            NSDictionary *itemData = SPJSONDict(itemWrapper[@"data"]);
            if (!itemData) continue;
            if (playlists) {
                SPPlaylist *pl = [SPPlaylist playlistFromPathfinderDict:itemData];
                if (pl) { [playlists addObject:pl]; [pageIDs addObject:pl.playlistID]; }
            } else if (albums) {
                SPAlbum *al = [SPAlbum albumFromPathfinderDict:itemData];
                if (al) { [albums addObject:al]; [pageIDs addObject:al.albumID]; }
            } else if (artists) {
                SPArtist *ar = [SPArtist artistFromPathfinderDict:itemData];
                if (ar) { [artists addObject:ar]; [pageIDs addObject:ar.artistID]; }
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            SPAppController *s = weakSelf;
            if (!s || s->_sessionGeneration != gen) return;
            if (playlists.count) [s->_store upsertPlaylists:playlists];
            if (albums.count) [s->_store upsertAlbums:albums];
            if (artists.count) [s->_store upsertArtists:artists];
            [accumulatedIDs addObjectsFromArray:pageIDs];

            NSInteger rawCount = (NSInteger)items.count;
            NSInteger nextOffset = offset + rawCount;
            BOOL hasMore = (rawCount > 0) && (nextOffset < kLibraryMaxItems) &&
                           (total >= 0 ? (nextOffset < total) : (rawCount >= kLibraryPageSize));
            if (hasMore) {
                if (offset == 0 && accumulatedIDs.count) {
                    if (playlists && s->_store.libraryPlaylists.count == 0) [s->_store setLibraryPlaylistIDs:accumulatedIDs];
                    else if (albums && s->_store.libraryAlbums.count == 0) [s->_store setLibraryAlbumIDs:accumulatedIDs addedAtByID:nil];
                    else if (artists && s->_store.libraryArtists.count == 0) [s->_store setLibraryArtistIDs:accumulatedIDs];
                }
                [s syncLibraryFilter:filter offset:nextOffset accumulatedIDs:accumulatedIDs generation:gen];
            } else {
                if (playlists) [s->_store setLibraryPlaylistIDs:accumulatedIDs];
                else if (albums) [s->_store setLibraryAlbumIDs:accumulatedIDs addedAtByID:nil];
                else if (artists) [s->_store setLibraryArtistIDs:accumulatedIDs];
            }
        });
    }]];
}

- (void)hydrateTracksForPlaybackState:(SPPlaybackState *)state {
    if (!state || !_netClient || !_store) return;
    if (!_hydratingTrackIDs) _hydratingTrackIDs = [NSMutableSet new];
    NSMutableArray<NSString *> *missing = [NSMutableArray new];
    if (state.currentTrackID.length && ![_store trackWithID:state.currentTrackID]) {
        [missing addObject:state.currentTrackID];
    }
    NSUInteger queuedLimit = MIN(state.nextTracks.count, (NSUInteger)20);
    for (NSUInteger i = 0; i < queuedLimit; i++) {
        NSString *tid = state.nextTracks[i].trackID;
        if (tid.length && ![_store trackWithID:tid] && ![missing containsObject:tid]) {
            [missing addObject:tid];
        }
    }
    if (!missing.count) return;
    uint64_t gen = _sessionGeneration;
    __weak typeof(self) weakSelf = self;
    for (NSString *tid in missing) {
        if ([_hydratingTrackIDs containsObject:tid]) continue;
        [_hydratingTrackIDs addObject:tid];
        [self trackBootToken:[_netClient fetchTrackMetadataWithID:tid completion:^(NSDictionary *rawMeta, SPTrack *track, NSError *err) {
            (void)rawMeta;
            dispatch_async(dispatch_get_main_queue(), ^{
                SPAppController *s = weakSelf;
                if (!s) return;
                [s->_hydratingTrackIDs removeObject:tid];
                if (s->_sessionGeneration != gen || err || !track) return;
                [s->_store upsertTracks:@[ track ]];
                SPPlaybackState *cur = s->_store.playbackState;
                if (cur && [cur.currentTrackID isEqualToString:tid]) {
                    [s->_mediaKeys updateNowPlayingWithState:cur track:track];
                }
            });
        }]];
    }
}

#pragma mark - SPConnectClientDelegate

- (void)connectClient:(SPConnectClient *)client didChangeConnected:(BOOL)connected {
    (void)client;
    if (connected) {
        SPImageResetFailedURLs();
    }
}

- (void)connectClient:(SPConnectClient *)client didUpdateCluster:(SPClusterState *)cluster {
    (void)client;
    SPPlaybackState *pb = cluster.playbackState ?: _store.playbackState;
    if (!pb) return;
    [self hydrateTracksForPlaybackState:pb];
    SPTrack *track = pb.currentTrackID.length ? [_store trackWithID:pb.currentTrackID] : nil;
    [_mediaKeys updateNowPlayingWithState:pb track:track];
}

- (BOOL)connectClient:(SPConnectClient *)client didReceiveCommandPayload:(NSDictionary *)payload {
    (void)client;
    if (!payload || !_audioEngine) return NO;
    NSDictionary *cmd = SPJSONDict(payload[@"command"]) ?: payload;
    NSString *endpoint = SPJSONString(cmd[@"endpoint"]);

    if ([endpoint isEqualToString:@"pause"]) {
        [_audioEngine pause];
        return YES;
    }
    if ([endpoint isEqualToString:@"resume"]) {
        [_audioEngine resume];
        return YES;
    }
    if ([endpoint isEqualToString:@"skip_next"]) {
        NSDictionary *targetTrack = SPJSONDict(cmd[@"track"]);
        NSString *targetURI = SPJSONString(targetTrack[@"uri"]);
        NSString *targetUID = SPJSONString(targetTrack[@"uid"]);
        if (targetURI.length || targetUID.length) {
            NSArray<SPQueueTrack *> *nextTracks = _audioEngine.playbackState.nextTracks;
            for (NSUInteger i = 0; i < nextTracks.count; i++) {
                SPQueueTrack *qt = nextTracks[i];
                if ((targetUID.length && [qt.uid isEqualToString:targetUID]) ||
                    (targetURI.length && [qt.uri isEqualToString:targetURI])) {
                    [_audioEngine skipToQueueIndex:(NSInteger)i];
                    return YES;
                }
            }
        }
        [_audioEngine skipNext];
        return YES;
    }
    if ([endpoint isEqualToString:@"skip_prev"]) {
        [_audioEngine skipPrevious];
        return YES;
    }
    if ([endpoint isEqualToString:@"seek_to"]) {
        NSNumber *val = SPJSONNumber(cmd[@"value"]);
        if (!val) return NO;
        [_audioEngine seekToMs:val.longLongValue];
        return YES;
    }
    if ([endpoint isEqualToString:@"set_shuffling_context"]) {
        NSNumber *val = SPJSONNumber(cmd[@"value"]);
        if (!val) return NO;
        [_audioEngine setShuffle:val.boolValue];
        return YES;
    }
    if ([endpoint isEqualToString:@"set_repeating_context"]) {
        NSNumber *val = SPJSONNumber(cmd[@"value"]);
        if (!val) return NO;
        [_audioEngine setRepeatMode:(val.boolValue ? SPRepeatContext : SPRepeatOff)];
        return YES;
    }
    if ([endpoint isEqualToString:@"set_repeating_track"]) {
        NSNumber *val = SPJSONNumber(cmd[@"value"]);
        if (!val) return NO;
        [_audioEngine setRepeatMode:(val.boolValue ? SPRepeatTrack : SPRepeatOff)];
        return YES;
    }
    if ([endpoint isEqualToString:@"set_options"]) {
        BOOL handled = NO;
        NSNumber *shuf = SPJSONNumber(cmd[@"shuffling_context"]);
        if (shuf) { [_audioEngine setShuffle:shuf.boolValue]; handled = YES; }
        NSNumber *repTrack = SPJSONNumber(cmd[@"repeating_track"]);
        NSNumber *repCtx = SPJSONNumber(cmd[@"repeating_context"]);
        if (repTrack || repCtx) {
            SPRepeatMode mode = SPRepeatOff;
            if (repTrack.boolValue) mode = SPRepeatTrack;
            else if (repCtx.boolValue) mode = SPRepeatContext;
            [_audioEngine setRepeatMode:mode];
            handled = YES;
        }
        return handled;
    }
    if ([endpoint isEqualToString:@"add_to_queue"]) {
        NSDictionary *trackDict = SPJSONDict(cmd[@"track"]);
        NSString *uri = SPJSONString(trackDict[@"uri"]);
        if (!uri.length) return NO;
        [_audioEngine enqueueTrackURI:uri];
        return YES;
    }
    if ([endpoint isEqualToString:@"set_volume"] || [endpoint isEqualToString:@"volume"] || (!endpoint.length && SPJSONNumber(cmd[@"volume"]) != nil)) {
        NSNumber *volNum = SPJSONNumber(cmd[@"volume"]) ?: SPJSONNumber(cmd[@"value"]);
        if (!volNum) return NO;
        NSInteger wire = MAX(0, MIN(65535, volNum.integerValue));
        NSInteger pct = (NSInteger)llround(((double)wire / 65535.0) * 100.0);
        [_audioEngine setVolumePercent:pct];
        return YES;
    }
    if ([endpoint isEqualToString:@"play"]) {
        NSDictionary *context = SPJSONDict(cmd[@"context"]);
        NSString *contextURI = SPJSONString(context[@"uri"]);
        NSDictionary *options = SPJSONDict(cmd[@"options"]);
        NSDictionary *skipTo = SPJSONDict(options[@"skip_to"]);
        NSString *trackURI = SPJSONString(skipTo[@"track_uri"]);
        NSInteger trackIndex = SPJSONInt(skipTo[@"track_index"], 0);

        NSDictionary *overrides = SPJSONDict(options[@"player_options_override"]);
        if (overrides) {
            NSNumber *shuf = SPJSONNumber(overrides[@"shuffling_context"]);
            if (shuf) [_audioEngine setShuffle:shuf.boolValue];
            NSNumber *repTrack = SPJSONNumber(overrides[@"repeating_track"]);
            NSNumber *repCtx = SPJSONNumber(overrides[@"repeating_context"]);
            if (repTrack || repCtx) {
                [_audioEngine setRepeatMode:(repTrack.boolValue ? SPRepeatTrack : (repCtx.boolValue ? SPRepeatContext : SPRepeatOff))];
            }
        }

        // Inline track list (e.g. `context.pages[].tracks[]`) when no resolvable context URI is given.
        NSMutableArray<NSString *> *inlineURIs = [NSMutableArray new];
        for (id rawPage in SPJSONArray(context[@"pages"]) ?: @[]) {
            NSDictionary *page = SPJSONDict(rawPage);
            for (id rawTrk in SPJSONArray(page[@"tracks"]) ?: @[]) {
                NSString *u = SPJSONString(SPJSONDict(rawTrk)[@"uri"]);
                if (u.length) [inlineURIs addObject:u];
            }
        }
        if (inlineURIs.count > 0 && !contextURI.length) {
            [_audioEngine playTrackURIs:inlineURIs completion:nil];
            return YES;
        }
        if (contextURI.length || trackURI.length) {
            [_audioEngine playTrackURI:(trackURI ?: @"") inContextURI:contextURI trackIndex:trackIndex completion:nil];
            return YES;
        }
        return NO;
    }
    if ([endpoint isEqualToString:@"transfer"]) {
        NSDictionary *data = SPJSONDict(cmd[@"data"]);
        NSDictionary *pb = SPJSONDict(data[@"playback"]);
        NSDictionary *curTrack = SPJSONDict(pb[@"current_track"]);
        NSString *trackURI = SPJSONString(curTrack[@"uri"]);
        NSString *contextURI = SPJSONString(SPJSONDict(data[@"context"])[@"uri"]);
        if (trackURI.length || contextURI.length) {
            [_audioEngine playTrackURI:(trackURI ?: @"") inContextURI:contextURI trackIndex:0 completion:nil];
        } else if (_store.playbackState.currentTrackURI.length) {
            [_audioEngine playTrackURI:_store.playbackState.currentTrackURI
                          inContextURI:_store.playbackState.contextURI
                            trackIndex:0
                            completion:nil];
        } else {
            [_audioEngine resume];
        }
        return YES;
    }
    return NO;
}

#pragma mark - SPAudioEngineDelegate

- (void)audioEngine:(id<SPAudioEngine>)engine didUpdatePlaybackState:(SPPlaybackState *)state {
    [self hydrateTracksForPlaybackState:state];
    SPTrack *track = state.currentTrackID.length ? [_store trackWithID:state.currentTrackID] : nil;
    [_mediaKeys updateNowPlayingWithState:state track:track];
    if (engine.kind == SPAudioEngineKindFairPlay && _connectClient.isConnected) {
        BOOL active = state.isPlaying || state.isPaused || state.currentTrackURI.length > 0;
        uint32_t wireVol = (uint32_t)llround(((double)MAX(0, MIN(100, engine.volumePercent)) / 100.0) * 65535.0);
        [_connectClient publishDeviceStateActive:active volume:wireVol playbackState:state completion:nil];
    }
}

- (void)audioEngine:(id<SPAudioEngine>)engine didChangeStatus:(SPAudioEngineStatus)status error:(NSError *)error {
    (void)error;
    SPAudioEnginePreference pref = (SPAudioEnginePreference)[NSUserDefaults.standardUserDefaults integerForKey:kSPEnginePrefKey];
    if (pref == SPAudioEnginePrefAuto && engine.kind == SPAudioEngineKindFairPlay && status == SPAudioEngineStatusFailed) {
        // Automatic FairPlay -> Soloist fallback when FairPlay license server rejects desktop tokens.
        [engine stop];
        SPSoloistEngine *solo = [[SPSoloistEngine alloc] initWithConnectClient:_connectClient netClient:_netClient store:_store];
        solo.executablePath = [SPSoloistEngine discoverExecutablePath];
        solo.soloistKey = _auth.session.soloistKey;
        solo.delegate = self;
        _audioEngine = solo;
        _shell.audioEngine = solo;
        _mediaKeys.engine = solo;
        _connectClient.canBePlayer = NO;
        _connectClient.hidden = YES;
        if (_connectClient.isConnected) {
            [_connectClient publishDeviceStateActive:NO volume:0 playbackState:nil completion:nil];
        }
        [solo startWithCompletion:nil];
        _prefsController.activeEngineKind = SPAudioEngineKindSoloist;
        _prefsController.soloistKeyMissingOrFailed = (_auth.session.soloistKey.length == 0);
        [_prefsController refreshState];
    } else if (engine.kind == SPAudioEngineKindSoloist && status == SPAudioEngineStatusFailed) {
        _prefsController.soloistKeyMissingOrFailed = YES;
        [_prefsController refreshState];
    }
}

#pragma mark - Menu Bar & Actions

- (NSMenu *)buildMainMenu {
    NSMenu *mainMenu = [NSMenu new];

    // 1. Spotify app menu
    NSMenuItem *appItem = [mainMenu addItemWithTitle:@"Spotify" action:nil keyEquivalent:@""];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"Spotify"];
    [appMenu addItemWithTitle:@"About Spotify" action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *prefsItem = [appMenu addItemWithTitle:@"Settings..." action:@selector(openPreferences:) keyEquivalent:@","];
    prefsItem.target = self;
    NSMenuItem *signOutItem = [appMenu addItemWithTitle:@"Sign Out" action:@selector(signOutAction:) keyEquivalent:@""];
    signOutItem.target = self;
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Hide Spotify" action:@selector(hide:) keyEquivalent:@"h"];
    NSMenuItem *hideOthers = [appMenu addItemWithTitle:@"Hide Others" action:@selector(hideOtherApplications:) keyEquivalent:@"h"];
    hideOthers.keyEquivalentModifierMask = NSEventModifierFlagOption | NSEventModifierFlagCommand;
    [appMenu addItemWithTitle:@"Show All" action:@selector(unhideAllApplications:) keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Quit Spotify" action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;

    // 2. Edit menu (standard first-responder wiring so Cmd+C / Cmd+V / Cmd+A / Cmd+Z work everywhere)
    NSMenuItem *editItem = [mainMenu addItemWithTitle:@"Edit" action:nil keyEquivalent:@""];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    [editMenu addItemWithTitle:@"Undo" action:@selector(undo:) keyEquivalent:@"z"];
    NSMenuItem *redo = [editMenu addItemWithTitle:@"Redo" action:@selector(redo:) keyEquivalent:@"Z"];
    redo.keyEquivalentModifierMask = NSEventModifierFlagShift | NSEventModifierFlagCommand;
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
    [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
    editItem.submenu = editMenu;

    // 3. View menu
    NSMenuItem *viewItem = [mainMenu addItemWithTitle:@"View" action:nil keyEquivalent:@""];
    NSMenu *viewMenu = [[NSMenu alloc] initWithTitle:@"View"];
    NSMenuItem *back = [viewMenu addItemWithTitle:@"Back" action:@selector(navBack:) keyEquivalent:@"["];
    back.target = self;
    NSMenuItem *fwd = [viewMenu addItemWithTitle:@"Forward" action:@selector(navForward:) keyEquivalent:@"]"];
    fwd.target = self;
    [viewMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *sK = [viewMenu addItemWithTitle:@"Search" action:@selector(focusSearch:) keyEquivalent:@"k"];
    sK.target = self;
    NSMenuItem *sL = [viewMenu addItemWithTitle:@"Focus Search Bar" action:@selector(focusSearch:) keyEquivalent:@"l"];
    sL.target = self;
    NSMenuItem *sF = [viewMenu addItemWithTitle:@"Find..." action:@selector(focusSearch:) keyEquivalent:@"f"];
    sF.target = self;
    [viewMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *home = [viewMenu addItemWithTitle:@"Startpage" action:@selector(navHome:) keyEquivalent:@"1"];
    home.target = self;
    NSMenuItem *qPage = [viewMenu addItemWithTitle:@"Queue" action:@selector(navQueue:) keyEquivalent:@"2"];
    qPage.target = self;
    NSMenuItem *spk = [viewMenu addItemWithTitle:@"Playing On" action:@selector(navSpeakers:) keyEquivalent:@"3"];
    spk.target = self;
    NSMenuItem *fav = [viewMenu addItemWithTitle:@"Favorites" action:@selector(navFavorites:) keyEquivalent:@"4"];
    fav.target = self;
    NSMenuItem *pl = [viewMenu addItemWithTitle:@"Playlists" action:@selector(navPlaylists:) keyEquivalent:@"5"];
    pl.target = self;
    NSMenuItem *alb = [viewMenu addItemWithTitle:@"Albums" action:@selector(navAlbums:) keyEquivalent:@"6"];
    alb.target = self;
    NSMenuItem *art = [viewMenu addItemWithTitle:@"Artists" action:@selector(navArtists:) keyEquivalent:@"7"];
    art.target = self;
    [viewMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *sbToggle = [viewMenu addItemWithTitle:@"Toggle Sidebar" action:@selector(toggleSidebarAction:) keyEquivalent:@"s"];
    sbToggle.keyEquivalentModifierMask = NSEventModifierFlagOption | NSEventModifierFlagCommand;
    sbToggle.target = self;
    NSMenuItem *qToggle = [viewMenu addItemWithTitle:@"Now Playing Inspector" action:@selector(toggleQueue:) keyEquivalent:@"I"];
    qToggle.keyEquivalentModifierMask = NSEventModifierFlagOption | NSEventModifierFlagCommand;
    qToggle.target = self;
    viewItem.submenu = viewMenu;

    // 4. Playback menu
    NSMenuItem *pbItem = [mainMenu addItemWithTitle:@"Playback" action:nil keyEquivalent:@""];
    NSMenu *pbMenu = [[NSMenu alloc] initWithTitle:@"Playback"];
    NSMenuItem *playPause = [pbMenu addItemWithTitle:@"Play / Pause" action:@selector(playbackToggle:) keyEquivalent:@""];
    playPause.target = self;
    NSMenuItem *next = [pbMenu addItemWithTitle:@"Next Track" action:@selector(playbackNext:) keyEquivalent:[NSString stringWithFormat:@"%C", (unichar)NSRightArrowFunctionKey]];
    next.target = self;
    NSMenuItem *prev = [pbMenu addItemWithTitle:@"Previous Track" action:@selector(playbackPrev:) keyEquivalent:[NSString stringWithFormat:@"%C", (unichar)NSLeftArrowFunctionKey]];
    prev.target = self;
    [pbMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *shuf = [pbMenu addItemWithTitle:@"Toggle Shuffle" action:@selector(playbackShuffle:) keyEquivalent:@"s"];
    shuf.target = self;
    NSMenuItem *rep = [pbMenu addItemWithTitle:@"Cycle Repeat" action:@selector(playbackRepeat:) keyEquivalent:@"r"];
    rep.target = self;
    [pbMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *volUp = [pbMenu addItemWithTitle:@"Volume Up" action:@selector(volumeUp:) keyEquivalent:[NSString stringWithFormat:@"%C", (unichar)NSUpArrowFunctionKey]];
    volUp.target = self;
    NSMenuItem *volDown = [pbMenu addItemWithTitle:@"Volume Down" action:@selector(volumeDown:) keyEquivalent:[NSString stringWithFormat:@"%C", (unichar)NSDownArrowFunctionKey]];
    volDown.target = self;
    NSMenuItem *mute = [pbMenu addItemWithTitle:@"Mute" action:@selector(volumeMute:) keyEquivalent:[NSString stringWithFormat:@"%C", (unichar)NSDownArrowFunctionKey]];
    mute.keyEquivalentModifierMask = NSEventModifierFlagOption | NSEventModifierFlagCommand;
    mute.target = self;
    pbItem.submenu = pbMenu;

    // 5. Window menu
    NSMenuItem *winItem = [mainMenu addItemWithTitle:@"Window" action:nil keyEquivalent:@""];
    NSMenu *winMenu = [[NSMenu alloc] initWithTitle:@"Window"];
    [winMenu addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
    [winMenu addItemWithTitle:@"Close Window" action:@selector(performClose:) keyEquivalent:@"w"];
    [winMenu addItemWithTitle:@"Zoom" action:@selector(performZoom:) keyEquivalent:@""];
    [winMenu addItem:[NSMenuItem separatorItem]];
    [winMenu addItemWithTitle:@"Bring All to Front" action:@selector(arrangeInFront:) keyEquivalent:@""];
    winItem.submenu = winMenu;
    NSApp.windowsMenu = winMenu;

    return mainMenu;
}

- (void)openPreferences:(id)sender {
    (void)sender;
    if (!_store) return;
    if (!_prefsController) {
        _prefsController = [[SPPreferencesWindowController alloc] initWithStore:_store];
        __weak typeof(self) weakSelf = self;
        _prefsController.onEnginePreferenceChange = ^(SPAudioEnginePreference pref) {
            [NSUserDefaults.standardUserDefaults setInteger:pref forKey:kSPEnginePrefKey];
            [weakSelf configureAudioEngineFromPreferences];
            SPAppController *s = weakSelf;
            if (!s) return;
            [s->_audioEngine startWithCompletion:nil];
            uint32_t wireVol = (uint32_t)llround(((double)MIN(100, MAX(0, s->_audioEngine.volumePercent)) / 100.0) * 65535.0);
            [s->_connectClient publishDeviceStateActive:NO volume:wireVol playbackState:nil completion:nil];
            s->_prefsController.activeEngineKind = s->_audioEngine.kind;
            s->_prefsController.soloistKeyMissingOrFailed = (pref == SPAudioEnginePrefSoloist && s->_auth.session.soloistKey.length == 0);
            [s->_prefsController refreshState];
        };
        _prefsController.onSaveSoloistKey = ^(NSString *key) {
            SPAppController *s = weakSelf;
            if (!s || !s->_auth.session) return;
            SPSessionBlob *updated = [s->_auth.session withSoloistKey:key];
            [s->_auth adoptSession:updated];
            SPSaveSessionBlobAsync(updated, s->_secretStore, nil);
            if ([s->_audioEngine isKindOfClass:SPSoloistEngine.class]) {
                ((SPSoloistEngine *)s->_audioEngine).soloistKey = key;
                [s->_audioEngine startWithCompletion:nil];
            }
        };
        _prefsController.onSongRadioToggle = ^(BOOL enabled) {
            [NSUserDefaults.standardUserDefaults setBool:enabled forKey:kSPSongRadioKey];
            weakSelf.shell.songRadioEnabled = enabled;
        };
        _prefsController.onSignOut = ^{
            [weakSelf signOutAction:nil];
        };
    }
    _prefsController.enginePreference = (SPAudioEnginePreference)[NSUserDefaults.standardUserDefaults integerForKey:kSPEnginePrefKey];
    _prefsController.activeEngineKind = _audioEngine.kind;
    _prefsController.songRadioEnabled = _shell.songRadioEnabled;
    _prefsController.soloistKeyValue = _auth.session.soloistKey;
    _prefsController.soloistKeyMissingOrFailed = (_prefsController.enginePreference == SPAudioEnginePrefSoloist && _auth.session.soloistKey.length == 0);
    [_prefsController refreshState];
    [_prefsController showWindow:nil];
    [_prefsController.window center];
    [_prefsController.window makeKeyAndOrderFront:nil];
}

- (void)signOutAction:(id)sender {
    (void)sender;
    _sessionGeneration++;
    [self cancelBootTokens];
    [_hydratingTrackIDs removeAllObjects];
    [_prefsController close];
    _prefsController = nil;
    [_mediaKeys deactivate];
    _mediaKeys = nil;
    [_audioEngine stop];
    _audioEngine = nil;
    [_connectClient disconnect];
    _connectClient = nil;
    [_shell closeWindowReleasingViews];
    _shell = nil;
    [_auth signOut];
    _auth = nil;
    _netClient = nil;
    [_store.database close];
    _store = nil;
    _bootedNetwork = NO;
    [self showSignInWindow];
}

- (BOOL)forwardTextNavigationIfEditing:(SEL)selector {
    if (NSApp.currentEvent.type != NSEventTypeKeyDown) return NO;
    NSResponder *fr = NSApp.keyWindow.firstResponder;
    if (![fr isKindOfClass:NSText.class]) return NO;
    if ([fr respondsToSelector:selector]) {
        [fr doCommandBySelector:selector];
    }
    return YES;
}

- (void)navBack:(id)sender { (void)sender; [_shell goBack]; }
- (void)navForward:(id)sender { (void)sender; [_shell goForward]; }
- (void)focusSearch:(id)sender { (void)sender; [_shell focusSearchFieldSelectingAll:YES]; }
- (void)navHome:(id)sender { (void)sender; if (!_shell.isWindowOpen) [_shell showWindow]; [_shell openHome]; }
- (void)navQueue:(id)sender { (void)sender; if (!_shell.isWindowOpen) [_shell showWindow]; [_shell openQueue]; }
- (void)navSpeakers:(id)sender { (void)sender; if (!_shell.isWindowOpen) [_shell showWindow]; [_shell openSpeakers]; }
- (void)navFavorites:(id)sender { (void)sender; if (!_shell.isWindowOpen) [_shell showWindow]; [_shell openFavorites]; }
- (void)navAlbums:(id)sender { (void)sender; if (!_shell.isWindowOpen) [_shell showWindow]; [_shell openAlbums]; }
- (void)navArtists:(id)sender { (void)sender; if (!_shell.isWindowOpen) [_shell showWindow]; [_shell openArtists]; }
- (void)navPlaylists:(id)sender { (void)sender; if (!_shell.isWindowOpen) [_shell showWindow]; [_shell openPlaylists]; }
- (void)toggleSidebarAction:(id)sender { (void)sender; if (!_shell.isWindowOpen) [_shell showWindow]; [_shell toggleSidebar]; }
- (void)toggleQueue:(id)sender { (void)sender; if (!_shell.isWindowOpen) [_shell showWindow]; [_shell toggleQueueDrawer]; }
- (void)playbackToggle:(id)sender { (void)sender; [_shell togglePlayPause]; }
- (void)playbackNext:(id)sender {
    (void)sender;
    if ([self forwardTextNavigationIfEditing:@selector(moveToEndOfLine:)]) return;
    [_shell skipNext];
}
- (void)playbackPrev:(id)sender {
    (void)sender;
    if ([self forwardTextNavigationIfEditing:@selector(moveToBeginningOfLine:)]) return;
    [_shell skipPrevious];
}
- (void)playbackShuffle:(id)sender { (void)sender; [_shell toggleShuffle]; }
- (void)playbackRepeat:(id)sender { (void)sender; [_shell cycleRepeatMode]; }
- (void)volumeUp:(id)sender {
    (void)sender;
    if ([self forwardTextNavigationIfEditing:@selector(moveToBeginningOfDocument:)]) return;
    [_shell adjustVolumeBy:10];
}
- (void)volumeDown:(id)sender {
    (void)sender;
    if ([self forwardTextNavigationIfEditing:@selector(moveToEndOfDocument:)]) return;
    [_shell adjustVolumeBy:-10];
}
- (void)volumeMute:(id)sender { (void)sender; [_shell toggleMute]; }

@end
