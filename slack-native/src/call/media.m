// Owns a call's peer connection: its configuration, the offer and answer as Chime's client shapes
// them, mute and the connection's state.
#import "call/media.h"

#if SN_WEBRTC
#import <WebRTC/WebRTC.h>
#import <dlfcn.h>
#import <pthread.h>

#import "call/voicedevice.h"
#endif

@implementation SNICEServer
@end

NSString *SNSlackPortURL(NSString *url) {
    NSRange port = [url rangeOfString:@":3478"];
    return port.location == NSNotFound ? url : [url stringByReplacingCharactersInRange:port withString:@":22466"];
}

#if SN_WEBRTC

/// Chime's client stops waiting for candidates after this, with whatever it has.
static const NSTimeInterval SNGatheringTimeout = 5;

/// The Opus fmtp line of every audio section with `parameter` set (Chime's
/// withAudioMaxAverageBitrate: fullband speech mono is 40 kbps).
static NSString *SNSetOpusParameter(NSString *sdp, NSString *name, NSString *value) {
    NSMutableArray<NSString *> *lines = [[sdp componentsSeparatedByString:@"\r\n"] mutableCopy];
    NSMutableSet<NSString *> *opus = [NSMutableSet new];
    BOOL audio = NO;
    for (NSString *line in lines) {
        if ([line hasPrefix:@"m="]) audio = [line hasPrefix:@"m=audio"];
        NSRange slash = [line rangeOfString:@" opus/48000"];
        if (audio && [line hasPrefix:@"a=rtpmap:"] && slash.location != NSNotFound)
            [opus addObject:[NSString stringWithFormat:@"a=fmtp:%@ ", [line substringWithRange:NSMakeRange(9, slash.location - 9)]]];
    }
    for (NSUInteger i = 0; i < lines.count; i++) {
        NSString *line = lines[i];
        NSString *prefix = nil;
        for (NSString *candidate in opus)
            if ([line hasPrefix:candidate]) prefix = candidate;
        if (!prefix) continue;
        NSMutableArray *kept = [NSMutableArray new];
        for (NSString *parameter in [[line substringFromIndex:prefix.length] componentsSeparatedByString:@";"])
            if (parameter.length && ![parameter hasPrefix:[name stringByAppendingString:@"="]]) [kept addObject:parameter];
        [kept addObject:[NSString stringWithFormat:@"%@=%@", name, value]];
        lines[i] = [prefix stringByAppendingString:[kept componentsJoinedByString:@";"]];
    }
    return [lines componentsJoinedByString:@"\r\n"];
}

/// Chime's client keeps only relay and host candidates of the audio host's answer.
static NSString *SNWithoutReflexiveCandidates(NSString *sdp) {
    NSMutableArray *lines = [NSMutableArray new];
    for (NSString *line in [sdp componentsSeparatedByString:@"\r\n"])
        if (!([line hasPrefix:@"a=candidate:"] && [line containsString:@" typ srflx"])) [lines addObject:line];
    return [lines componentsJoinedByString:@"\r\n"];
}

static NSString *WebRTCBinaryPath(void) {
    NSString *frameworks = NSBundle.mainBundle.privateFrameworksPath;
    return frameworks.length ? [frameworks stringByAppendingPathComponent:@"WebRTC.framework/WebRTC"] : nil;
}

BOOL SNLoadWebRTCAtPath(NSString *path) {
    if (!path.length) return NO;
    void *handle = dlopen(path.fileSystemRepresentation, RTLD_LAZY | RTLD_LOCAL);
    if (!handle) return NO;
    BOOL (*initSSL)(void) = dlsym(handle, "RTCInitializeSSL");
    if (!initSSL || !initSSL() || !NSClassFromString(@"RTCPeerConnectionFactory")) {
        dlclose(handle);
        return NO;
    }
    return YES;
}

