// Soloist fallback audio engine implementing SPAudioEngine.
#import "audio/soloist.h"
#import "model/json.h"

#import <AppKit/NSWorkspace.h>
#import <Network/Network.h>
#import <libproc.h>
#import <signal.h>
#import <unistd.h>

static NSString *const kSPSoloistVolumeKey = @"soloistVolume";
static NSString *const kSPSoloistExecutablePrefKey = @"sp.soloistExecutablePath";
static NSString *const kSPSoloistErrorDomain = @"local.spotify-native.soloist";

@implementation SPSoloistEngine {
    SPConnectClient *_connect;
    SPNetClient *_net;
    SPStore *_store;

    NSTask *_process;
    NSURLSessionWebSocketTask *_socket;
    nw_path_monitor_t _pathMonitor;
    id _wakeObserver;
    BOOL _hadUnsatisfiedPath;

    SPAudioEngineStatus _status;
    NSInteger _volumePercent;
    NSString *_soloistDeviceID;
    BOOL _networkReturnedSinceLaunch;
    NSInteger _restartsInARow;
    BOOL _wantRunning;
    uint64_t _launchGen;
    dispatch_group_t _stopGroup;
    uint64_t _playGeneration;
}

@synthesize delegate = _delegate;

+ (nullable NSString *)newestBinaryUnderBuildsDir:(NSString *)buildsDir {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:buildsDir error:nil];
    if (!entries.count) return nil;
    NSArray<NSString *> *sorted = [entries sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
    for (NSString *dir in [sorted reverseObjectEnumerator]) {
        NSString *candidate = [[buildsDir stringByAppendingPathComponent:dir] stringByAppendingPathComponent:@"soloist"];
        if ([fm isExecutableFileAtPath:candidate]) return candidate;
    }
    return nil;
}

