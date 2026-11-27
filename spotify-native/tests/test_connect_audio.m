// Spotify Connect dealer WS + connect-state REST, FairPlay engine, Soloist engine, and MediaKeys tests.
#import "test.h"
#import "mockserver.h"
#import "app/app.h"
#import "audio/engine.h"
#import "audio/fairplay.h"
#import "audio/mediakeys.h"
#import "audio/soloist.h"
#import "auth/auth.h"
#import "connect/connect.h"
#import "model/protobuf.h"
#import "net/client.h"
#import "store/store.h"

#import <MediaPlayer/MediaPlayer.h>
#import <zlib.h>

static NSData *GzipCompress(NSData *raw) {
    z_stream zs;
    memset(&zs, 0, sizeof(zs));
    if (deflateInit2(&zs, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 16 + MAX_WBITS, 8, Z_DEFAULT_STRATEGY) != Z_OK) return nil;
    zs.next_in = (Bytef *)raw.bytes;
    zs.avail_in = (uInt)raw.length;
    NSMutableData *out = [NSMutableData dataWithCapacity:raw.length + 64];
    uint8_t buf[4096];
    int rc = Z_OK;
    while (rc == Z_OK) {
        zs.next_out = buf;
        zs.avail_out = sizeof(buf);
        rc = deflate(&zs, Z_FINISH);
        size_t produced = sizeof(buf) - zs.avail_out;
        if (produced > 0) [out appendBytes:buf length:produced];
    }
    deflateEnd(&zs);
    return rc == Z_STREAM_END ? out : nil;
}

static NSData *BuildTestClusterUpdate(NSString *activeID, NSString *deviceName, NSString *trackURI, BOOL playing) {
    return [SPProtobufWriter messageWithBlock:^(SPProtobufWriter *upd) {
        [upd writeMessageField:1 block:^(SPProtobufWriter *cl) {
            [cl writeString:activeID field:2];
            [cl writeMessageField:3 block:^(SPProtobufWriter *ps) {
                [ps writeVarint:1700000000000ULL field:1];
                [ps writeMessageField:7 block:^(SPProtobufWriter *tr) {
                    [tr writeString:trackURI field:1];
                    [tr writeString:@"u1" field:2];
                }];
                [ps writeVarint:12000 field:10];
                [ps writeVarint:210000 field:11];
                [ps writeBool:playing field:12];
                [ps writeBool:!playing field:13];
            }];
            [cl writeMessageField:4 block:^(SPProtobufWriter *entry) {
                [entry writeString:activeID field:1];
                [entry writeMessageField:2 block:^(SPProtobufWriter *di) {
                    [di writeBool:YES field:1];
                    [di writeVarint:49151 field:2]; // 75%
                    [di writeString:deviceName field:3];
                    [di writeVarint:SPDeviceTypeComputer field:7];
                    [di writeString:activeID field:10];
                }];
            }];
        }];
    }];
}

@interface SPTestConnectDelegate : NSObject <SPConnectClientDelegate>
@property (nonatomic, strong) NSMutableArray<SPClusterState *> *clusters;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *connEvents;
@end

@implementation SPTestConnectDelegate
- (instancetype)init {
    if (!(self = [super init])) return nil;
    _clusters = [NSMutableArray new];
    _connEvents = [NSMutableArray new];
    return self;
}
- (void)connectClient:(SPConnectClient *)client didUpdateCluster:(SPClusterState *)cluster {
    (void)client;
    [_clusters addObject:cluster];
}
- (void)connectClient:(SPConnectClient *)client didChangeConnected:(BOOL)connected {
    (void)client;
    [_connEvents addObject:@(connected)];
}
@end