BOOL SNLoadWebRTC(void) {
    static BOOL loaded;
    static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
    pthread_mutex_lock(&lock);
    if (!loaded) loaded = SNLoadWebRTCAtPath(WebRTCBinaryPath());
    BOOL result = loaded;
    pthread_mutex_unlock(&lock);
    return result;
}

#define SNRTC(name) ((Class)NSClassFromString(@#name))

static NSError *SNMediaError(NSString *reason) { return [NSError errorWithDomain:@"SNCallMedia" code:1 userInfo:@{NSLocalizedDescriptionKey : reason}]; }

@interface SNCallMedia () <RTCPeerConnectionDelegate>
@end

@implementation SNCallMedia {
    RTCPeerConnectionFactory *_factory;
    RTCPeerConnection *_connection;
    RTCAudioTrack *_track;
    BOOL _relay, _relayed;
    void (^_gathered)(void);
}

+ (BOOL)isAvailable {
    NSString *path = WebRTCBinaryPath();
    return path.length && [NSFileManager.defaultManager fileExistsAtPath:path];
}

- (instancetype)initWithICEServers:(NSArray<SNICEServer *> *)servers audioDevice:(id)audioDevice {
    return [self initWithICEServers:servers audioDevice:audioDevice loopbackOnly:NO];
}

- (instancetype)initWithICEServers:(NSArray<SNICEServer *> *)servers audioDevice:(id)audioDevice loopbackOnly:(BOOL)loopbackOnly {
    if (!(self = [super init]) || !SNLoadWebRTC()) return nil;
    // The video factories only give the inactive video section its codecs, as a browser offers.
    _factory = [[SNRTC(RTCPeerConnectionFactory) alloc] initWithEncoderFactory:[SNRTC(RTCDefaultVideoEncoderFactory) new]
                                                                decoderFactory:[SNRTC(RTCDefaultVideoDecoderFactory) new]
                                                                   audioDevice:audioDevice ?: [SNVoiceDevice new]];
    if (loopbackOnly) {
        RTCPeerConnectionFactoryOptions *options = [SNRTC(RTCPeerConnectionFactoryOptions) new];
        options.ignoreLoopbackNetworkAdapter = NO;
        options.ignoreWiFiNetworkAdapter = options.ignoreEthernetNetworkAdapter = options.ignoreVPNNetworkAdapter = options.ignoreCellularNetworkAdapter = YES;
        [_factory setOptions:options];
    }
    RTCConfiguration *configuration = [SNRTC(RTCConfiguration) new];
    NSMutableArray<RTCIceServer *> *iceServers = [NSMutableArray new];
    for (SNICEServer *server in servers) {
        NSMutableArray *urls = [NSMutableArray new];
        for (NSString *url in server.urls) [urls addObject:SNSlackPortURL(url)];
        if (urls.count) [iceServers addObject:[[SNRTC(RTCIceServer) alloc] initWithURLStrings:urls username:server.username credential:server.credential]];
    }
    _relay = iceServers.count > 0;
    configuration.iceServers = iceServers;
    configuration.iceTransportPolicy = _relay ? RTCIceTransportPolicyRelay : RTCIceTransportPolicyAll;
    configuration.bundlePolicy = RTCBundlePolicyMaxBundle;
    configuration.rtcpMuxPolicy = RTCRtcpMuxPolicyRequire;
    configuration.sdpSemantics = RTCSdpSemanticsUnifiedPlan;
    configuration.continualGatheringPolicy = RTCContinualGatheringPolicyGatherOnce;
    _connection = [_factory peerConnectionWithConfiguration:configuration
                                                constraints:[[SNRTC(RTCMediaConstraints) alloc] initWithMandatoryConstraints:nil optionalConstraints:nil]
                                                   delegate:self];
    if (!_connection) return nil;
    // Voice processing (or the synthetic device) already cancels echo and levels the voice;
    // libwebrtc's own processing on top would fight it (and would eat a test's steady tone as noise).
    NSDictionary *processing = @{@"googEchoCancellation" : @"false", @"googAutoGainControl" : @"false", @"googNoiseSuppression" : @"false", @"googHighpassFilter" : @"false"};
    RTCAudioSource *source = [_factory audioSourceWithConstraints:[[SNRTC(RTCMediaConstraints) alloc] initWithMandatoryConstraints:processing optionalConstraints:nil]];
    _track = [_factory audioTrackWithSource:source trackId:@"audio"];
    _muted = YES;
    _track.isEnabled = NO;
    RTCRtpTransceiverInit *audio = [SNRTC(RTCRtpTransceiverInit) new];
    audio.direction = RTCRtpTransceiverDirectionSendRecv;
    audio.streamIds = @[ @"stream" ];
    RTCRtpTransceiverInit *video = [SNRTC(RTCRtpTransceiverInit) new];
    video.direction = RTCRtpTransceiverDirectionInactive;
    video.streamIds = @[ @"stream" ];
    if (![_connection addTransceiverWithTrack:_track init:audio] || ![_connection addTransceiverOfType:RTCRtpMediaTypeVideo init:video]) {
        [_connection close];
        return nil;
    }
    _state = SNCallMediaConnecting;
    return self;
}