+ (nullable NSString *)discoverExecutablePath {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *prefPath = [NSUserDefaults.standardUserDefaults stringForKey:kSPSoloistExecutablePrefKey];
    if (prefPath.length && [fm isExecutableFileAtPath:prefPath]) return prefPath;

    NSString *envPath = NSProcessInfo.processInfo.environment[@"SPOTIFY_NATIVE_SOLOIST_PATH"];
    if (envPath.length && [fm isExecutableFileAtPath:envPath]) return envPath;

    NSMutableArray<NSString *> *candidates = [NSMutableArray new];
    if (NSBundle.mainBundle.resourcePath.length) {
        [candidates addObject:[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"soloist"]];
    }
    if (NSBundle.mainBundle.executablePath.length) {
        [candidates addObject:[NSBundle.mainBundle.executablePath.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"soloist"]];
    }
    NSURL *support = [fm URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    if (support) {
        NSString *snRoot = [support URLByAppendingPathComponent:@"Spotify Native/Soloist" isDirectory:YES].path;
        NSString *sfRoot = [support URLByAppendingPathComponent:@"Spotifly/Soloist" isDirectory:YES].path;
        [candidates addObject:[snRoot stringByAppendingPathComponent:@"soloist"]];
        NSString *snBuild = [self newestBinaryUnderBuildsDir:[snRoot stringByAppendingPathComponent:@"builds"]];
        if (snBuild) [candidates addObject:snBuild];
        [candidates addObject:[sfRoot stringByAppendingPathComponent:@"soloist"]];
        NSString *sfBuild = [self newestBinaryUnderBuildsDir:[sfRoot stringByAppendingPathComponent:@"builds"]];
        if (sfBuild) [candidates addObject:sfBuild];
    }
    [candidates addObject:@"/opt/homebrew/bin/soloist"];
    [candidates addObject:@"/usr/local/bin/soloist"];

    for (NSString *path in candidates) {
        if (path.length && [fm isExecutableFileAtPath:path]) return path;
    }
    return nil;
}

- (instancetype)initWithConnectClient:(SPConnectClient *)connectClient
                            netClient:(SPNetClient *)netClient
                                store:(SPStore *)store {
    if (!(self = [super init])) return nil;
    _connect = connectClient;
    _net = netClient;
    _store = store;
    _deviceName = SPComputerDeviceName();
    _executablePath = [SPSoloistEngine discoverExecutablePath];
    _defaults = NSUserDefaults.standardUserDefaults;
    _status = SPAudioEngineStatusIdle;
    _stopGroup = dispatch_group_create();

    NSNumber *savedVol = [_defaults objectForKey:kSPSoloistVolumeKey];
    _volumePercent = savedVol ? MIN(100, MAX(0, savedVol.integerValue)) : 40;

    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *root = [support URLByAppendingPathComponent:@"Spotify Native/Soloist" isDirectory:YES];
    _dataDirectory = [root URLByAppendingPathComponent:@"data" isDirectory:YES].path;
    _cacheDirectory = [root URLByAppendingPathComponent:@"cache" isDirectory:YES].path;

    return self;
}

- (void)dealloc {
    _delegate = nil;
    [self stopMonitoringEnvironment];
    [self stop];
}

- (SPAudioEngineKind)kind { return SPAudioEngineKindSoloist; }
- (SPAudioEngineStatus)status { return _status; }
- (NSInteger)volumePercent { return _volumePercent; }
- (SPPlaybackState *)playbackState { return _store.playbackState; }
- (NSString *)soloistDeviceID { return _soloistDeviceID; }
- (BOOL)isProcessRunning { return _process != nil && _process.isRunning; }
- (BOOL)networkReturnedSinceLaunch { return _networkReturnedSinceLaunch; }

- (void)setDefaults:(NSUserDefaults *)defaults {
    _defaults = defaults ?: NSUserDefaults.standardUserDefaults;
    NSNumber *savedVol = [_defaults objectForKey:kSPSoloistVolumeKey];
    if (savedVol) {
        _volumePercent = MIN(100, MAX(0, savedVol.integerValue));
    }
}

+ (BOOL)shouldRestartForStatus:(SPAudioEngineStatus)status
                     isRunning:(BOOL)isRunning
               networkReturned:(BOOL)networkReturned {
    return status == SPAudioEngineStatusWaitingForPairing && isRunning && networkReturned;
}

- (void)setStatus:(SPAudioEngineStatus)status error:(NSError *)error {
    _status = status;
    if ([self.delegate respondsToSelector:@selector(audioEngine:didChangeStatus:error:)]) {
        [self.delegate audioEngine:self didChangeStatus:status error:error];
    }
}

- (void)startMonitoringEnvironment {
    if (!_wakeObserver) {
        __weak typeof(self) weakSelf = self;
        _wakeObserver = [NSWorkspace.sharedWorkspace.notificationCenter addObserverForName:NSWorkspaceDidWakeNotification
                                                                                    object:nil
                                                                                     queue:NSOperationQueue.mainQueue
                                                                                usingBlock:^(NSNotification *note) {
            (void)note;
            [weakSelf handleNetworkReturned];
        }];
    }
    if (!_pathMonitor) {
        _pathMonitor = nw_path_monitor_create();
        __weak typeof(self) weakSelf = self;
        nw_path_monitor_set_update_handler(_pathMonitor, ^(nw_path_t path) {
            nw_path_status_t st = nw_path_get_status(path);
            dispatch_async(dispatch_get_main_queue(), ^{
                SPSoloistEngine *strong = weakSelf;
                if (!strong) return;
                if (st != nw_path_status_satisfied) {
                    strong->_hadUnsatisfiedPath = YES;
                } else if (strong->_hadUnsatisfiedPath) {
                    strong->_hadUnsatisfiedPath = NO;
                    [strong handleNetworkReturned];
                }
            });
        });
        nw_path_monitor_set_queue(_pathMonitor, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
        nw_path_monitor_start(_pathMonitor);
    }
}

- (void)stopMonitoringEnvironment {
    if (_wakeObserver) {
        [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:_wakeObserver];
        _wakeObserver = nil;
    }
    if (_pathMonitor) {
        nw_path_monitor_cancel(_pathMonitor);
        _pathMonitor = nil;
    }
}

- (NSString *)pidFilePath {
    return [self.dataDirectory stringByAppendingPathComponent:@"soloist.pid"];
}

- (void)stopLeftoverChild {
    NSString *pidPath = [self pidFilePath];
    NSString *raw = [NSString stringWithContentsOfFile:pidPath encoding:NSUTF8StringEncoding error:nil];
    pid_t pid = (pid_t)[raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].intValue;
    if (pid > 1 && pid != getpid()) {
        char pathBuf[PROC_PIDPATHINFO_MAXSIZE];
        memset(pathBuf, 0, sizeof(pathBuf));
        if (proc_pidpath(pid, pathBuf, sizeof(pathBuf)) > 0) {
            NSString *procPath = @(pathBuf);
            if ([procPath rangeOfString:@"soloist" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                kill(pid, SIGTERM);
                for (int i = 0; i < 20; i++) {
                    if (kill(pid, 0) != 0) break;
                    usleep(50000);
                }
                if (kill(pid, 0) == 0) {
                    kill(pid, SIGKILL);
                }
            }
        }
    }
    [NSFileManager.defaultManager removeItemAtPath:pidPath error:nil];
}

- (void)startWithCompletion:(void (^)(NSError *))completion {
    if (_process && _process.isRunning) {
        if (completion) completion(nil);
        return;
    }
    if (!self.executablePath.length) {
        self.executablePath = [SPSoloistEngine discoverExecutablePath];
    }
    if (!self.executablePath.length || !self.soloistKey.length) {
        NSError *err = [NSError errorWithDomain:kSPSoloistErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey : @"Soloist executable or key not configured"}];
        [self setStatus:SPAudioEngineStatusFailed error:err];
        if (completion) completion(err);
        return;
    }

    _wantRunning = YES;
    uint64_t gen = ++_launchGen;
    [self startMonitoringEnvironment];
    [self setStatus:SPAudioEngineStatusStarting error:nil];

    __weak typeof(self) weakSelf = self;
    dispatch_group_notify(_stopGroup, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        SPSoloistEngine *prep = weakSelf;
        if (!prep) return;
        [prep stopLeftoverChild];
        dispatch_async(dispatch_get_main_queue(), ^{
            SPSoloistEngine *strong = weakSelf;
            if (!strong || !strong->_wantRunning || strong->_launchGen != gen) {
                if (completion) completion(nil);
                return;
            }
            [strong launchProcessForGeneration:gen completion:completion];
        });
    });
}

- (void)launchProcessForGeneration:(uint64_t)gen completion:(void (^)(NSError *))completion {
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *dir in @[ self.dataDirectory, self.cacheDirectory ]) {
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions : @(0700)} error:nil];
    }
    NSString *portFile = [self.dataDirectory stringByAppendingPathComponent:@"ws.port"];
    [fm removeItemAtPath:portFile error:nil];

    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:self.executablePath];
    task.arguments = @[
        @"-n", self.deviceName ?: SPComputerDeviceName(),
        @"-k", self.soloistKey,
        @"-D", self.dataDirectory,
        @"-C", self.cacheDirectory,
        @"-z", @"512",
        @"-w", @"127.0.0.1:0",
    ];
    task.standardInput = NSFileHandle.fileHandleWithNullDevice;
    __weak typeof(self) weakSelf = self;
    task.terminationHandler = ^(NSTask *ended) {
        int code = ended.terminationStatus;
        dispatch_async(dispatch_get_main_queue(), ^{
            SPSoloistEngine *strong = weakSelf;
            if (!strong || !strong->_wantRunning || strong->_launchGen != gen || strong->_process != ended) return;
            strong->_process = nil;
            [strong->_socket cancel];
            strong->_socket = nil;
            [NSFileManager.defaultManager removeItemAtPath:[strong pidFilePath] error:nil];
            strong->_restartsInARow++;
            if (strong->_restartsInARow > 5 || code == 10) {
                NSError *e = [NSError errorWithDomain:kSPSoloistErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey : @"Soloist process stopped"}];
                [strong setStatus:SPAudioEngineStatusFailed error:e];
                return;
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                SPSoloistEngine *retry = weakSelf;
                if (!retry || !retry->_wantRunning || retry->_launchGen != gen) return;
                [retry startWithCompletion:nil];
            });
        });
    };

    NSError *launchErr = nil;
    if (![task launchAndReturnError:&launchErr]) {
        [self setStatus:SPAudioEngineStatusFailed error:launchErr];
        if (completion) completion(launchErr);
        return;
    }
    _process = task;
    _networkReturnedSinceLaunch = NO;
    [[NSString stringWithFormat:@"%d\n", task.processIdentifier] writeToFile:[self pidFilePath]
                                                                  atomically:YES
                                                                    encoding:NSUTF8StringEncoding
                                                                       error:nil];

    NSString *dataDir = [self.dataDirectory copy];
    // Poll ws.port off the main thread for up to 10s, aborting promptly if stopped or superseded.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSInteger port = 0;
        for (int i = 0; i < 500; i++) {
            SPSoloistEngine *probe = weakSelf;
            if (!probe || !task.isRunning) break;
            NSString *txt = [NSString stringWithContentsOfFile:portFile encoding:NSUTF8StringEncoding error:nil];
            NSInteger p = [txt stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].integerValue;
            if (p > 0) { port = p; break; }
            usleep(20000);
        }
        NSString *devID = [[NSString stringWithContentsOfFile:[dataDir stringByAppendingPathComponent:@".device_id"]
                                                     encoding:NSUTF8StringEncoding
                                                        error:nil] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        dispatch_async(dispatch_get_main_queue(), ^{
            SPSoloistEngine *strong = weakSelf;
            if (!strong || !strong->_wantRunning || strong->_launchGen != gen || strong->_process != task) {
                return;
            }
            if (port <= 0) {
                NSError *e = [NSError errorWithDomain:kSPSoloistErrorDomain code:2 userInfo:@{NSLocalizedDescriptionKey : @"Soloist did not open loopback socket"}];
                [strong setStatus:SPAudioEngineStatusFailed error:e];
                if (completion) completion(e);
                return;
            }
            strong->_soloistDeviceID = devID.length ? devID : nil;
            NSURL *wsURL = [NSURL URLWithString:[NSString stringWithFormat:@"ws://127.0.0.1:%ld", (long)port]];
            NSURLSessionWebSocketTask *sock = [strong->_net.urlSession webSocketTaskWithURL:wsURL];
            sock.maximumMessageSize = 4 * 1024 * 1024;
            strong->_socket = sock;
            [sock resume];
            [strong receiveFromSocket:sock];
            if (completion) completion(nil);
        });
    });
}

