// Owns the test audio host.
#import "audiohost.h"

#if SN_WEBRTC
#import <WebRTC/WebRTC.h>

#import "call/media.h"

#define SNRTC(name) ((Class)NSClassFromString(@#name))

@interface SNTestAudioHost () <RTCPeerConnectionDelegate>
@end

@implementation SNTestAudioHost {
    RTCPeerConnectionFactory *_factory;
    RTCPeerConnection *_connection;
    RTCAudioTrack *_track;
    void (^_gathered)(void);
}

- (instancetype)initWithFrequency:(double)frequency {
    if (!(self = [super init]) || !SNLoadWebRTC()) return nil;
    _device = [[SNToneDevice alloc] initWithFrequency:frequency];
    _factory = [[SNRTC(RTCPeerConnectionFactory) alloc] initWithEncoderFactory:[SNRTC(RTCDefaultVideoEncoderFactory) new] decoderFactory:[SNRTC(RTCDefaultVideoDecoderFactory) new] audioDevice:_device];
    RTCPeerConnectionFactoryOptions *options = [SNRTC(RTCPeerConnectionFactoryOptions) new];
    options.ignoreLoopbackNetworkAdapter = NO;
    options.ignoreWiFiNetworkAdapter = options.ignoreEthernetNetworkAdapter = options.ignoreVPNNetworkAdapter = options.ignoreCellularNetworkAdapter = YES;
    [_factory setOptions:options];
    RTCConfiguration *configuration = [SNRTC(RTCConfiguration) new];
    configuration.sdpSemantics = RTCSdpSemanticsUnifiedPlan;
    configuration.bundlePolicy = RTCBundlePolicyMaxBundle;
    configuration.rtcpMuxPolicy = RTCRtcpMuxPolicyRequire;
    _connection = [_factory peerConnectionWithConfiguration:configuration constraints:[[SNRTC(RTCMediaConstraints) alloc] initWithMandatoryConstraints:nil optionalConstraints:nil] delegate:self];
    NSDictionary *plain = @{@"googEchoCancellation" : @"false", @"googAutoGainControl" : @"false", @"googNoiseSuppression" : @"false", @"googHighpassFilter" : @"false"};
    _track = [_factory audioTrackWithSource:[_factory audioSourceWithConstraints:[[SNRTC(RTCMediaConstraints) alloc] initWithMandatoryConstraints:plain optionalConstraints:nil]] trackId:@"host"];
    return self;
}

- (void)dealloc { [self close]; }

- (void)answerOffer:(NSString *)offer completion:(void (^)(NSString *, NSError *))completion {
    __weak SNTestAudioHost *weakSelf = self;
    void (^finish)(NSString *, NSError *) = ^(NSString *answer, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(answer, error); });
    };
    [_connection setRemoteDescription:[[SNRTC(RTCSessionDescription) alloc] initWithType:RTCSdpTypeOffer sdp:offer] completionHandler:^(NSError *error) {
        SNTestAudioHost *host = weakSelf;
        if (error || !host) return finish(nil, error);
        for (RTCRtpTransceiver *transceiver in host->_connection.transceivers) {
            if (transceiver.mediaType != RTCRtpMediaTypeAudio) continue;
            transceiver.sender.track = host->_track;
            [transceiver setDirection:RTCRtpTransceiverDirectionSendRecv error:nil];
        }
        [host->_connection answerForConstraints:[[SNRTC(RTCMediaConstraints) alloc] initWithMandatoryConstraints:nil optionalConstraints:nil] completionHandler:^(RTCSessionDescription *answer, NSError *answerError) {
            SNTestAudioHost *host = weakSelf;
            if (!answer || !host) return finish(nil, answerError);
            [host->_connection setLocalDescription:answer completionHandler:^(NSError *setError) {
                SNTestAudioHost *host = weakSelf;
                if (setError || !host) return finish(nil, setError);
                dispatch_async(dispatch_get_main_queue(), ^{
                    SNTestAudioHost *host = weakSelf;
                    if (!host) return;
                    void (^done)(void) = ^{
                        SNTestAudioHost *host = weakSelf;
                        finish(host ? host->_connection.localDescription.sdp : nil, nil);
                    };
                    if (host->_connection.iceGatheringState == RTCIceGatheringStateComplete) done();
                    else host->_gathered = done;
                });
            }];
        }];
    }];
}

- (void)close {
    _gathered = nil;
    [_connection close];
    _connection = nil;
    _track = nil;
    _factory = nil;
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeConnectionState:(RTCPeerConnectionState)newState {
    __weak SNTestAudioHost *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        SNTestAudioHost *host = weakSelf;
        if (host) host->_connected = newState == RTCPeerConnectionStateConnected;
    });
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeIceGatheringState:(RTCIceGatheringState)newState {
    if (newState != RTCIceGatheringStateComplete) return;
    __weak SNTestAudioHost *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        SNTestAudioHost *host = weakSelf;
        if (!host) return;
        void (^gathered)(void) = host->_gathered;
        host->_gathered = nil;
        if (gathered) gathered();
    });
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeSignalingState:(RTCSignalingState)stateChanged {}
- (void)peerConnection:(RTCPeerConnection *)peerConnection didAddStream:(RTCMediaStream *)stream {}
- (void)peerConnection:(RTCPeerConnection *)peerConnection didRemoveStream:(RTCMediaStream *)stream {}
- (void)peerConnectionShouldNegotiate:(RTCPeerConnection *)peerConnection {}
- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeIceConnectionState:(RTCIceConnectionState)newState {}
- (void)peerConnection:(RTCPeerConnection *)peerConnection didGenerateIceCandidate:(RTCIceCandidate *)candidate {}
- (void)peerConnection:(RTCPeerConnection *)peerConnection didRemoveIceCandidates:(NSArray<RTCIceCandidate *> *)candidates {}
- (void)peerConnection:(RTCPeerConnection *)peerConnection didOpenDataChannel:(RTCDataChannel *)dataChannel {}

@end

#endif
