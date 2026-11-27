// Application controller: overlapped Keychain/SQLite launch preload, menus, audio engine switching, and window lifecycle.
#import <AppKit/AppKit.h>

#import "audio/engine.h"
#import "audio/fairplay.h"
#import "audio/mediakeys.h"
#import "audio/soloist.h"
#import "auth/auth.h"
#import "auth/keychain.h"
#import "connect/connect.h"
#import "net/client.h"
#import "store/database.h"
#import "store/store.h"
#import "ui/prefs/prefs.h"
#import "ui/shell/shell.h"

NS_ASSUME_NONNULL_BEGIN

/// Background preload started in main() BEFORE AppKit finishes initializing.
@interface SPAppPreload : NSObject
@property (nonatomic, readonly) dispatch_group_t group;
@property (nonatomic, readonly) id<SPSecretStore> secretStore;
@property (nonatomic, readonly, nullable) SPSessionBlob *session;
@property (nonatomic, readonly, nullable) SPStore *store;

+ (instancetype)startAsync;
@end

@interface SPAppController : NSObject <NSApplicationDelegate, SPAudioEngineDelegate, SPConnectClientDelegate>
@property (nonatomic, strong, nullable) SPAppPreload *preload;
@property (nonatomic, readonly, nullable) SPShell *shell;
@property (nonatomic, readonly, nullable) SPStore *store;
@property (nonatomic, readonly, nullable) id<SPAudioEngine> audioEngine;
@property (nonatomic, readonly, nullable) SPPreferencesWindowController *prefsController;

/// Builds the complete macOS menu bar (Spotify Native, Edit, View, Playback, Window).
- (NSMenu *)buildMainMenu;

/// Attaches session components for headless integration testing (Connect commands, cluster hydration, menus).
- (void)attachAudioEngine:(id<SPAudioEngine>)engine
                    store:(SPStore *)store
                netClient:(nullable SPNetClient *)netClient
            connectClient:(nullable SPConnectClient *)connectClient
                mediaKeys:(nullable SPMediaKeysBridge *)mediaKeys;
@end

NS_ASSUME_NONNULL_END