- (void)receiveFromSocket:(NSURLSessionWebSocketTask *)sock {
    __weak typeof(self) weakSelf = self;
    [sock receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *msg, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            SPSoloistEngine *strong = weakSelf;
            if (!strong || strong->_socket != sock || err || !msg) return;
            NSData *raw = msg.type == NSURLSessionWebSocketMessageTypeString
                ? [msg.string dataUsingEncoding:NSUTF8StringEncoding]
                : msg.data;
            if (raw.length) [strong applySocketEventData:raw];
            [strong receiveFromSocket:sock];
        });
    }];
}

- (void)applySocketEventData:(NSData *)jsonData {
    NSDictionary *evt = SPJSONDict([NSJSONSerialization JSONObjectWithData:jsonData options:0 error:nil]);
    if (!evt) return;
    NSString *devID = SPJSONString(evt[@"device_id"]);
    if (devID.length) _soloistDeviceID = devID;
    NSNumber *volNum = SPJSONNumber(evt[@"volume"]);
    if (volNum) {
        _volumePercent = MIN(100, MAX(0, volNum.integerValue));
    }
    NSNumber *loggedInNum = SPJSONNumber(evt[@"logged_in"]);
    if (!loggedInNum) return;

    BOOL loggedIn = loggedInNum.boolValue;
    BOOL becomesReady = loggedIn && (_status != SPAudioEngineStatusReady && _status != SPAudioEngineStatusPlaying && _status != SPAudioEngineStatusPaused);
    [self setStatus:loggedIn ? SPAudioEngineStatusReady : SPAudioEngineStatusWaitingForPairing error:nil];

    if (loggedIn) {
        _restartsInARow = 0;
        if (becomesReady) {
            NSNumber *remembered = [_defaults objectForKey:kSPSoloistVolumeKey];
            if (remembered) {
                NSInteger pct = MIN(100, MAX(0, remembered.integerValue));
                _volumePercent = pct;
                [self sendSocketVolume:pct];
            }
        }
    } else {
        [self restartIfLoggedOutAfterNetworkReturn];
    }
}

