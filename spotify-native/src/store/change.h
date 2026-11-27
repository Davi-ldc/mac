// Coalesced per-run-loop-turn state change delivery (runs before Core Animation commit at order 0).
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, SPChangeKind) {
    // Kinds carrying entity ID sets (must stay contiguous before SPChangeLibraryLists).
    SPChangeTracks = 0,
    SPChangeAlbums,
    SPChangeArtists,
    SPChangePlaylists,
    SPChangeFavorites,

    // Flag-only kinds.
    SPChangeLibraryLists,
    SPChangeHomeShelves,
    SPChangeSearch,
    SPChangePlayback,
    SPChangeDevices,
    SPChangeConnection,
    SPChangeProfile,
    SPChangeRecentSearches,
};

@interface SPChange : NSObject
- (void)add:(SPChangeKind)kind value:(nullable NSString *)value;
@property (nonatomic, readonly) BOOL isEmpty;

@property (nonatomic, readonly, nullable) NSSet<NSString *> *tracks;
@property (nonatomic, readonly, nullable) NSSet<NSString *> *albums;
@property (nonatomic, readonly, nullable) NSSet<NSString *> *artists;
@property (nonatomic, readonly, nullable) NSSet<NSString *> *playlists;
@property (nonatomic, readonly, nullable) NSSet<NSString *> *favorites;

@property (nonatomic, readonly) BOOL libraryLists;
@property (nonatomic, readonly) BOOL homeShelves;
@property (nonatomic, readonly) BOOL search;
@property (nonatomic, readonly) BOOL playback;
@property (nonatomic, readonly) BOOL devices;
@property (nonatomic, readonly) BOOL connection;
@property (nonatomic, readonly) BOOL profile;
@property (nonatomic, readonly) BOOL recentSearches;
@end

@protocol SPChangeObserver <NSObject>
- (void)storeChanged:(SPChange *)change;
@end

@interface SPChangeQueue : NSObject
- (void)addObserver:(id<SPChangeObserver>)observer;
- (void)removeObserver:(id<SPChangeObserver>)observer;
- (void)note:(SPChangeKind)kind value:(nullable NSString *)value;
@end

/// Flushes every pending queue immediately (up to 8 re-entrant rounds; wakes the next run-loop turn if more remain).
void SPFlushChanges(void);

NS_ASSUME_NONNULL_END