SP_TEST(ConnectDealerWebSocketPutStateGzipClusterAndCommands) {
    SPExpect(SPComputerDeviceName().length > 0, @"computer device name non-empty");

    // Gzip round-trip helper check.
    NSData *sample = [@"spotify-connect-gzip-payload-0123456789" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *gz = GzipCompress(sample);
    SPExpect([SPGunzipData(gz) isEqualToData:sample], @"SPGunzipData round-trips gzip");
    SPExpect([SPGunzipData(sample) isEqualToData:sample], @"SPGunzipData passes through uncompressed bytes");

    SPMockWebSocketServer *wsServer = [SPMockWebSocketServer new];
    SPMockHTTPServer *httpServer = [SPMockHTTPServer new];
    SPExpect([wsServer start] && [httpServer start], @"mock dealer WS & connect-state HTTP started");

    __block NSString *receivedConnID = nil;
    __block NSData *receivedPutStatePB = nil;
    __block NSMutableArray<SPMockRequest *> *cmdRequests = [NSMutableArray new];

    NSData *putStateReplyCluster = [SPProtobufWriter messageWithBlock:^(SPProtobufWriter *cl) {
        [cl writeString:@"dev-remote" field:2];
        [cl writeMessageField:4 block:^(SPProtobufWriter *entry) {
            [entry writeString:@"dev-remote" field:1];
            [entry writeMessageField:2 block:^(SPProtobufWriter *di) {
                [di writeBool:YES field:1];
                [di writeVarint:32768 field:2];
                [di writeString:@"Kitchen Speaker" field:3];
                [di writeVarint:SPDeviceTypeSpeaker field:6];
                [di writeString:@"dev-remote" field:10];
            }];
        }];
    }];

    httpServer.handler = ^SPMockResponse *(SPMockRequest *req) {
        if ([req.method isEqualToString:@"PUT"] && [req.path hasPrefix:@"/connect-state/v1/devices/"]) {
            receivedConnID = req.headers[@"x-spotify-connection-id"];
            receivedPutStatePB = req.body;
            return [SPMockResponse responseWithStatus:200 contentType:@"application/x-protobuf" data:putStateReplyCluster];
        }
        if ([req.path hasPrefix:@"/connect-state/v1/connect/"] || [req.path hasPrefix:@"/connect-state/v1/player/"]) {
            @synchronized(cmdRequests) { [cmdRequests addObject:req]; }
            return [SPMockResponse responseWithStatus:200 json:@{@"ack_id" : @"ack-1"}];
        }
        return [SPMockResponse responseWithStatus:404 json:@{}];
    };

    SPSessionBlob *sess = [[SPSessionBlob alloc] initWithAccessToken:@"ws-bearer-token"
                                                        refreshToken:@"ref"
                                                accessTokenExpiresAt:NSDate.date.timeIntervalSince1970 + 3600.0
                                                            username:@"davi"
                                                            deviceID:@"0123456789abcdef0123456789abcdef01234567"
                                                         clientToken:@"ct-live"
                                                clientTokenExpiresAt:NSDate.date.timeIntervalSince1970 + 3600.0
                                                          soloistKey:nil];
    SPAuth *auth = [[SPAuth alloc] initWithSecretStore:[SPMemorySecretStore new] session:sess urlSession:nil];
    SPNetClient *net = [[SPNetClient alloc] initWithAuth:auth];
    net.spclientBaseURL = httpServer.baseURL;
    net.retryDelays = @[];
    SPStore *store = [[SPStore alloc] initWithDatabase:nil];

    SPConnectClient *connect = [[SPConnectClient alloc] initWithAuth:auth netClient:net store:store];
    connect.dealerWebSocketURL = wsServer.wsURL;
    connect.deviceName = @"Davi's MacBook";
    connect.canBePlayer = YES;
    connect.hidden = NO;
    connect.pingInterval = 60.0;
    connect.heartbeatInterval = 60.0;

    SPTestConnectDelegate *del = [SPTestConnectDelegate new];
    connect.delegate = del;
    [connect connect];

    SPExpect(SPWaitUntil(3.0, ^BOOL { return wsServer.hasClient; }), @"dealer WebSocket connected");
    SPExpect([wsServer.lastRequestPath containsString:@"access_token=ws-bearer-token"], @"access_token passed in WS URL");

    // 1. Server sends connection_id -> client automatically PUTs connect-state device registration.
    [wsServer sendTextFrame:@"{\"type\":\"message\",\"uri\":\"hm://pusher/v1/connections/\",\"headers\":{\"Spotify-Connection-Id\":\"conn-xyz-123\"}}"];
    SPExpect(SPWaitUntil(3.0, ^BOOL {
        return receivedPutStatePB.length > 0 && store.devices.count == 1;
    }), @"PutState sent automatically with connection ID and initial cluster adopted");
    SPExpectEqualStr(receivedConnID, @"conn-xyz-123", "X-Spotify-Connection-Id header sent");
    SPExpectEqualStr(store.devices[0].name, @"Kitchen Speaker", "initial PutState cluster updated store");

    // Verify encoded PutState protobuf carries our device name & COMPUTER type.
    NSData *deviceMsg = SPProtobufFirstBytes(receivedPutStatePB, 2);
    NSData *deviceInfoPB = SPProtobufFirstBytes(deviceMsg, 1);
    SPExpectEqualStr(SPProtobufFirstString(deviceInfoPB, 3), @"Davi's MacBook", "PutState carries Mac name");
    uint64_t devType = 0;
    SPExpect(SPProtobufFirstVarint(deviceInfoPB, 7, &devType) && devType == SPDeviceTypeComputer, @"PutState registers as COMPUTER");

    // 2. Server sends JSON ping -> client responds with JSON pong text frame.
    [wsServer sendTextFrame:@"{\"type\":\"ping\"}"];
    SPExpect(SPWaitUntil(2.0, ^BOOL {
        for (NSString *f in wsServer.receivedTextFrames) {
            if ([f containsString:@"\"pong\""]) return YES;
        }
        return NO;
    }), @"dealer JSON ping answered with text pong");

    // 3. Server pushes gzipped base64 ClusterUpdate protobuf -> store updates playback & devices.
    NSData *cuPB = BuildTestClusterUpdate(@"dev-mac-2", @"Studio Mac", @"spotify:track:4cOdK2wGLETKBW3PvgPWqT", YES);
    NSString *cuB64 = [GzipCompress(cuPB) base64EncodedStringWithOptions:0];
    NSString *clusterFrame = [NSString stringWithFormat:
        @"{\"type\":\"message\",\"uri\":\"hm://connect-state/v1/cluster\",\"headers\":{\"Transfer-Encoding\":\"gzip\"},\"payloads\":[\"%@\"]}",
        cuB64];
    [wsServer sendTextFrame:clusterFrame];
    SPExpect(SPWaitUntil(2.0, ^BOOL {
        return [store.activeDeviceID isEqualToString:@"dev-mac-2"] && store.playbackState.isPlaying;
    }), @"gzipped ClusterUpdate decoded and applied to store");
    SPExpectEqualStr(store.playbackState.currentTrackID, @"4cOdK2wGLETKBW3PvgPWqT", "cluster track updated");

    // 4. Server sends request -> client acknowledges with text reply frame.
    [wsServer sendTextFrame:@"{\"type\":\"request\",\"key\":\"req-key-7\",\"message_ident\":\"hm://connect-state/v1/player/command\",\"payload\":{\"endpoint\":\"pause\"}}"];
    SPExpect(SPWaitUntil(2.0, ^BOOL {
        for (NSString *f in wsServer.receivedTextFrames) {
            if ([f containsString:@"\"reply\""] && [f containsString:@"req-key-7"]) return YES;
        }
        return NO;
    }), @"dealer request acknowledged with text reply frame");

    // 5. Connect-state REST commands: transfer, volume (0..65535), pause, seek, playTrackURIs.
    __block int doneCmds = 0;
    [connect transferPlaybackToDeviceID:@"dev-mac-2" completion:^(NSError *e) { if (!e) doneCmds++; }];
    [connect setVolumePercent:50 onDeviceID:@"dev-mac-2" completion:^(NSError *e) { if (!e) doneCmds++; }];
    [connect pauseOnDeviceID:@"dev-mac-2" completion:^(NSError *e) { if (!e) doneCmds++; }];
    [connect seekToMs:42000 onDeviceID:@"dev-mac-2" completion:^(NSError *e) { if (!e) doneCmds++; }];
    [connect playTrackURIs:@[ @"spotify:track:a", @"spotify:track:b" ] onDeviceID:@"dev-mac-2" completion:^(NSError *e) { if (!e) doneCmds++; }];
    SPExpect(SPWaitUntil(3.0, ^BOOL { return doneCmds == 5; }), @"all 5 connect-state REST commands succeeded");

    BOOL sawTransfer = NO, sawVolume = NO, sawPauseEnvelope = NO, sawSeek = NO, sawPlayList = NO;
    @synchronized(cmdRequests) {
        for (SPMockRequest *r in cmdRequests) {
            if ([r.path containsString:@"/connect/transfer/"] && [r.method isEqualToString:@"POST"]) sawTransfer = YES;
            if ([r.path containsString:@"/connect/volume/"] && [r.method isEqualToString:@"PUT"]) {
                NSInteger vol = [r.jsonBody[@"volume"] integerValue];
                if (vol == 32768) sawVolume = YES;
            }
            NSDictionary *cmd = r.jsonBody[@"command"];
            NSDictionary *ctx = cmd[@"context"];
            if ([cmd[@"endpoint"] isEqualToString:@"pause"]) sawPauseEnvelope = YES;
            if ([cmd[@"endpoint"] isEqualToString:@"seek_to"] && [cmd[@"value"] longLongValue] == 42000) sawSeek = YES;
            if ([cmd[@"endpoint"] isEqualToString:@"play"] && ctx[@"pages"]) sawPlayList = YES;
        }
    }
    SPExpect(sawTransfer && sawVolume && sawPauseEnvelope && sawSeek && sawPlayList,
             @"connect-state REST transfer/volume/command envelopes verified (t=%d v=%d p=%d s=%d pl=%d)",
             sawTransfer, sawVolume, sawPauseEnvelope, sawSeek, sawPlayList);

    [connect disconnect];
    [wsServer stop];
    [httpServer stop];
}

SP_TEST(FairPlaySelectCBCSManifestAndOfflineSPC) {
    // 1. CBCS format preference: MP4_256_CBCS (15) beats MP4_128_CBCS (14).
    NSDictionary *meta = @{
        @"file" : @[
            @{@"file_id" : @"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", @"format" : @"OGG_VORBIS_320"},
            @{@"file_id" : @"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", @"format" : @"MP4_128_CBCS"},
            @{@"file_id" : @"cccccccccccccccccccccccccccccccccccccccc", @"format" : @"MP4_256_CBCS"},
        ],
    };
    NSString *fid = nil;
    NSInteger fmt = 0;
    SPExpect(SPFairPlaySelectCBCSFile(meta, &fid, &fmt), @"CBCS file selected");
    SPExpectEqualStr(fid, @"cccccccccccccccccccccccccccccccccccccccc", "MP4_256_CBCS chosen over MP4_128_CBCS");
    SPExpectEqualInt(fmt, 15, "format code 15 for MP4_256_CBCS");

    // 2. HLS v6 VOD manifest builder handles both dict and array segment shapes.
    NSDictionary *stDict = @{
        @"offset" : @1024,
        @"timescale" : @44100,
        @"segments" : @[ @{@"size" : @16000, @"duration" : @220500}, @{@"size" : @18000, @"duration" : @220500} ],
    };
    NSError *err = nil;
    NSString *m1 = SPFairPlayBuildHLSManifest(fid, @"https://audio.example/file.mp4", stDict, &err);
    SPExpect(m1 != nil && err == nil, @"HLS manifest built from dict segments");
    SPExpect([m1 containsString:@"#EXT-X-VERSION:6"], @"HLS version 6");
    SPExpect([m1 containsString:@"METHOD=SAMPLE-AES"], @"CBCS SAMPLE-AES key");
    SPExpect([m1 containsString:@"skd://cccccccccccccccccccccccccccccccccccccccc"], @"skd URI matches fileID");
    SPExpect([m1 containsString:@"BYTERANGE=\"1024@0\""], @"init map byte range");
    SPExpect([m1 containsString:@"#EXT-X-BYTERANGE:16000@1024"], @"segment 0 byte range");
    SPExpect([m1 containsString:@"#EXT-X-BYTERANGE:18000@17024"], @"segment 1 byte range");

    NSDictionary *stArr = @{@"offset" : @512, @"timescale" : @48000, @"segments" : @[ @[ @8000, @96000 ] ]};
    NSString *m2 = SPFairPlayBuildHLSManifest(fid, @"https://audio.example/file.mp4", stArr, &err);
    SPExpect(m2 != nil && [m2 containsString:@"#EXT-X-BYTERANGE:8000@512"], @"HLS manifest built from array segments");

    // 3. Offline FairPlay SPC generation via macOS AVContentKeySession for both UTF-8 and UTF-16LE.
    NSString *certPath = [SPTestRepoRoot() stringByAppendingPathComponent:@"tests/fixtures/fairplay-cert.der"];
    NSData *certDER = [NSData dataWithContentsOfFile:certPath];
    SPExpect(certDER.length > 500, @"offline FairPlay cert fixture loaded");
    NSData *spc8 = SPFairPlayGenerateOfflineSPC(certDER, fid, NO, &err);
    SPExpect(spc8.length > 100 && err == nil, @"offline UTF-8 SPC generated (%lu bytes)", (unsigned long)spc8.length);
    NSData *spc16 = SPFairPlayGenerateOfflineSPC(certDER, fid, YES, &err);
    SPExpect(spc16.length > 100 && err == nil, @"offline UTF-16LE SPC generated (%lu bytes)", (unsigned long)spc16.length);

    // 4. Harmony track-playback/v1/media CBCS manifest format (string "15"/"14" format IDs) + UTF-8 default.
    NSDictionary *tpEntry = @{
        @"item" : @{
            @"manifest" : @{
                @"file_ids_mp4_cbcs" : @[
                    @{@"file_id" : @"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", @"format" : @"14", @"bitrate" : @128000},
                    @{@"file_id" : @"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", @"format" : @"15", @"bitrate" : @256000},
                ],
            },
        },
    };
    NSString *tpFID = nil;
    NSInteger tpFmt = 0;
    SPExpect(SPFairPlaySelectCBCSFile(tpEntry, &tpFID, &tpFmt), @"selects CBCS file from track-playback/v1/media manifest");
    SPExpectEqualStr(tpFID, @"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "prefers 256kbps (format \"15\") over 128kbps");
    SPExpectEqualInt(tpFmt, 15, "parsed string format \"15\" to integer 15");
    SPAuth *tmpAuth = [[SPAuth alloc] initWithSecretStore:[SPMemorySecretStore new]];
    SPNetClient *tmpNet = [[SPNetClient alloc] initWithAuth:tmpAuth];
    SPStore *tmpStore = [[SPStore alloc] initWithDatabase:nil];
    SPFairPlayEngine *defaultEng = [[SPFairPlayEngine alloc] initWithNetClient:tmpNet store:tmpStore];
    SPExpect(!defaultEng.useUTF16LEAssetID, @"FairPlay engine defaults to UTF-8 contentIdentifier (verified live 200 OK)");
}

SP_TEST(FairPlayEngineDryRunAndSongRadioContinuation) {
    // Pure radio continuation helper: clicked track first, deduplicated radio after, fallback when empty.
    NSArray<NSString *> *withRadio = SPTrackWithRecommendations(@"spotify:track:seed",
                                                                @[ @"spotify:track:seed", @"spotify:track:r1", @"spotify:track:r2", @"spotify:track:r1" ],
                                                                @[ @"spotify:track:fb1" ]);
    SPExpectEqualInt(withRadio.count, 3, "clicked + 2 unique radio tracks");
    SPExpectEqualStr(withRadio[0], @"spotify:track:seed", "clicked track plays first");
    SPExpectEqualStr(withRadio[1], @"spotify:track:r1", "radio track 1 follows");

    NSArray<NSString *> *withFallback = SPTrackWithRecommendations(@"spotify:track:seed", @[], @[ @"spotify:track:seed", @"spotify:track:fb1" ]);
    SPExpectEqualInt(withFallback.count, 2, "fallback used when radio empty");
    SPExpectEqualStr(withFallback[1], @"spotify:track:fb1", "fallback track follows clicked track");

    SPMockHTTPServer *server = [SPMockHTTPServer new];
    SPExpect([server start], @"mock radio server started");
    server.handler = ^SPMockResponse *(SPMockRequest *req) {
        if ([req.path hasPrefix:@"/context-resolve/v1/spotify%3Astation%3Atrack%3A"]) {
            return [SPMockResponse responseWithStatus:200 json:@{
                @"pages" : @[ @{@"tracks" : @[ @{@"uri" : @"spotify:track:radioA"}, @{@"uri" : @"spotify:track:radioB"} ]} ],
            }];
        }
        return [SPMockResponse responseWithStatus:404 json:@{}];
    };

    SPSessionBlob *sess = [[SPSessionBlob alloc] initWithAccessToken:@"t" refreshToken:@"r"
                                                accessTokenExpiresAt:NSDate.date.timeIntervalSince1970 + 3600.0
                                                            username:@"davi" deviceID:[SPPKCE generateDeviceID]
                                                         clientToken:@"ct"
                                                clientTokenExpiresAt:NSDate.date.timeIntervalSince1970 + 3600.0
                                                          soloistKey:nil];
    SPAuth *auth = [[SPAuth alloc] initWithSecretStore:[SPMemorySecretStore new] session:sess urlSession:nil];
    SPNetClient *net = [[SPNetClient alloc] initWithAuth:auth];
    net.spclientBaseURL = server.baseURL;
    net.retryDelays = @[];
    SPStore *store = [[SPStore alloc] initWithDatabase:nil];

    SPFairPlayEngine *engine = [[SPFairPlayEngine alloc] initWithNetClient:net store:store];
    engine.dryRunMode = YES;
    SPExpectEqualInt(engine.kind, SPAudioEngineKindFairPlay, "FairPlay engine kind");

    __block BOOL started = NO;
    [engine startWithCompletion:^(NSError *e) { if (!e) started = YES; }];
    SPExpect(started && engine.status == SPAudioEngineStatusReady, @"FairPlay engine started in dry-run");

    __block BOOL played = NO;
    [engine playTrackURIWithRadio:@"spotify:track:4cOdK2wGLETKBW3PvgPWqT"
                     fallbackURIs:@[ @"spotify:track:fb" ]
                       completion:^(NSError *e) { if (!e) played = YES; }];
    SPExpect(SPWaitUntil(2.0, ^BOOL { return played; }), @"playTrackURIWithRadio completed");
    SPExpectEqualInt(engine.status, SPAudioEngineStatusPlaying, "engine playing");
    SPExpectEqualInt(engine.queueURIs.count, 3, "clicked search track + 2 Song Radio tracks queued");
    SPExpectEqualStr(engine.queueURIs[0], @"spotify:track:4cOdK2wGLETKBW3PvgPWqT", "clicked track is index 0");
    SPExpectEqualStr(store.playbackState.currentTrackURI, @"spotify:track:4cOdK2wGLETKBW3PvgPWqT", "store playback state updated");

    [engine enqueueTrackURI:@"spotify:track:upnext"];
    [engine skipNext];
    SPExpectEqualStr(store.playbackState.currentTrackURI, @"spotify:track:upnext", "user-queued track plays next");
    [engine pause];
    SPExpectEqualInt(engine.status, SPAudioEngineStatusPaused, "engine paused");
    [engine resume];
    SPExpectEqualInt(engine.status, SPAudioEngineStatusPlaying, "engine resumed");
    [engine setVolumePercent:72];
    SPExpectEqualInt(engine.volumePercent, 72, "volume updated");

    [engine stop];
    [server stop];
}

SP_TEST(SoloistEngineProtocolVolumePersistenceNetworkRestartAndRadio) {
    SPMockHTTPServer *server = [SPMockHTTPServer new];
    SPExpect([server start], @"mock soloist connect-state server started");
    __block NSArray<NSString *> *playedURIs = nil;
    server.handler = ^SPMockResponse *(SPMockRequest *req) {
        if ([req.path hasPrefix:@"/context-resolve/v1/spotify%3Astation%3Atrack%3A"]) {
            return [SPMockResponse responseWithStatus:200 json:@{
                @"pages" : @[ @{@"tracks" : @[ @{@"uri" : @"spotify:track:solRad1"} ]} ],
            }];
        }
        if ([req.path hasPrefix:@"/connect-state/v1/player/command/"]) {
            NSDictionary *cmd = req.jsonBody[@"command"];
            NSDictionary *ctx = cmd[@"context"];
            NSArray *pages = ctx[@"pages"];
            NSArray *tracks = [pages.firstObject objectForKey:@"tracks"];
            NSMutableArray *uris = [NSMutableArray new];
            for (NSDictionary *t in tracks) [uris addObject:t[@"uri"]];
            playedURIs = uris;
            return [SPMockResponse responseWithStatus:200 json:@{@"ack_id" : @"ok"}];
        }
        return [SPMockResponse responseWithStatus:200 json:@{}];
    };

    SPSessionBlob *sess = [[SPSessionBlob alloc] initWithAccessToken:@"t" refreshToken:@"r"
                                                accessTokenExpiresAt:NSDate.date.timeIntervalSince1970 + 3600.0
                                                            username:@"davi" deviceID:[SPPKCE generateDeviceID]
                                                         clientToken:@"ct"
                                                clientTokenExpiresAt:NSDate.date.timeIntervalSince1970 + 3600.0
                                                          soloistKey:nil];
    SPAuth *auth = [[SPAuth alloc] initWithSecretStore:[SPMemorySecretStore new] session:sess urlSession:nil];
    SPNetClient *net = [[SPNetClient alloc] initWithAuth:auth];
    net.spclientBaseURL = server.baseURL;
    net.retryDelays = @[];
    SPStore *store = [[SPStore alloc] initWithDatabase:nil];
    SPConnectClient *connect = [[SPConnectClient alloc] initWithAuth:auth netClient:net store:store];

    // Isolated NSUserDefaults suite so tests never touch standard defaults.
    NSString *suite = [NSString stringWithFormat:@"local.spotify-native.test.%@", NSUUID.UUID.UUIDString];
    NSUserDefaults *defs = [[NSUserDefaults alloc] initWithSuiteName:suite];

    SPSoloistEngine *solo1 = [[SPSoloistEngine alloc] initWithConnectClient:connect netClient:net store:store];
    solo1.defaults = defs;
    id<SPAudioEngine> asProtocol = solo1;
    SPExpectEqualInt(asProtocol.kind, SPAudioEngineKindSoloist, "Soloist implements SPAudioEngine");
    SPExpectEqualStr(solo1.deviceName, SPComputerDeviceName(), "Soloist device named after this Mac");

    // Persist volume across simulated launches.
    [solo1 setVolumePercent:63];
    SPSoloistEngine *solo2 = [[SPSoloistEngine alloc] initWithConnectClient:connect netClient:net store:store];
    solo2.defaults = defs;
    SPExpectEqualInt(solo2.volumePercent, 63, "Soloist volume persisted across launches");

    // Socket events: logged_in false -> WaitingForPairing, then true -> Ready + device_id + volume sync.
    [solo2 applySocketEventData:[@"{\"logged_in\":false}" dataUsingEncoding:NSUTF8StringEncoding]];
    SPExpectEqualInt(solo2.status, SPAudioEngineStatusWaitingForPairing, "logged_in:false sets WaitingForPairing");

    // Network return restart policy.
    SPExpect([SPSoloistEngine shouldRestartForStatus:SPAudioEngineStatusWaitingForPairing isRunning:YES networkReturned:YES],
             @"restarts when waitingForPairing, running, and network returned");
    SPExpect(![SPSoloistEngine shouldRestartForStatus:SPAudioEngineStatusReady isRunning:YES networkReturned:YES],
             @"does not restart when already ready");

    [solo2 applySocketEventData:[@"{\"logged_in\":true,\"device_id\":\"soloist-mac-id\"}" dataUsingEncoding:NSUTF8StringEncoding]];
    SPExpectEqualInt(solo2.status, SPAudioEngineStatusReady, "logged_in:true transitions to Ready");
    SPExpectEqualStr(solo2.soloistDeviceID, @"soloist-mac-id", "Soloist device ID captured");

    // Clicked search track + Song Radio continuation routes over Connect to Soloist device.
    __block BOOL done = NO;
    [solo2 playTrackURIWithRadio:@"spotify:track:4cOdK2wGLETKBW3PvgPWqT"
                    fallbackURIs:nil
                      completion:^(NSError *e) { if (!e) done = YES; }];
    SPExpect(SPWaitUntil(2.0, ^BOOL { return done; }), @"Soloist radio playback dispatched");
    SPExpectEqualInt(playedURIs.count, 2, "clicked track + radio track sent to Soloist");
    SPExpectEqualStr(playedURIs[0], @"spotify:track:4cOdK2wGLETKBW3PvgPWqT", "clicked track first");
    SPExpectEqualStr(playedURIs[1], @"spotify:track:solRad1", "radio track second");

    [defs removePersistentDomainForName:suite];
    [server stop];
}

SP_TEST(MediaKeysNowPlayingInfoBuilder) {
    SPTrack *track = [[SPTrack alloc] initWithTrackID:@"4cOdK2wGLETKBW3PvgPWqT"
                                                  uri:@"spotify:track:4cOdK2wGLETKBW3PvgPWqT"
                                                 name:@"Never Gonna Give You Up"
                                              albumID:@"alb1"
                                            albumName:@"Whenever You Need Somebody"
                                             artistID:@"art1"
                                           artistName:@"Rick Astley"
                                          artistNames:@[ @"Rick Astley" ]
                                           durationMs:213573
                                          trackNumber:1
                                           discNumber:1
                                           artworkURL:nil
                                      artworkSmallURL:nil
                                             playable:YES
                                     unplayableReason:nil];
    SPPlaybackState *playing = [[SPPlaybackState alloc] initWithActiveDeviceID:@"dev1"
                                                                    contextURI:@"spotify:album:alb1"
                                                                   contextName:nil
                                                               currentTrackURI:track.uri
                                                                   timestampMs:1000000
                                                       positionAsOfTimestampMs:10000
                                                                    durationMs:213573
                                                                     isPlaying:YES
                                                                      isPaused:NO
                                                                     shuffling:NO
                                                                    repeatMode:SPRepeatOff
                                                                   canSkipNext:YES
                                                                    canShuffle:YES
                                                              canRepeatContext:YES
                                                                canRepeatTrack:YES
                                                                    prevTracks:@[]
                                                                    nextTracks:@[]];
    NSDictionary *info = [SPMediaKeysBridge nowPlayingInfoForState:playing track:track nowMs:1005000];
    SPExpectEqualStr(info[MPMediaItemPropertyTitle], @"Never Gonna Give You Up", "Now Playing title");
    SPExpectEqualStr(info[MPMediaItemPropertyArtist], @"Rick Astley", "Now Playing artist");
    SPExpectEqualStr(info[MPMediaItemPropertyAlbumTitle], @"Whenever You Need Somebody", "Now Playing album");
    SPExpect([info[MPNowPlayingInfoPropertyPlaybackRate] doubleValue] == 1.0, @"playing rate is 1.0");
    SPExpect([info[MPNowPlayingInfoPropertyElapsedPlaybackTime] doubleValue] == 15.0, @"elapsed time interpolated to 15.0s");

    // Verify SPMediaKeysBridge dispatches remote commands onto the main thread (BP-H5).
    SPStore *store = [[SPStore alloc] initWithDatabase:nil];
    SPAuth *auth = [[SPAuth alloc] initWithSecretStore:[SPMemorySecretStore new]];
    SPNetClient *net = [[SPNetClient alloc] initWithAuth:auth];
    SPFairPlayEngine *engine = [[SPFairPlayEngine alloc] initWithNetClient:net store:store];
    engine.dryRunMode = YES;
    SPMediaKeysBridge *bridge = [[SPMediaKeysBridge alloc] initWithEngine:engine];

    __block BOOL ranOnMain = NO;
    __block BOOL done = NO;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [bridge dispatchRemoteCommand:^(id<SPAudioEngine> eng) {
            (void)eng;
            ranOnMain = NSThread.isMainThread;
            done = YES;
        }];
    });
    SPExpect(SPWaitUntil(2.0, ^BOOL { return done; }), @"media keys remote command executed");
    SPExpect(ranOnMain, @"media keys remote command marshalled onto main thread");
}