- (void)handleNetworkReturned {
    _networkReturnedSinceLaunch = YES;
    [self restartIfLoggedOutAfterNetworkReturn];
}

- (void)restartIfLoggedOutAfterNetworkReturn {
    if (![SPSoloistEngine shouldRestartForStatus:_status
                                       isRunning:self.isProcessRunning
                                 networkReturned:_networkReturnedSinceLaunch]) {
        return;
    }
    [self stop];
    [self startWithCompletion:nil];
}

- (void)sendSocketVolume:(NSInteger)percent {
    if (!_socket) return;
    NSString *cmd = [NSString stringWithFormat:@"{\"type\":\"command\",\"command\":\"set_volume\",\"volume\":%ld}", (long)percent];
    [_socket sendMessage:[[NSURLSessionWebSocketMessage alloc] initWithString:cmd] completionHandler:^(NSError *err) { (void)err; }];
}

- (void)stop {
    _wantRunning = NO;
    _launchGen++;
    [_socket cancel];
    _socket = nil;
    NSString *pidPath = [self pidFilePath];
    if (_process) {
        NSTask *p = _process;
        _process = nil;
        pid_t pid = p.processIdentifier;
        [p terminate];
        dispatch_group_t grp = _stopGroup;
        dispatch_group_enter(grp);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            for (int i = 0; i < 20; i++) {
                if (!p.isRunning) break;
                usleep(50000);
            }
            if (p.isRunning && pid > 1) {
                kill(pid, SIGKILL);
            }
            [NSFileManager.defaultManager removeItemAtPath:pidPath error:nil];
            dispatch_group_leave(grp);
        });
    } else {
        [NSFileManager.defaultManager removeItemAtPath:pidPath error:nil];
    }
    [self setStatus:SPAudioEngineStatusIdle error:nil];
}

