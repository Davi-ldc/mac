// A call's media: one libwebrtc peer connection to Chime's audio host, audio only, with the Mac's
// microphone and output through AVAudioEngine's voice processing (echo cancellation). Without
// libwebrtc (SN_WEBRTC unset) the class exists but is unavailable. Main thread.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SNCallMediaState) {
    SNCallMediaConnecting,
    SNCallMediaConnected,
    /// ICE lost the path; it may come back by itself.
    SNCallMediaDisconnected,
    SNCallMediaFailed,
    SNCallMediaClosed,
};

/// A TURN server as JOIN_ACK gives it; the media connects to its UDP port as Slack's client does
/// (3478 becomes 22466).
@interface SNICEServer : NSObject
@property (nonatomic, copy) NSArray<NSString *> *urls;
@property (nonatomic, copy, nullable) NSString *username, *credential;
@end

/// Slack's client sends Chime's port 3478 to 22466 (MediaSessionSdk's urlRewriter, applied to
/// every meeting URL and the TURN URIs; an experiment keeps 3478).
NSString *SNSlackPortURL(NSString *url);

/// Loads WebRTC.framework lazily (once per process); NO when unavailable.
BOOL SNLoadWebRTC(void);
BOOL SNLoadWebRTCAtPath(NSString *_Nullable path);

@interface SNCallMedia : NSObject
/// This build has libwebrtc.
+ (BOOL)isAvailable;
/// `audioDevice` nil uses the Mac's microphone and output; tests pass a synthetic id<RTCAudioDevice>.
/// With servers the media goes through them only (relay), as Chime's client. nil when unavailable.
- (nullable instancetype)initWithICEServers:(NSArray<SNICEServer *> *)servers audioDevice:(nullable id)audioDevice;
/// `loopbackOnly` gathers candidates on the loopback interface alone: in-process tests that reach
/// nothing outside the Mac.
- (nullable instancetype)initWithICEServers:(NSArray<SNICEServer *> *)servers audioDevice:(nullable id)audioDevice loopbackOnly:(BOOL)loopbackOnly;
/// The offer for SUBSCRIBE once ICE gathering finished (Chime takes no trickled candidates): audio
/// sent and received, and an inactive video section, as Chime's client offers.
- (void)createOffer:(void (^)(NSString *_Nullable sdp, NSError *_Nullable error))completion;
- (void)setAnswer:(NSString *)sdp completion:(void (^)(NSError *_Nullable error))completion;
/// The microphone's track sends nothing while muted; YES at first, as calls start muted.
@property (nonatomic) BOOL muted;
@property (nonatomic, readonly) SNCallMediaState state;
@property (nonatomic, copy, nullable) void (^onStateChange)(SNCallMediaState state);
/// Stops the audio device and closes the peer connection; idempotent.
- (void)close;
@end

NS_ASSUME_NONNULL_END
