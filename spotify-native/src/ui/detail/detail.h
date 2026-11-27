// Spotifly 1:1 Detail screens: Album, Artist (with Discography filter), Playlist, User Profile, and Empty Detail placeholder.
#import <AppKit/AppKit.h>

#import "store/store.h"
#import "ui/kit/controls.h"
#import "ui/kit/grid.h"
#import "ui/kit/nav.h"

NS_ASSUME_NONNULL_BEGIN

@interface SPAlbumDetailView : NSView <SPChangeObserver>
@property (nonatomic, copy, readonly) NSString *albumID;
@property (nonatomic, weak, nullable) id<SPNavigator> navigator;
@property (nonatomic, readonly) SPTrackListView *trackList;

- (instancetype)initWithFrame:(NSRect)frame albumID:(NSString *)albumID store:(SPStore *)store navigator:(nullable id<SPNavigator>)navigator;
- (void)reloadData;
@end

@interface SPArtistDetailView : NSView <SPChangeObserver>
@property (nonatomic, copy, readonly) NSString *artistID;
@property (nonatomic, weak, nullable) id<SPNavigator> navigator;
@property (nonatomic, readonly) SPTrackListView *topTracksList;
@property (nonatomic, readonly) SPCardGridView *discographyGrid;

- (instancetype)initWithFrame:(NSRect)frame artistID:(NSString *)artistID store:(SPStore *)store navigator:(nullable id<SPNavigator>)navigator;
- (void)reloadData;
@end

@interface SPPlaylistDetailView : NSView <SPChangeObserver>
@property (nonatomic, copy, readonly) NSString *playlistID;
@property (nonatomic, weak, nullable) id<SPNavigator> navigator;
@property (nonatomic, readonly) SPTrackListView *trackList;

- (instancetype)initWithFrame:(NSRect)frame playlistID:(NSString *)playlistID store:(SPStore *)store navigator:(nullable id<SPNavigator>)navigator;
- (void)reloadData;
@end

/// Spotifly 1:1 UserProfileView (centered 96pt avatar, Account card, Manage Account / Settings, Log Out).
@interface SPProfileView : NSView <SPChangeObserver>
@property (nonatomic, weak, nullable) id<SPNavigator> navigator;
- (instancetype)initWithFrame:(NSRect)frame store:(SPStore *)store navigator:(nullable id<SPNavigator>)navigator;
@end

/// Centered empty detail placeholder for 3-column sections when no entity is selected.
@interface SPEmptyDetailView : NSView
@property (nonatomic, copy) NSString *message;
@property (nonatomic, copy, nullable) NSString *symbolName;
- (instancetype)initWithFrame:(NSRect)frame message:(NSString *)message symbolName:(nullable NSString *)symbolName;
@end

NS_ASSUME_NONNULL_END
