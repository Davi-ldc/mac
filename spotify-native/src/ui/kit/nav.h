// Navigation routes and action protocol decoupling ui/ feature panes from ui/shell (strict acyclic DAG).
#import <AppKit/AppKit.h>

#import "model/track.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SPRouteKind) {
    SPRouteHome = 0,
    SPRouteSearch,
    SPRouteFavorites,
    SPRouteAlbums,
    SPRouteArtists,
    SPRoutePlaylists,
    SPRouteAlbumDetail,
    SPRouteArtistDetail,
    SPRoutePlaylistDetail,
    SPRouteQueue,
    SPRouteSpeakers,
    SPRouteProfile,
};

@interface SPRoute : NSObject <NSCopying>
@property (nonatomic, readonly) SPRouteKind kind;
@property (nonatomic, readonly, copy, nullable) NSString *entityID;

+ (instancetype)home;
+ (instancetype)search;
+ (instancetype)favorites;
+ (instancetype)albums;
+ (instancetype)artists;
+ (instancetype)playlists;
+ (instancetype)queue;
+ (instancetype)speakers;
+ (instancetype)profile;
+ (instancetype)albumWithID:(NSString *)albumID;
+ (instancetype)artistWithID:(NSString *)artistID;
+ (instancetype)playlistWithID:(NSString *)playlistID;

- (instancetype)initWithKind:(SPRouteKind)kind entityID:(nullable NSString *)entityID NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

@protocol SPNavigator <NSObject>
@property (nonatomic, readonly) SPRoute *currentRoute;
@property (nonatomic, readonly) BOOL canGoBack;
@property (nonatomic, readonly) BOOL canGoForward;
@property (nonatomic, readonly) BOOL queueDrawerOpen;
@property (nonatomic, readonly) BOOL inspectorOpen;

// Route navigation
- (void)openHome;
- (void)openSearchWithQuery:(nullable NSString *)query focus:(BOOL)focus;
- (void)openQueue;
- (void)openSpeakers;
- (void)openProfile;
- (void)openFavorites;
- (void)openAlbums;
- (void)openArtists;
- (void)openPlaylists;
- (void)openAlbumWithID:(NSString *)albumID;
- (void)openArtistWithID:(NSString *)artistID;
- (void)openPlaylistWithID:(NSString *)playlistID;
- (void)goBack;
- (void)goForward;

// Playback & queue actions
- (void)playTrack:(SPTrack *)track
     inContextURI:(nullable NSString *)contextURI
       trackIndex:(NSInteger)trackIndex
     fallbackURIs:(nullable NSArray<NSString *> *)fallbackURIs;
- (void)playTrackWithRadio:(SPTrack *)track fallbackURIs:(nullable NSArray<NSString *> *)fallbackURIs;
- (void)playContextURI:(NSString *)contextURI;
- (void)togglePlayPause;
- (void)skipNext;
- (void)skipPrevious;
- (void)seekToMs:(int64_t)positionMs;
- (void)toggleShuffle;
- (void)setShuffleEnabled:(BOOL)enabled;
- (void)cycleRepeatMode;
- (void)previewVolumePercent:(NSInteger)percent;
- (void)setVolumePercent:(NSInteger)percent;
- (void)toggleMute;
- (void)toggleFavoriteTrackID:(NSString *)trackID;
- (void)addTrackToQueue:(SPTrack *)track;
- (void)skipToQueueIndex:(NSInteger)queueIndex;

// Library & Playlist CRUD
- (void)promptCreatePlaylist;
- (void)createPlaylistWithName:(NSString *)name description:(nullable NSString *)description;
- (void)renamePlaylistID:(NSString *)playlistID toName:(NSString *)newName;
- (void)deletePlaylistID:(NSString *)playlistID;
- (void)removeTrackID:(NSString *)trackID fromPlaylistID:(NSString *)playlistID;
- (void)removeTrackID:(NSString *)trackID uid:(nullable NSString *)uid fromPlaylistID:(NSString *)playlistID;
- (void)toggleSaveAlbumID:(NSString *)albumID;
- (void)toggleFollowArtistID:(NSString *)artistID;
- (void)toggleFollowPlaylistID:(NSString *)playlistID;

// Toolbar / overlays / search / data refresh
- (void)toggleQueueDrawer;
- (void)toggleInspector;
- (void)toggleSpeakersPopoverFromView:(NSView *)anchorView;
- (void)transferPlaybackToDeviceID:(NSString *)deviceID;
- (void)reconnectSpotify;
- (void)refreshCurrentSection;
- (void)requestTopContentForRange:(NSString *)rangeKey;
- (void)openPreferences;
- (void)signOut;
- (void)focusSearchFieldSelectingAll:(BOOL)selectAll;
- (void)setSearchQuery:(NSString *)query;
@end

NS_ASSUME_NONNULL_END
