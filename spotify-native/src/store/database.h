// SQLite WAL persistence with cached prepared statements and normalized domain tables.
#import <Foundation/Foundation.h>

#import "model/album.h"
#import "model/artist.h"
#import "model/playlist.h"
#import "model/shelf.h"
#import "model/track.h"

NS_ASSUME_NONNULL_BEGIN

@interface SPDatabase : NSObject
+ (nullable instancetype)databaseAtURL:(NSURL *)url;
@property (class, nonatomic, readonly) NSURL *defaultFolder;
+ (NSURL *)URLForAccount:(NSString *)account;

@property (nonatomic, readonly, copy) NSString *journalMode;
@property (nonatomic, readonly) int schemaVersion;

- (void)transaction:(void (^)(void))block;
- (void)setBusyTimeoutMs:(int)timeoutMs;
- (void)releaseMemory;
- (void)close;
- (void)deleteFile;

// Normalized entity tables
- (void)upsertTrack:(SPTrack *)track;
- (NSArray<SPTrack *> *)allTracks;

- (void)upsertAlbum:(SPAlbum *)album;
- (NSArray<SPAlbum *> *)allAlbums;

- (void)upsertArtist:(SPArtist *)artist;
- (NSArray<SPArtist *> *)allArtists;

- (void)upsertPlaylist:(SPPlaylist *)playlist;
- (NSArray<SPPlaylist *> *)allPlaylists;
- (void)replacePlaylistTracks:(NSArray<SPPlaylistItem *> *)items forPlaylistID:(NSString *)playlistID;
- (NSArray<SPPlaylistItem *> *)playlistTracksForPlaylistID:(NSString *)playlistID;

// Ordered library membership tables
- (void)replaceLibraryTrackIDs:(NSArray<NSString *> *)trackIDs addedAtByID:(nullable NSDictionary<NSString *, NSNumber *> *)addedAt;
- (void)appendLibraryTrackIDs:(NSArray<NSString *> *)trackIDs addedAtByID:(nullable NSDictionary<NSString *, NSNumber *> *)addedAt;
- (NSArray<NSString *> *)libraryTrackIDs;
- (NSDictionary<NSString *, NSNumber *> *)libraryTrackAddedAtByID;
- (void)insertLibraryTrackID:(NSString *)trackID atPosition:(NSInteger)position addedAt:(double)addedAt;
- (void)deleteLibraryTrackID:(NSString *)trackID;

- (void)replaceLibraryAlbumIDs:(NSArray<NSString *> *)albumIDs addedAtByID:(nullable NSDictionary<NSString *, NSNumber *> *)addedAt;
- (NSArray<NSString *> *)libraryAlbumIDs;

- (void)replaceLibraryArtistIDs:(NSArray<NSString *> *)artistIDs;
- (NSArray<NSString *> *)libraryArtistIDs;

- (void)replaceLibraryPlaylistIDs:(NSArray<NSString *> *)playlistIDs;
- (NSArray<NSString *> *)libraryPlaylistIDs;

// Home shelves & recent searches
- (void)replaceHomeShelves:(NSArray<SPHomeShelf *> *)shelves;
- (NSArray<SPHomeShelf *> *)allHomeShelves;

- (void)replaceRecentSearches:(NSArray<NSString *> *)queries;
- (NSArray<NSString *> *)allRecentSearches;

// Key-value metadata (profile, sync cursors, preferences)
- (nullable id)jsonForKey:(NSString *)key;
- (void)setJSON:(nullable id)value forKey:(NSString *)key;
@end

NS_ASSUME_NONNULL_END