- (void)dealloc { [self close]; }

- (void)createOffer:(void (^)(NSString *, NSError *))completion {
    __weak SNCallMedia *weakSelf = self;
    void (^fail)(NSString *) = ^(NSString *reason) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, SNMediaError(reason)); });
    };
    [_connection offerForConstraints:[[SNRTC(RTCMediaConstraints) alloc] initWithMandatoryConstraints:nil optionalConstraints:nil] completionHandler:^(RTCSessionDescription *offer, NSError *error) {
        if (!offer) return fail(error.localizedDescription ?: @"no offer");
        RTCSessionDescription *local = [[SNRTC(RTCSessionDescription) alloc] initWithType:RTCSdpTypeOffer sdp:SNSetOpusParameter(offer.sdp, @"maxaveragebitrate", @"40000")];
        dispatch_async(dispatch_get_main_queue(), ^{
            SNCallMedia *media = weakSelf;
            if (!media || !media->_connection) return completion(nil, SNMediaError(@"closed"));
            [media->_connection setLocalDescription:local completionHandler:^(NSError *setError) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    SNCallMedia *media = weakSelf;
                    if (setError || !media || !media->_connection) return completion(nil, setError ?: SNMediaError(@"closed"));
                    [media waitForCandidates:^{
                        SNCallMedia *media = weakSelf;
                        NSString *sdp = media ? media->_connection.localDescription.sdp : nil;
                        if (![sdp containsString:@"a=candidate:"]) return completion(nil, SNMediaError(sdp ? @"no ICE candidates" : @"closed"));
                        // Chime's audio host reads a unified-plan offer by this origin, as its JS
                        // client's withUnifiedPlanFormat sends it.
                        completion([sdp stringByReplacingOccurrencesOfString:@"o=-" withString:@"o=mozilla-chrome" options:0 range:NSMakeRange(0, MIN(sdp.length, 64))], nil);
                    }];
                });
            }];
        });
    }];
}

/// Done when gathering completes; through TURN, at the first relay candidate for RTP, as Chime's
/// client: whichever comes first, or the timeout.
- (void)waitForCandidates:(void (^)(void))done {
    if (_relayed || _connection.iceGatheringState == RTCIceGatheringStateComplete) return done();
    _gathered = [done copy];
    __weak SNCallMedia *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SNGatheringTimeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [weakSelf finishGathering]; });
}

- (void)finishGathering {
    void (^gathered)(void) = _gathered;
    _gathered = nil;
    if (gathered && _connection) gathered();
}

