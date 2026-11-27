// Native macOS FairPlay CBCS audio engine (AVQueuePlayer + in-memory HLS v6 VOD + AVContentKeySession).
#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

#import "audio/engine.h"
#import "net/client.h"
#import "store/store.h"

NS_ASSUME_NONNULL_BEGIN

/// Selects the best CBCS file from spclient `metadata/4/track` JSON (`MP4_256_CBCS`=15 > `MP4_128_CBCS`=14).
BOOL SPFairPlaySelectCBCSFile(NSDictionary *trackMeta, NSString *_Nullable *_Nullable outFileID, NSInteger *_Nullable outFormat);

/// Builds an in-memory HLS v6 VOD playlist from Spotify seektable v2 JSON + CDN URL.
/// Supports both `[{size, duration}]` dict segments and `[[size, duration]]` array segments.
NSString *_Nullable SPFairPlayBuildHLSManifest(NSString *fileID,
                                               NSString *cdnURL,
                                               NSDictionary *seektable,
                                               NSError *_Nullable *_Nullable outError);

/// Generates a local FairPlay Streaming SPC payload offline via macOS AVContentKeySession (no network or entitlements).
NSData *_Nullable SPFairPlayGenerateOfflineSPC(NSData *certDER,
                                               NSString *fileID,
                                               BOOL useUTF16LE,
                                               NSError *_Nullable *_Nullable outError);

@interface SPFairPlayEngine : NSObject <SPAudioEngine, AVContentKeySessionDelegate, AVAssetResourceLoaderDelegate>
@property (nonatomic, readonly) NSArray<NSString *> *queueURIs;
@property (nonatomic, readonly) NSInteger currentQueueIndex;
/// Safari WebKit uses UTF-16LE hex file_id with `?assetId=hex` (default YES); set NO for UTF-8 hex bytes.
@property (nonatomic) BOOL useUTF16LEAssetID;
/// When YES (unit tests), manages full playback queue/state machine without starting AVPlayer/CoreAudio hardware.
@property (nonatomic) BOOL dryRunMode;
/// Optional pre-loaded FairPlay DER application certificate.
@property (nonatomic, copy, nullable) NSData *applicationCertificate;

- (instancetype)initWithNetClient:(SPNetClient *)netClient store:(SPStore *)store NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Test hooks for end-of-track advancement and AVPlayerItem failure handling in headless dry-run tests.
- (void)simulateCurrentItemDidEnd;
- (void)simulateCurrentItemDidFailWithError:(NSError *)error;
@end

NS_ASSUME_NONNULL_END
