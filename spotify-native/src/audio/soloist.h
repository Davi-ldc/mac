// Soloist fallback audio engine implementing SPAudioEngine by supervising Spotify's Soloist + loopback WS + Connect.
#import <Foundation/Foundation.h>

#import "audio/engine.h"
#import "connect/connect.h"
#import "net/client.h"
#import "store/store.h"

NS_ASSUME_NONNULL_BEGIN

@interface SPSoloistEngine : NSObject <SPAudioEngine>
@property (nonatomic, copy) NSString *deviceName;
@property (nonatomic, copy, nullable) NSString *executablePath;
@property (nonatomic, copy, nullable) NSString *soloistKey;
@property (nonatomic, copy) NSString *dataDirectory;
@property (nonatomic, copy) NSString *cacheDirectory;
@property (nonatomic, readonly, copy, nullable) NSString *soloistDeviceID;
@property (nonatomic, readonly) BOOL isProcessRunning;
@property (nonatomic, readonly) BOOL networkReturnedSinceLaunch;

/// Injected defaults for volume persistence across launches (defaults to NSUserDefaults.standardUserDefaults).
@property (nonatomic, strong) NSUserDefaults *defaults;

- (instancetype)initWithConnectClient:(SPConnectClient *)connectClient
                            netClient:(SPNetClient *)netClient
                                store:(SPStore *)store NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Applies a Soloist loopback WebSocket JSON event (`auth_state`, `volume_changed`, `playback_state`).
/// Exposed for deterministic headless unit tests.
- (void)applySocketEventData:(NSData *)jsonData;

/// Called when network returns or macOS wakes from sleep. Restarts Soloist if logged out since launch.
- (void)handleNetworkReturned;

/// Auto-discovers an installed Soloist binary path (defaults override, app bundle, Application Support, Homebrew).
+ (nullable NSString *)discoverExecutablePath;

/// Synchronously waits (bounded ~1s) for graceful SIGTERM exit before falling back to SIGKILL (for app quit).
- (void)stopAndWait;

/// Pure decision helper: YES when Soloist is running in waitingForPairing and network returned since launch.
+ (BOOL)shouldRestartForStatus:(SPAudioEngineStatus)status
                     isRunning:(BOOL)isRunning
               networkReturned:(BOOL)networkReturned;
@end

NS_ASSUME_NONNULL_END
