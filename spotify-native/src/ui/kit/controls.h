// Native macOS Spotifly-styled AppKit controls: SPButton, SPHeartButton, SPSlider, SPSearchField,
// SPDetailHeaderView, and virtualized SPTrackListView with single-row heart redraws.
#import <AppKit/AppKit.h>

#import "model/track.h"
#import "render/icons.h"
#import "store/store.h"
#import "ui/kit/list.h"
#import "ui/kit/nav.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SPButtonStyle) {
    SPButtonStyleGhost = 0,
    SPButtonStyleSecondary,
    SPButtonStylePrimary,
    SPButtonStyleCirclePlay,
    SPButtonStyleLink,
    SPButtonStyleDestructive,
};

@interface SPButton : NSView
@property (nonatomic) SPButtonStyle style;
@property (nonatomic) BOOL hasIcon;
@property (nonatomic) SPIconName icon;
@property (nonatomic) CGFloat iconSize;
@property (nonatomic) NSFontWeight iconWeight;
@property (nonatomic) BOOL primaryWhenIdle;
@property (nonatomic) BOOL pillShape;
@property (nonatomic, copy, nullable) NSString *title;
@property (nonatomic, getter=isActive) BOOL active;
@property (nonatomic, getter=isEnabled) BOOL enabled;
@property (nonatomic, copy, nullable) void (^onClick)(void);

+ (instancetype)iconButton:(SPIconName)icon size:(CGFloat)iconSize frame:(NSRect)frame;
+ (instancetype)pillButtonWithTitle:(NSString *)title style:(SPButtonStyle)style frame:(NSRect)frame;
@end

/// Lightweight native-look macOS segmented capsule (exact #1DB954 green selection for pickers, or momentary icon pair for toolbar <|>).
@interface SPSegmentedControl : NSView
@property (nonatomic) NSInteger selectedSegment;
@property (nonatomic) BOOL momentary;
@property (nonatomic, copy, nullable) void (^onSelectSegment)(NSInteger index);

+ (instancetype)segmentedControlWithLabels:(NSArray<NSString *> *)labels;
+ (instancetype)momentaryControlWithIcons:(NSArray<NSNumber *> *)icons iconSize:(CGFloat)iconSize;
- (void)setEnabled:(BOOL)enabled forSegment:(NSInteger)segment;
- (void)sizeToFit;
@end

@interface SPHeartButton : NSView
@property (nonatomic, getter=isFavorited) BOOL favorited;
@property (nonatomic) BOOL primaryWhenUnfavorited;
@property (nonatomic) CGFloat iconPointSize;
@property (nonatomic, copy, nullable) void (^onToggle)(void);
@end

/// Native-styled scrub bar and volume slider with click-to-jump, smooth drag, and optional #1DB954 green track fill.
@interface SPSlider : NSView
@property (nonatomic) double minValue;
@property (nonatomic) double maxValue;
@property (nonatomic) double doubleValue;
@property (nonatomic) BOOL accentFill;
@property (nonatomic) BOOL alwaysShowKnob;
@property (nonatomic, getter=isEnabled) BOOL enabled;
@property (nonatomic, readonly) BOOL isDragging;
@property (nonatomic, copy, nullable) void (^onChange)(double value);
@property (nonatomic, copy, nullable) void (^onCommit)(double value);
@end

/// Always-active Liquid Glass toolbar search capsule: 1-click focus anywhere on pill, clear button, instant keystroke callback.
@interface SPSearchField : NSView <NSTextFieldDelegate>
@property (nonatomic, readonly) NSTextField *textField;
@property (nonatomic, copy) NSString *stringValue;
@property (nonatomic, copy) NSString *placeholderString;
@property (nonatomic, readonly) BOOL isFocused;

@property (nonatomic, copy, nullable) void (^onTextChange)(NSString *text);
@property (nonatomic, copy, nullable) void (^onSubmit)(NSString *text);
@property (nonatomic, copy, nullable) void (^onEscape)(void);
@property (nonatomic, copy, nullable) void (^onFocus)(void);

- (void)focusSelectingAll:(BOOL)selectAll;
- (void)clearAndResign:(BOOL)resign;
/// Programmatic typing helper used by UI tests after 1-click focus.
- (void)typeString:(NSString *)text;
@end