- (void)stopAndWait {
    [self stop];
    dispatch_group_wait(_stopGroup, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)));
}

#pragma mark - Target Device & Connect Playback Routing

- (BOOL)isLocalSoloistActive {
    if (!_store.activeDeviceID.length) return YES;
    return _soloistDeviceID.length > 0 && [_store.activeDeviceID isEqualToString:_soloistDeviceID];
}

- (NSString *)targetDeviceID {
    if (_store.activeDeviceID.length) {
        return _store.activeDeviceID;
    }
    return _soloistDeviceID;
}

- (void)playTrackURI:(NSString *)trackURI
        inContextURI:(NSString *)contextURI
          trackIndex:(NSInteger)trackIndex
          completion:(void (^)(NSError *))completion {
    NSString *target = [self targetDeviceID];
    if (!target.length) {
        if (completion) completion([NSError errorWithDomain:kSPSoloistErrorDomain code:3 userInfo:@{NSLocalizedDescriptionKey : @"No active Spotify Connect device"}]);
        return;
    }
    _playGeneration++;
    NSString *uri = contextURI.length ? contextURI : trackURI;
    [_connect playContextURI:uri
          startingAtTrackURI:trackURI
                  trackIndex:trackURI.length ? -1 : trackIndex
                  onDeviceID:target
                  completion:completion];
}

