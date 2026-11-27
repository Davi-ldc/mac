// Library screens: Favorites (DetailHeader + TrackTable) and 3-column filterable Master Lists
// (Playlists, Albums, Artists) matching Spotifly 1:1.
#import <AppKit/AppKit.h>

#import "store/store.h"
#import "ui/kit/controls.h"
#import "ui/kit/grid.h"
#import "ui/kit/nav.h"

NS_ASSUME_NONNULL_BEGIN

@interface SPFavoritesView : NSView <SPChangeObserver>
@property (nonatomic, weak, nullable) id<SPNavigator> navigator;
@property (nonatomic, readonly) SPTrackListView *trackList;
@property (nonatomic, copy) NSString *filterText;

- (instancetype)initWithFrame:(NSRect)frame store:(SPStore *)store navigator:(nullable id<SPNavigator>)navigator;
- (void)reloadTracks;
@end

typedef NS_ENUM(NSInteger, SPLibraryListKind) {
    SPLibraryListPlaylists = 0,
    SPLibraryListAlbums,
    SPLibraryListArtists,
};

typedef NS_ENUM(NSInteger, SPAlbumSortOrder) {
    SPAlbumSortRecentlyAdded = 0,
    SPAlbumSortTitle,
    SPAlbumSortArtist,
};

/// 3-column master list column (Filter field + virtualized artwork rows with hover Play button) matching Spotifly LibraryListView.
@interface SPLibraryListView : NSView <SPChangeObserver, NSTextFieldDelegate>
@property (nonatomic, readonly) SPLibraryListKind kind;
@property (nonatomic, weak, nullable) id<SPNavigator> navigator;
@property (nonatomic, copy, nullable) NSString *selectedEntityID;
@property (nonatomic) SPAlbumSortOrder albumSortOrder;

- (instancetype)initWithFrame:(NSRect)frame
                         kind:(SPLibraryListKind)kind
                        store:(SPStore *)store
                    navigator:(nullable id<SPNavigator>)navigator;
- (void)reloadItems;
/// Returns the first entity ID in the list for automatic initial selection (matching Spotifly selectFirstIfNeeded).
- (nullable NSString *)firstEntityID;
@end

// Kept for backward compatibility if referenced directly.
@interface SPAlbumsGridView : NSView <SPChangeObserver>
@property (nonatomic, weak, nullable) id<SPNavigator> navigator;
@property (nonatomic, readonly) SPCardGridView *gridView;
- (instancetype)initWithFrame:(NSRect)frame store:(SPStore *)store navigator:(nullable id<SPNavigator>)navigator;
- (void)reloadAlbums;
@end

@interface SPArtistsGridView : NSView <SPChangeObserver>
@property (nonatomic, weak, nullable) id<SPNavigator> navigator;
@property (nonatomic, readonly) SPCardGridView *gridView;
- (instancetype)initWithFrame:(NSRect)frame store:(SPStore *)store navigator:(nullable id<SPNavigator>)navigator;
- (void)reloadArtists;
@end

@interface SPPlaylistsGridView : NSView <SPChangeObserver>
@property (nonatomic, weak, nullable) id<SPNavigator> navigator;
@property (nonatomic, readonly) SPCardGridView *gridView;
- (instancetype)initWithFrame:(NSRect)frame store:(SPStore *)store navigator:(nullable id<SPNavigator>)navigator;
- (void)reloadPlaylists;
@end

NS_ASSUME_NONNULL_END
