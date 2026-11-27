// Normalized domain store backed by SQLite WAL with in-place derived lists and <1 ms local search.
#import <Foundation/Foundation.h>

#import "model/album.h"
#import "model/artist.h"
#import "model/device.h"
#import "model/playback.h"
#import "model/playlist.h"
#import "model/search.h"
#import "model/shelf.h"
#import "model/track.h"
#import "store/change.h"
#import "store/database.h"

NS_ASSUME_NONNULL_BEGIN

@interface SPStore : NSObject
@property (nonatomic, readonly, nullable) SPDatabase *database;
@property (nonatomic, readonly) SPChangeQueue *changes;

// Derived ordered library lists maintained in place on write (zero ad-hoc caches).
@property (nonatomic, readonly) NSArray<SPTrack *> *libraryTracks;
@property (nonatomic, readonly) NSArray<SPAlbum *> *libraryAlbums;
@property (nonatomic, readonly) NSArray<SPArtist *> *libraryArtists;
@property (nonatomic, readonly) NSArray<SPPlaylist *> *libraryPlaylists;
@property (nonatomic, readonly) NSArray<SPHomeShelf *> *homeShelves;
@property (nonatomic, readonly) NSArray<NSString *> *recentSearches;

@property (nonatomic, readonly, nullable) SPUserProfile *userProfile;
@property (nonatomic, readonly, nullable) SPPlaybackState *playbackState;
@property (nonatomic, readonly) NSArray<SPDevice *> *devices;
@property (nonatomic, readonly, copy, nullable) NSString *activeDeviceID;
@property (nonatomic, readonly) BOOL isConnected;

- (instancetype)initWithDatabase:(nullable SPDatabase *)database NS_DESIGNATED_INITIALIZER;
- (instancetype)init;

- (void)addObserver:(id<SPChangeObserver>)observer;
- (void)removeObserver:(id<SPChangeObserver>)observer;

// Entity lookups
- (nullable SPTrack *)trackWithID:(NSString *)trackID;
- (nullable SPAlbum *)albumWithID:(NSString *)albumID;
- (nullable SPArtist *)artistWithID:(NSString *)artistID;
- (nullable SPPlaylist *)playlistWithID:(NSString *)playlistID;
- (BOOL)isFavoriteTrackID:(NSString *)trackID;
- (BOOL)hasResolvedFavoriteStatusForTrackID:(NSString *)trackID;

// Normalized writes (persist to SQLite WAL + update derived lists in place + coalesce SPChange).
- (void)upsertTracks:(NSArray<SPTrack *> *)tracks;
- (void)upsertAlbums:(NSArray<SPAlbum *> *)albums;
- (void)upsertArtists:(NSArray<SPArtist *> *)artists;
- (void)upsertPlaylists:(NSArray<SPPlaylist *> *)playlists;

- (void)setLibraryTrackIDs:(NSArray<NSString *> *)trackIDs addedAtByID:(nullable NSDictionary<NSString *, NSNumber *> *)addedAt;
- (void)appendLibraryTrackIDs:(NSArray<NSString *> *)trackIDs addedAtByID:(nullable NSDictionary<NSString *, NSNumber *> *)addedAt;
- (void)setLibraryAlbumIDs:(NSArray<NSString *> *)albumIDs addedAtByID:(nullable NSDictionary<NSString *, NSNumber *> *)addedAt;
- (void)setLibraryArtistIDs:(NSArray<NSString *> *)artistIDs;
- (void)setLibraryPlaylistIDs:(NSArray<NSString *> *)playlistIDs;

/// Single-row favorite heart toggle: updates memory, derived libraryTracks, search index, and SQLite in place.
/// Returns the new favorite state (YES = now favorited, NO = removed).
- (BOOL)toggleFavoriteTrackID:(NSString *)trackID;
- (void)setFavorite:(BOOL)favorite forTrackID:(NSString *)trackID;
- (void)updateFavoriteStatuses:(NSDictionary<NSString *, NSNumber *> *)statuses;

- (void)applyHomePage:(SPHomePage *)homePage;
- (void)setUserProfile:(nullable SPUserProfile *)profile;
- (void)recordRecentSearch:(NSString *)query;
- (void)removeRecentSearch:(NSString *)query;
- (void)clearRecentSearches;

- (void)applyClusterState:(SPClusterState *)cluster;
- (void)setPlaybackState:(nullable SPPlaybackState *)state;
- (void)setConnected:(BOOL)connected;

/// Sub-millisecond case- and diacritic-insensitive local library search ranked by exact/prefix match.
- (SPSearchResults *)searchLocal:(NSString *)query limitPerKind:(NSUInteger)limit;
- (SPSearchResults *)searchLocal:(NSString *)query;
@end

NS_ASSUME_NONNULL_END