@interface SPTestAudioDelegate : NSObject <SPAudioEngineDelegate>
@property (nonatomic) SPAudioEngineStatus lastStatus;
@property (nonatomic, strong, nullable) NSError *lastError;
@end

@implementation SPTestAudioDelegate
- (void)audioEngine:(id<SPAudioEngine>)engine didChangeStatus:(SPAudioEngineStatus)status error:(NSError *)error {
    (void)engine;
    _lastStatus = status;
    _lastError = error;
}
@end

SP_TEST(FairPlayContextPlayShuffleAdvancementFailureAndConnectBidirectional) {
    SPStore *store = [[SPStore alloc] initWithDatabase:nil];
    NSMutableArray<SPTrack *> *tracks = [NSMutableArray new];
    NSMutableArray<NSString *> *tids = [NSMutableArray new];
    for (int i = 0; i < 4; i++) {
        NSString *tid = [NSString stringWithFormat:@"fpTrk%d", i];
        [tids addObject:tid];
        [tracks addObject:[[SPTrack alloc] initWithTrackID:tid
                                                       uri:[NSString stringWithFormat:@"spotify:track:%@", tid]
                                                      name:[NSString stringWithFormat:@"Song %d", i]
                                                   albumID:@"albFP1"
                                                 albumName:@"FP Album"
                                                  artistID:@"artFP1"
                                                artistName:@"FP Artist"
                                               artistNames:@[ @"FP Artist" ]
                                                durationMs:200000
                                               trackNumber:i + 1
                                                discNumber:1
                                                artworkURL:nil
                                           artworkSmallURL:nil
                                                  playable:YES
                                          unplayableReason:nil]];
    }
    SPAlbum *album = [[SPAlbum alloc] initWithAlbumID:@"albFP1"
                                                  uri:@"spotify:album:albFP1"
                                                 name:@"FP Album"
                                            albumType:@"album"
                                             artistID:@"artFP1"
                                           artistName:@"FP Artist"
                                          artistNames:@[ @"FP Artist" ]
                                          releaseDate:@"2026"
                                           artworkURL:nil
                                      artworkSmallURL:nil
                                             trackIDs:tids
                                      totalTrackCount:4
                                      totalDurationMs:800000
                                        detailsLoaded:YES];
    [store upsertTracks:tracks];
    [store upsertAlbums:@[ album ]];

    SPSessionBlob *sess = [[SPSessionBlob alloc] initWithAccessToken:@"tok" refreshToken:@"ref"
                                                accessTokenExpiresAt:NSDate.date.timeIntervalSince1970 + 3600
                                                            username:@"davi" deviceID:@"dev-fp-1"
                                                         clientToken:@"ct" clientTokenExpiresAt:NSDate.date.timeIntervalSince1970 + 3600
                                                          soloistKey:nil];
    SPAuth *auth = [[SPAuth alloc] initWithSecretStore:[SPMemorySecretStore new] session:sess urlSession:nil];
    SPNetClient *net = [[SPNetClient alloc] initWithAuth:auth];
    SPFairPlayEngine *engine = [[SPFairPlayEngine alloc] initWithNetClient:net store:store];
    engine.dryRunMode = YES;
    SPTestAudioDelegate *audioDel = [SPTestAudioDelegate new];
    engine.delegate = audioDel;

    // 1. Context playback with empty trackURI (Album Play button path — BP-C2).
    __block NSError *ctxErr = nil;
    __block BOOL ctxDone = NO;
    [engine playTrackURI:@"" inContextURI:album.uri trackIndex:0 completion:^(NSError *err) {
        ctxErr = err;
        ctxDone = YES;
    }];
    SPExpect(ctxDone && ctxErr == nil, @"FairPlay context play resolved album tracks cleanly");
    SPExpectEqualInt(engine.queueURIs.count, 4, "all 4 album tracks queued");
    SPExpectEqualStr(store.playbackState.currentTrackURI, @"spotify:track:fpTrk0", "started at album track 0");

    // 2. End-of-track automatic advancement (BP-C3).
    [engine simulateCurrentItemDidEnd];
    SPExpectEqualStr(store.playbackState.currentTrackURI, @"spotify:track:fpTrk1", "end-of-track advanced to fpTrk1");

    // Non-destructive skipToQueueIndex (UX-M3): jump over fpTrk2 to fpTrk3 without wiping context.
    [engine skipToQueueIndex:1];
    SPExpectEqualStr(store.playbackState.currentTrackURI, @"spotify:track:fpTrk3", "skipToQueueIndex jumped to fpTrk3");

    // RepeatTrack stays on fpTrk3 on end-of-track.
    [engine setRepeatMode:SPRepeatTrack];
    [engine simulateCurrentItemDidEnd];
    SPExpectEqualStr(store.playbackState.currentTrackURI, @"spotify:track:fpTrk3", "RepeatTrack restarted fpTrk3");

    // RepeatContext wraps back to fpTrk0.
    [engine setRepeatMode:SPRepeatContext];
    [engine simulateCurrentItemDidEnd];
    SPExpectEqualStr(store.playbackState.currentTrackURI, @"spotify:track:fpTrk0", "RepeatContext wrapped to fpTrk0");

    // 3. Shuffle pins current track at index 0 and restores original order on unshuffle (BP-C2).
    [engine setShuffle:YES];
    SPExpectEqualInt(engine.currentQueueIndex, 0, "shuffle pins current track at index 0");
    SPExpectEqualStr(engine.queueURIs[0], @"spotify:track:fpTrk0", "current track preserved at index 0 when shuffled");
    SPExpectEqualInt(engine.queueURIs.count, 4, "all 4 tracks kept when shuffled");
    [engine setShuffle:NO];
    SPExpectEqualStr(engine.queueURIs[0], @"spotify:track:fpTrk0", "original order restored on unshuffle");
    SPExpectEqualStr(engine.queueURIs[3], @"spotify:track:fpTrk3", "original last track restored on unshuffle");

    // 4. PutState encodes Device.player_state protobuf (BP-C5).
    NSData *putPB = SPConnectBuildPutStateProtobufWithPlayerState(@"dev-fp-1", @"Mac", YES, NO, YES, 32768, 1234567, store.playbackState);
    NSData *deviceWrap = SPProtobufFirstBytes(putPB, 2);
    NSData *psBytes = SPProtobufFirstBytes(deviceWrap, 2);
    SPExpect(psBytes.length > 0, @"PutState encoded Device.player_state field 2");
    SPPlaybackState *decodedPS = [SPPlaybackState playbackStateFromProtobufData:psBytes activeDeviceID:@"dev-fp-1"];
    SPExpectEqualStr(decodedPS.currentTrackURI, @"spotify:track:fpTrk0", "PutState player_state round-tripped current track");
    SPExpectEqualStr(decodedPS.contextURI, album.uri, "PutState player_state round-tripped context URI");

    // 5. SPAppController SPConnectClientDelegate command dispatch (BP-C5).
    SPAppController *app = [SPAppController new];
    SPConnectClient *connect = [[SPConnectClient alloc] initWithAuth:auth netClient:net store:store];
    SPMediaKeysBridge *mk = [[SPMediaKeysBridge alloc] initWithEngine:engine];
    [app attachAudioEngine:engine store:store netClient:net connectClient:connect mediaKeys:mk];

    SPExpect([app connectClient:connect didReceiveCommandPayload:@{@"command" : @{@"endpoint" : @"pause"}}], @"pause command handled");
    SPExpectEqualInt(engine.status, SPAudioEngineStatusPaused, "remote Connect pause paused FairPlay");
    SPExpect([app connectClient:connect didReceiveCommandPayload:@{@"command" : @{@"endpoint" : @"resume"}}], @"resume command handled");
    SPExpectEqualInt(engine.status, SPAudioEngineStatusPlaying, "remote Connect resume resumed FairPlay");
    NSDictionary *seekCmd = @{@"command" : @{@"endpoint" : @"seek_to", @"value" : @45000}};
    SPExpect([app connectClient:connect didReceiveCommandPayload:seekCmd], @"seek command handled");
    SPExpectEqualInt(store.playbackState.positionAsOfTimestampMs, 45000, "remote Connect seek updated position");
    NSDictionary *volCmd = @{@"command" : @{@"endpoint" : @"set_volume", @"volume" : @32768}};
    SPExpect([app connectClient:connect didReceiveCommandPayload:volCmd], @"volume command handled");
    SPExpectEqualInt(engine.volumePercent, 50, "remote Connect set_volume updated engine volume");
    NSDictionary *unkCmd = @{@"command" : @{@"endpoint" : @"unknown_op"}};
    SPExpect(![app connectClient:connect didReceiveCommandPayload:unkCmd], @"unknown Connect endpoint returns NO");

    // 6. AVPlayerItem failure notification triggers SPAudioEngineStatusFailed (BP-C3).
    NSError *simErr = [NSError errorWithDomain:@"test" code:403 userInfo:nil];
    [engine simulateCurrentItemDidFailWithError:simErr];
    SPExpectEqualInt(engine.status, SPAudioEngineStatusFailed, "item failure transitions FairPlay to Failed");
    SPExpectEqualInt(audioDel.lastStatus, SPAudioEngineStatusFailed, "delegate notified of item failure");

    // 7. Connect backoff increments across failed attempts without prematurely resetting (BP-H1).
    SPConnectClient *backoffClient = [[SPConnectClient alloc] initWithAuth:auth netClient:net store:store];
    backoffClient.dealerWebSocketURL = [NSURL URLWithString:@"ws://127.0.0.1:1"]; // immediate connection refused
    backoffClient.baseReconnectDelay = 0.02;
    [backoffClient connect];
    SPExpect(SPWaitUntil(1.5, ^BOOL { return backoffClient.reconnectAttempts >= 2; }),
             @"Connect reconnectAttempts incremented across consecutive failures (%lu)",
             (unsigned long)backoffClient.reconnectAttempts);
    [backoffClient disconnect];

    // 8. SPSoloistEngine routes commands to active remote speaker rather than hijacking to local Soloist (BP-H3).
    SPMockHTTPServer *remoteSrv = [SPMockHTTPServer new];
    SPExpect([remoteSrv start], @"mock remote speaker server started");
    NSObject *pathLock = [NSObject new];
    __block NSString *commandedPath = nil;
    remoteSrv.handler = ^SPMockResponse *(SPMockRequest *req) {
        @synchronized(pathLock) { commandedPath = req.path; }
        return [SPMockResponse responseWithStatus:200 json:@{}];
    };
    SPNetClient *remoteNet = [[SPNetClient alloc] initWithAuth:auth];
    remoteNet.spclientBaseURL = [remoteSrv urlForPath:@"/"];
    SPConnectClient *remoteConnect = [[SPConnectClient alloc] initWithAuth:auth netClient:remoteNet store:store];
    SPSoloistEngine *solo = [[SPSoloistEngine alloc] initWithConnectClient:remoteConnect netClient:remoteNet store:store];
    [solo applySocketEventData:[@"{\"event\":\"auth_state\",\"logged_in\":true,\"device_id\":\"solo-local\"}" dataUsingEncoding:NSUTF8StringEncoding]];
    SPDevice *remoteDev = [[SPDevice alloc] initWithDeviceID:@"sonos-living-room"
                                                        name:@"Living Room"
                                                  deviceType:SPDeviceTypeSpeaker
                                                    isActive:YES
                                                    isHidden:NO
                                                     canPlay:YES
                                               disableVolume:NO
                                                      volume:39321u];
    [store applyClusterState:[[SPClusterState alloc] initWithActiveDeviceID:@"sonos-living-room" allDevices:@[ remoteDev ] playbackState:nil]];
    [solo skipNext];
    SPExpect(SPWaitUntil(2.0, ^BOOL {
        @synchronized(pathLock) { return commandedPath != nil; }
    }), @"Soloist routed command to active remote speaker");
    SPExpect([commandedPath containsString:@"/to/sonos-living-room"], @"command targeted sonos-living-room, not solo-local (got %@)", commandedPath);
    [remoteSrv stop];
}
