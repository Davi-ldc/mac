// Main application shell matching Spotifly 1:1:
// Native translucent sidebar + transparent full-size glass header + 2/3-column layout + Floating Liquid Glass bar + Now Playing Inspector.
#import <AppKit/AppKit.h>

#import "audio/engine.h"
#import "connect/connect.h"
#import "net/client.h"
#import "net/search.h"
#import "store/store.h"
#import "ui/kit/controls.h"
#import "ui/kit/nav.h"
#import "ui/player/player.h"
#import "ui/sidebar/sidebar.h"
#import "ui/shell/window.h"

NS_ASSUME_NONNULL_BEGIN

@interface SPShell : NSObject <SPNavigator, SPChangeObserver, SPSearchControllerDelegate, NSWindowDelegate>
@property (nonatomic, readonly, nullable) SPWindow *window;
@property (nonatomic, readonly, nullable) SPSearchField *toolbarSearchField;
@property (nonatomic, readonly, nullable) NSView *currentContentView;
@property (nonatomic, readonly, nullable) SPSidebarView *sidebarView;
@property (nonatomic, readonly, nullable) SPPlayerBarView *playerBarView;
@property (nonatomic, readonly) BOOL isWindowOpen;

@property (nonatomic, strong) id<SPAudioEngine> audioEngine;
@property (nonatomic, strong, nullable) SPConnectClient *connectClient;
@property (nonatomic, strong, nullable) SPNetClient *netClient;
@property (nonatomic, strong) SPSearchController *searchController;
@property (nonatomic) BOOL songRadioEnabled;

@property (nonatomic, copy, nullable) void (^onOpenPreferences)(void);
@property (nonatomic, copy, nullable) void (^onSignOut)(void);
@property (nonatomic, copy, nullable) void (^onWindowClosed)(void);

- (instancetype)initWithStore:(SPStore *)store
                  audioEngine:(id<SPAudioEngine>)audioEngine
                    netClient:(nullable SPNetClient *)netClient
                connectClient:(nullable SPConnectClient *)connectClient
                     defaults:(nullable NSUserDefaults *)defaults NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Builds (or brings forward) the main window and UI view hierarchy from current store state.
- (SPWindow *)ensureWindow;
- (void)showWindow;

/// Collapses or expands the left navigation sidebar.
- (void)toggleSidebar;

/// Tears down all UI views, cancels timers/popovers, releases images, and closes the window
/// WITHOUT stopping audio playback or disconnecting Spotify Connect.
- (void)closeWindowReleasingViews;

/// Adjusts volume by delta percent (e.g. +10 / -10) and persists it.
- (void)adjustVolumeBy:(NSInteger)delta;
@end

NS_ASSUME_NONNULL_END
