// Native macOS Spotifly Settings window (Cmd+,): General (Appearance), Playback (FairPlay/Soloist + Song Radio), Shortcuts.
#import <AppKit/AppKit.h>

#import "audio/engine.h"
#import "store/store.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SPAudioEnginePreference) {
    SPAudioEnginePrefAuto = 0,     // FairPlay primary with automatic Soloist fallback
    SPAudioEnginePrefFairPlay = 1, // FairPlay native only
    SPAudioEnginePrefSoloist = 2,  // Soloist fallback explicitly selected
};

typedef NS_ENUM(NSInteger, SPAppearanceMode) {
    SPAppearanceSystem = 0,
    SPAppearanceLight = 1,
    SPAppearanceDark = 2,
};

extern NSString *const kSPAppearanceModeDefaultsKey;

/// Applies the saved System / Light / Dark appearance preference to NSApp.
void SPApplySavedAppearancePreference(void);

@interface SPPreferencesWindowController : NSWindowController <SPChangeObserver, NSToolbarDelegate>
@property (nonatomic) SPAudioEnginePreference enginePreference;
@property (nonatomic) SPAudioEngineKind activeEngineKind;
@property (nonatomic) BOOL soloistKeyMissingOrFailed;
@property (nonatomic) BOOL songRadioEnabled;
@property (nonatomic, copy, nullable) NSString *soloistKeyValue;
@property (nonatomic, readonly) BOOL soloistKeySectionVisible;
@property (nonatomic, readonly) BOOL soloistChangeKeyButtonVisible;

@property (nonatomic, copy, nullable) void (^onEnginePreferenceChange)(SPAudioEnginePreference pref);
@property (nonatomic, copy, nullable) void (^onSaveSoloistKey)(NSString *key);
@property (nonatomic, copy, nullable) void (^onSongRadioToggle)(BOOL enabled);
@property (nonatomic, copy, nullable) void (^onSignOut)(void);

- (instancetype)initWithStore:(SPStore *)store;
- (void)beginEditingSoloistKey;
- (void)refreshState;
@end

NS_ASSUME_NONNULL_END