- (void)setAnswer:(NSString *)sdp completion:(void (^)(NSError *))completion {
    if (!_connection) return completion(SNMediaError(@"closed"));
    NSString *munged = SNSetOpusParameter(SNWithoutReflexiveCandidates(sdp), @"maxaveragebitrate", @"40000");
    [_connection setRemoteDescription:[[SNRTC(RTCSessionDescription) alloc] initWithType:RTCSdpTypeAnswer sdp:munged] completionHandler:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
    }];
}

- (void)setMuted:(BOOL)muted {
    _muted = muted;
    _track.isEnabled = !muted;
}

- (void)close {
    if (!_connection) return;
    _onStateChange = nil;
    _gathered = nil;
    _track.isEnabled = NO;
    [_connection close];
    _connection = nil;
    _track = nil;
    // The factory stops the audio device as it goes.
    _factory = nil;
    _state = SNCallMediaClosed;
}

- (void)changeState:(SNCallMediaState)state {
    if (!_connection || state == _state) return;
    _state = state;
    if (_onStateChange) _onStateChange(state);
}

#pragma mark RTCPeerConnectionDelegate (libwebrtc's signalling thread)

- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeConnectionState:(RTCPeerConnectionState)newState {
    SNCallMediaState state = newState == RTCPeerConnectionStateConnected ? SNCallMediaConnected
                             : newState == RTCPeerConnectionStateDisconnected ? SNCallMediaDisconnected
                             : newState == RTCPeerConnectionStateFailed ? SNCallMediaFailed
                             : newState == RTCPeerConnectionStateClosed ? SNCallMediaClosed
                                                                        : SNCallMediaConnecting;
    __weak SNCallMedia *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf changeState:state]; });
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeIceGatheringState:(RTCIceGatheringState)newState {
    if (newState != RTCIceGatheringStateComplete) return;
    __weak SNCallMedia *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf finishGathering]; });
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didGenerateIceCandidate:(RTCIceCandidate *)candidate {
    // "candidate:<foundation> <component> ...": component 1 carries RTP.
    NSArray *fields = [candidate.sdp componentsSeparatedByString:@" "];
    if (!_relay || fields.count < 2 || ![fields[1] isEqualToString:@"1"] || ![candidate.sdp containsString:@" typ relay"]) return;
    __weak SNCallMedia *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        SNCallMedia *media = weakSelf;
        if (!media) return;
        media->_relayed = YES;
        [media finishGathering];
    });
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeSignalingState:(RTCSignalingState)stateChanged {}
- (void)peerConnection:(RTCPeerConnection *)peerConnection didAddStream:(RTCMediaStream *)stream {}
- (void)peerConnection:(RTCPeerConnection *)peerConnection didRemoveStream:(RTCMediaStream *)stream {}
- (void)peerConnectionShouldNegotiate:(RTCPeerConnection *)peerConnection {}
- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeIceConnectionState:(RTCIceConnectionState)newState {}
- (void)peerConnection:(RTCPeerConnection *)peerConnection didRemoveIceCandidates:(NSArray<RTCIceCandidate *> *)candidates {}
- (void)peerConnection:(RTCPeerConnection *)peerConnection didOpenDataChannel:(RTCDataChannel *)dataChannel {}

@end

#else

BOOL SNLoadWebRTCAtPath(NSString *path) { return NO; }
BOOL SNLoadWebRTC(void) { return NO; }

@implementation SNCallMedia

+ (BOOL)isAvailable { return NO; }
- (instancetype)initWithICEServers:(NSArray<SNICEServer *> *)servers audioDevice:(id)audioDevice { return nil; }
- (instancetype)initWithICEServers:(NSArray<SNICEServer *> *)servers audioDevice:(id)audioDevice loopbackOnly:(BOOL)loopbackOnly { return nil; }
- (void)createOffer:(void (^)(NSString *, NSError *))completion {}
- (void)setAnswer:(NSString *)sdp completion:(void (^)(NSError *))completion {}
- (void)close {}

@end

#endif
