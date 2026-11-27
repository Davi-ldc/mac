// Spotifly 1:1 Floating Liquid Glass Now Playing capsule (SPPlayerBarView),
// Now Playing Inspector (SPNowPlayingInspectorView), Queue Page (SPQueuePageView),
// Playing On / Speakers Page (SPSpeakersPageView), plus legacy drawer/popover.
#import <AppKit/AppKit.h>

#import "audio/engine.h"
#import "store/store.h"
#import "ui/kit/nav.h"

NS_ASSUME_NONNULL_BEGIN

@interface SPPlayerBarView : NSView <SPChangeObserver>
@property (nonatomic, weak, nullable) id<SPNavigator> navigator;
@property (nonatomic) NSInteger volumePercent;
@property (nonatomic) BOOL muted;
@property (nonatomic) BOOL queueOpen;
@property (nonatomic) BOOL inspectorOpen;
@property (nonatomic, readonly) BOOL progressTimerRunning;

- (instancetype)initWithFrame:(NSRect)frame store:(SPStore *)store navigator:(nullable id<SPNavigator>)navigator;
- (void)syncFromStore;
- (void)stopProgressTimer;
@end

/// Right-hand 320pt Now Playing Inspector matching Spotifly NowPlayingInspector.swift.
@interface SPNowPlayingInspectorView : NSView <SPChangeObserver>
@property (nonatomic, weak, nullable) id<SPNavigator> navigator;
- (instancetype)initWithFrame:(NSRect)frame store:(SPStore *)store navigator:(nullable id<SPNavigator>)navigator;
- (void)reloadInspector;
@end

/// Full-page Queue screen matching Spotifly QueueListView.swift.
@interface SPQueuePageView : NSView <SPChangeObserver>
@property (nonatomic, weak, nullable) id<SPNavigator> navigator;
- (instancetype)initWithFrame:(NSRect)frame store:(SPStore *)store navigator:(nullable id<SPNavigator>)navigator;
- (void)reloadQueue;
- (void)scrollToCurrentTrack;
@end

/// Full-page Playing On / Connect Devices screen matching Spotifly SpeakersView.swift.
@interface SPSpeakersPageView : NSView <SPChangeObserver>
@property (nonatomic, weak, nullable) id<SPNavigator> navigator;
@property (nonatomic) NSInteger volumePercent;
- (instancetype)initWithFrame:(NSRect)frame store:(SPStore *)store navigator:(nullable id<SPNavigator>)navigator;
- (void)reloadDevices;
@end

// Kept for compatibility
@interface SPQueueDrawerView : NSView <SPChangeObserver>
@property (nonatomic, weak, nullable) id<SPNavigator> navigator;
- (instancetype)initWithFrame:(NSRect)frame store:(SPStore *)store navigator:(nullable id<SPNavigator>)navigator;
- (void)reloadQueue;
@end

@interface SPSpeakersPopover : NSObject
@property (nonatomic, readonly) BOOL isShown;
- (instancetype)initWithStore:(SPStore *)store navigator:(nullable id<SPNavigator>)navigator;
- (void)toggleFromView:(NSView *)anchorView;
- (void)close;
@end

NS_ASSUME_NONNULL_END