- (void)playTrackURIs:(NSArray<NSString *> *)trackURIs completion:(void (^)(NSError *))completion {
    NSString *target = [self targetDeviceID];
    if (!target.length || !trackURIs.count) {
        if (completion) completion(nil);
        return;
    }
    _playGeneration++;
    [_connect playTrackURIs:trackURIs onDeviceID:target completion:completion];
}

- (void)playTrackURIWithRadio:(NSString *)trackURI
                 fallbackURIs:(NSArray<NSString *> *)fallbackURIs
                   completion:(void (^)(NSError *))completion {
    if (!trackURI.length) { if (completion) completion(nil); return; }
    _playGeneration++;
    uint64_t gen = _playGeneration;
    NSArray<NSString *> *fallbackCopy = [fallbackURIs copy];
    [_net fetchRadioSeedForTrackURI:trackURI deviceID:_connect.deviceID completion:^(NSArray<NSString *> *radioURIs, NSError *err) {
        (void)err;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self->_playGeneration != gen) { if (completion) completion(nil); return; }
            NSArray<NSString *> *combined = SPTrackWithRecommendations(trackURI, radioURIs, fallbackCopy);
            NSString *target = [self targetDeviceID];
            if (!target.length) {
                if (completion) completion([NSError errorWithDomain:kSPSoloistErrorDomain code:3 userInfo:@{NSLocalizedDescriptionKey : @"No target device"}]);
                return;
            }
            [self->_connect playTrackURIs:combined onDeviceID:target completion:completion];
        });
    }];
}

- (void)pause {
    NSString *target = [self targetDeviceID];
    if (target.length) [_connect pauseOnDeviceID:target completion:nil];
}

- (void)resume {
    NSString *target = [self targetDeviceID];
    if (target.length) [_connect resumeOnDeviceID:target completion:nil];
}

- (void)togglePlayPause {
    if (_store.playbackState.isPlaying) [self pause];
    else [self resume];
}

- (void)skipNext {
    NSString *target = [self targetDeviceID];
    if (target.length) [_connect skipNextOnDeviceID:target completion:nil];
}

- (void)skipPrevious {
    NSString *target = [self targetDeviceID];
    if (target.length) [_connect skipPrevOnDeviceID:target completion:nil];
}

- (void)seekToMs:(int64_t)positionMs {
    NSString *target = [self targetDeviceID];
    if (target.length) [_connect seekToMs:positionMs onDeviceID:target completion:nil];
}

- (void)setVolumePercent:(NSInteger)percent {
    NSInteger clamped = MIN(100, MAX(0, percent));
    _volumePercent = clamped;
    BOOL localActive = [self isLocalSoloistActive];
    if (localActive) {
        [_defaults setInteger:clamped forKey:kSPSoloistVolumeKey];
    }
    if (localActive && _socket) {
        [self sendSocketVolume:clamped];
    } else {
        NSString *target = [self targetDeviceID];
        if (target.length) [_connect setVolumePercent:clamped onDeviceID:target completion:nil];
    }
}

- (void)setShuffle:(BOOL)enabled {
    NSString *target = [self targetDeviceID];
    if (target.length) [_connect setShuffle:enabled onDeviceID:target completion:nil];
}

- (void)setRepeatMode:(SPRepeatMode)mode {
    NSString *target = [self targetDeviceID];
    if (target.length) [_connect setRepeatMode:mode onDeviceID:target completion:nil];
}

- (void)enqueueTrackURI:(NSString *)trackURI {
    NSString *target = [self targetDeviceID];
    if (target.length && trackURI.length) [_connect addToQueueTrackURI:trackURI onDeviceID:target completion:nil];
}

- (void)skipToQueueIndex:(NSInteger)queueIndex {
    NSString *target = [self targetDeviceID];
    NSArray<SPQueueTrack *> *nextTracks = _store.playbackState.nextTracks;
    if (!target.length || queueIndex < 0 || queueIndex >= (NSInteger)nextTracks.count) return;
    SPQueueTrack *qt = nextTracks[(NSUInteger)queueIndex];
    if (!qt.uri.length) return;
    [_connect skipNextToTrackURI:qt.uri uid:qt.uid onDeviceID:target completion:nil];
}

@end