/// Spotifly DetailHeader: 132pt art beside kind, bold title, optional description, metadata (with optional artist link), and actions.
@interface SPDetailHeaderView : NSView
@property (nonatomic, copy) NSString *kindText;
@property (nonatomic, copy) NSString *titleText;
@property (nonatomic, copy, nullable) NSString *descriptionText;
@property (nonatomic, copy, nullable) NSString *metadataLinkText;
@property (nonatomic, copy, nullable) NSString *metadataText;
@property (nonatomic, copy, nullable) NSString *artworkURL;
@property (nonatomic, copy) NSString *placeholderSymbol;
@property (nonatomic) BOOL artworkCircular;
@property (nonatomic) BOOL isFavoritesHeader;

@property (nonatomic) BOOL showPlayButton;
@property (nonatomic) BOOL playEnabled;
@property (nonatomic) BOOL showShuffleButton;
@property (nonatomic) BOOL showLibraryButton;
@property (nonatomic) BOOL libraryButtonOn;
@property (nonatomic, copy) NSString *libraryOnTitle;
@property (nonatomic, copy) NSString *libraryOffTitle;
@property (nonatomic) BOOL showMoreButton;

@property (nonatomic, copy, nullable) void (^onPlay)(void);
@property (nonatomic, copy, nullable) void (^onShuffle)(void);
@property (nonatomic, copy, nullable) void (^onLibraryToggle)(void);
@property (nonatomic, copy, nullable) void (^onMore)(NSView *anchorView);
@property (nonatomic, copy, nullable) void (^onMetadataLink)(void);

+ (CGFloat)preferredHeightForWidth:(CGFloat)width hasDescription:(BOOL)hasDescription;
@end

typedef NS_ENUM(NSInteger, SPTrackSortColumn) {
    SPTrackSortNone = 0,
    SPTrackSortNumber,
    SPTrackSortTitle,
    SPTrackSortAlbum,
    SPTrackSortDuration,
};

/// Non-layer-backed track table row; attaches SPWaveformView ONLY when this row is actively playing.
@interface SPTrackRowView : SPListRowView
@property (nonatomic, strong, nullable) SPTrack *track;
@property (nonatomic) NSUInteger displayNumber;
@property (nonatomic) BOOL showArtwork;
@property (nonatomic) BOOL showAlbumColumn;
@property (nonatomic) BOOL isPlayingTrack;
@property (nonatomic) BOOL isAudioPlaying;
@property (nonatomic) BOOL isFavorited;
@property (nonatomic) BOOL isDimmed;
@property (nonatomic, copy, nullable) NSString *badgeTag;
@property (nonatomic, readonly) SPHeartButton *heartButton;
@property (nonatomic, readonly) BOOL hasWaveformAttached;
@property (nonatomic, copy, nullable) void (^onToggleFavorite)(SPTrack *track);
@property (nonatomic, copy, nullable) void (^onMoreClick)(SPTrack *track, NSView *anchor);
@property (nonatomic, copy, nullable) void (^onClickArtist)(SPTrack *track);
@property (nonatomic, copy, nullable) void (^onClickAlbum)(SPTrack *track);
@end

/// Reusable virtualized track list supporting single-row heart redraws, 30 fps waveform on playing row,
/// optional sortable column header, double-click playback, and right-click / ellipsis context menu.
@interface SPTrackListView : SPListView
@property (nonatomic, weak, nullable) id<SPNavigator> navigator;
@property (nonatomic, weak, nullable) SPStore *store;
@property (nonatomic, copy) NSArray<SPTrack *> *tracks;
@property (nonatomic, copy, nullable) NSString *contextURI;
@property (nonatomic) BOOL showArtwork;
@property (nonatomic) BOOL showAlbumColumn;
@property (nonatomic) BOOL showColumnHeader;
@property (nonatomic) BOOL sortable;
@property (nonatomic) BOOL playWithSongRadio;
@property (nonatomic, copy, nullable) NSArray<NSMenuItem *> *_Nullable (^extraMenuItemsProvider)(SPTrack *track, NSUInteger index);

- (instancetype)initWithFrame:(NSRect)frame store:(SPStore *)store navigator:(nullable id<SPNavigator>)navigator;
/// Updates only visible rows affected by a favorite or playback change.
- (void)applyStoreChange:(SPChange *)change;
/// Refreshes playing-row waveform indicator when current track or play/pause state changes.
- (void)syncPlaybackState;
@end

NS_ASSUME_NONNULL_END
