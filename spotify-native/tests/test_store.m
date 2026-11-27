// Store, ChangeQueue, SQLite WAL persistence, favorite toggle, and <1 ms local search benchmark tests.
#import "test.h"
#import "model/album.h"
#import "model/artist.h"
#import "model/playlist.h"
#import "model/shelf.h"
#import "model/track.h"
#import "store/change.h"
#import "store/database.h"
#import "store/store.h"

#import <mach/mach_time.h>
#import <stdio.h>

@interface SPTestChangeRecorder : NSObject <SPChangeObserver>
@property (nonatomic, strong) NSMutableArray<SPChange *> *received;
@property (nonatomic, copy, nullable) void (^onChange)(SPChange *change);
@end

@implementation SPTestChangeRecorder
- (instancetype)init {
    if (!(self = [super init])) return nil;
    _received = [NSMutableArray new];
    return self;
}
- (void)storeChanged:(SPChange *)change {
    [_received addObject:change];
    if (_onChange) _onChange(change);
}
@end

static SPTrack *MakeTrack(NSString *tid, NSString *name, NSString *artist, NSString *album, NSInteger durMs) {
    return [[SPTrack alloc] initWithTrackID:tid
                                        uri:[NSString stringWithFormat:@"spotify:track:%@", tid]
                                       name:name
                                    albumID:@"alb-0"
                                  albumName:album
                                   artistID:@"art-0"
                                 artistName:artist
                                artistNames:@[ artist ]
                                 durationMs:durMs
                                trackNumber:1
                                 discNumber:1
                                 artworkURL:@"https://i.scdn.co/image/large"
                            artworkSmallURL:@"https://i.scdn.co/image/small"
                                   playable:YES
                           unplayableReason:nil];
}

static double MachNowMs(void) {
    static mach_timebase_info_data_t tb;
    if (tb.denom == 0) mach_timebase_info(&tb);
    return (double)mach_absolute_time() * (double)tb.numer / (double)tb.denom / 1e6;
}

SP_TEST(ChangeQueueCoalescingAndReentrantWakeup) {
    SPChangeQueue *q = [SPChangeQueue new];
    SPTestChangeRecorder *rec = [SPTestChangeRecorder new];
    [q addObserver:rec];

    [q note:SPChangeTracks value:@"t1"];
    [q note:SPChangeTracks value:@"t2"];
    [q note:SPChangeFavorites value:@"t1"];
    [q note:SPChangePlayback value:nil];
    [q note:SPChangeDevices value:nil];

    SPExpectEqualInt(rec.received.count, 0, "changes coalesce until flush/run-loop end");
    SPFlushChanges();
    SPExpectEqualInt(rec.received.count, 1, "burst delivered as a single SPChange");

    SPChange *c = rec.received.firstObject;
    SPExpect([c.tracks isEqualToSet:([NSSet setWithArray:@[ @"t1", @"t2" ]])], @"tracks set coalesced");
    SPExpect([c.favorites isEqualToSet:([NSSet setWithArray:@[ @"t1" ]])], @"favorites set coalesced");
    SPExpect(c.playback && c.devices && !c.homeShelves, @"flag bits coalesced accurately");

    // Re-entrant observer exceeding 8-round cap must schedule wakeup and never strand remaining changes.
    [rec.received removeAllObjects];
    __block int remaining = 12;
    rec.onChange = ^(SPChange *change) {
        (void)change;
        if (remaining > 0) {
            remaining--;
            [q note:SPChangeTracks value:[NSString stringWithFormat:@"re-%d", remaining]];
        }
    };
    [q note:SPChangeTracks value:@"seed"];
    SPFlushChanges();
    // First SPFlushChanges caps at 8 rounds; remaining rounds wake on the next run-loop turn.
    BOOL drained = SPWaitUntil(1.0, ^BOOL { return remaining == 0 && rec.received.count == 13; });
    SPExpect(drained, @"re-entrant changes beyond 8-round cap drained via run-loop wakeup (remaining=%d, count=%lu)",
             remaining, (unsigned long)rec.received.count);
    [q removeObserver:rec];
}

SP_TEST(StoreSQLiteWALPersistenceAcrossReopen) {
    NSURL *dir = SPTestTempDirectory(@"sp-store-wal");
    NSURL *dbURL = [dir URLByAppendingPathComponent:@"account.sqlite"];

    SPDatabase *db1 = [SPDatabase databaseAtURL:dbURL];
    SPExpect(db1 != nil, @"database opened");
    SPExpectEqualStr(db1.journalMode.lowercaseString, @"wal", "PRAGMA journal_mode is WAL");
    SPExpectEqualInt(db1.schemaVersion, 1, "schema version is 1");

    SPStore *store1 = [[SPStore alloc] initWithDatabase:db1];
    SPTrack *t1 = MakeTrack(@"t1", @"Midnight City", @"M83", @"Hurry Up, We're Dreaming", 243000);
    SPTrack *t2 = MakeTrack(@"t2", @"Intro", @"M83", @"Hurry Up, We're Dreaming", 262000);
    SPAlbum *alb1 = [[SPAlbum alloc] initWithAlbumID:@"a1"
                                                 uri:@"spotify:album:a1"
                                                name:@"Hurry Up, We're Dreaming"
                                           albumType:@"ALBUM"
                                            artistID:@"ar1"
                                          artistName:@"M83"
                                         artistNames:@[ @"M83" ]
                                         releaseDate:@"2011-10-18"
                                          artworkURL:@"https://i.scdn.co/image/a1"
                                     artworkSmallURL:@"https://i.scdn.co/image/a1s"
                                            trackIDs:@[ @"t2", @"t1" ]
                                     totalTrackCount:2
                                     totalDurationMs:505000
                                       detailsLoaded:YES];
    SPArtist *ar1 = [[SPArtist alloc] initWithArtistID:@"ar1"
                                                   uri:@"spotify:artist:ar1"
                                                  name:@"M83"
                                            artworkURL:@"https://i.scdn.co/image/ar1"
                                       artworkSmallURL:nil
                                              albumIDs:@[ @"a1" ]
                                         detailsLoaded:YES];
    SPPlaylistItem *pi1 = [[SPPlaylistItem alloc] initWithTrackID:@"t1" uid:@"uid-1" addedAt:1700000100.0];
    SPPlaylist *pl1 = [[SPPlaylist alloc] initWithPlaylistID:@"pl1"
                                                         uri:@"spotify:playlist:pl1"
                                                        name:@"Night Drive"
                                         playlistDescription:@"Synth classics"
                                                     ownerID:@"user1"
                                                   ownerName:@"Alice"
                                                  artworkURL:@"https://i.scdn.co/image/pl1"
                                             artworkSmallURL:nil
                                                    isPublic:YES
                                                       items:@[ pi1 ]
                                             totalTrackCount:1
                                               detailsLoaded:YES];

    [store1 upsertTracks:@[ t1, t2 ]];
    [store1 upsertAlbums:@[ alb1 ]];
    [store1 upsertArtists:@[ ar1 ]];
    [store1 upsertPlaylists:@[ pl1 ]];
    [store1 setLibraryTrackIDs:@[ @"t1", @"t2" ] addedAtByID:@{@"t1" : @1700000200, @"t2" : @1700000100}];
    [store1 setLibraryAlbumIDs:@[ @"a1" ] addedAtByID:@{@"a1" : @1700000300}];
    [store1 setLibraryArtistIDs:@[ @"ar1" ]];
    [store1 setLibraryPlaylistIDs:@[ @"pl1" ]];

    // Summary album upsert must NOT overwrite detailsLoaded album.
    SPAlbum *stubAlb = [[SPAlbum alloc] initWithAlbumID:@"a1"
                                                    uri:@"spotify:album:a1"
                                                   name:@"Hurry Up, We're Dreaming"
                                              albumType:@"ALBUM"
                                               artistID:@"ar1"
                                             artistName:@"M83"
                                            artistNames:@[ @"M83" ]
                                            releaseDate:@"2011"
                                             artworkURL:nil
                                        artworkSmallURL:nil
                                               trackIDs:@[]
                                        totalTrackCount:0
                                        totalDurationMs:0
                                          detailsLoaded:NO];
    [store1 upsertAlbums:@[ stubAlb ]];
    SPExpect([store1 albumWithID:@"a1"].detailsLoaded, @"detailsLoaded album preserved against summary stub");
    SPExpectEqualInt([store1 albumWithID:@"a1"].trackIDs.count, 2, "album trackIDs preserved");

    SPShelfItem *si = [[SPShelfItem alloc] initWithKind:SPShelfItemAlbum
                                               entityID:@"a1"
                                                  title:@"Hurry Up, We're Dreaming"
                                               subtitle:@"M83"
                                             artworkURL:@"https://i.scdn.co/image/a1"];
    SPHomeShelf *shelf = [[SPHomeShelf alloc] initWithShelfID:@"shelf-1"
                                                        title:@"Jump back in"
                                             isRecentlyPlayed:NO
                                                        items:@[ si ]];
    SPHomePage *page = [[SPHomePage alloc] initWithShelves:@[ shelf ] albums:@[ stubAlb ] artists:@[] playlists:@[]];
    [store1 applyHomePage:page];

    SPUserProfile *prof = [[SPUserProfile alloc] initWithUsername:@"alice42"
                                                      displayName:@"Alice"
                                                              uri:@"spotify:user:alice42"
                                                        avatarURL:@"https://i.scdn.co/image/av"];
    [store1 setUserProfile:prof];
    [store1 recordRecentSearch:@"daft punk"];
    [store1 recordRecentSearch:@"m83"];
    [store1 recordRecentSearch:@"daft punk"]; // moves to top, deduplicated

    [db1 close];

    // Reopen fresh SPDatabase + SPStore from disk and verify full restoration.
    SPDatabase *db2 = [SPDatabase databaseAtURL:dbURL];
    SPExpect(db2 != nil, @"reopened database");
    SPStore *store2 = [[SPStore alloc] initWithDatabase:db2];

    SPExpectEqualInt(store2.libraryTracks.count, 2, "reopened libraryTracks count");
    SPExpectEqualStr(store2.libraryTracks[0].trackID, @"t1", "reopened track order 0");
    SPExpectEqualStr(store2.libraryTracks[1].trackID, @"t2", "reopened track order 1");
    SPExpect([store2 isFavoriteTrackID:@"t1"], @"t1 restored as favorite");
    SPExpectEqualInt(store2.libraryAlbums.count, 1, "reopened libraryAlbums count");
    SPExpect([store2 albumWithID:@"a1"].detailsLoaded, @"reopened album detailsLoaded");
    SPExpectEqualInt([store2 albumWithID:@"a1"].trackIDs.count, 2, "reopened album trackIDs");
    SPExpectEqualInt(store2.libraryArtists.count, 1, "reopened libraryArtists count");
    SPExpectEqualInt(store2.libraryPlaylists.count, 1, "reopened libraryPlaylists count");
    SPExpectEqualInt([store2 playlistWithID:@"pl1"].items.count, 1, "reopened playlist items");
    SPExpectEqualStr([store2 playlistWithID:@"pl1"].items[0].uid, @"uid-1", "reopened playlist item uid");
    SPExpectEqualInt(store2.homeShelves.count, 1, "reopened home shelves count");
    SPExpectEqualStr(store2.homeShelves[0].title, @"Jump back in", "reopened home shelf title");
    SPExpectEqualStr(store2.userProfile.username, @"alice42", "reopened user profile");
    SPExpectEqualInt(store2.recentSearches.count, 2, "reopened recent searches deduplicated");
    SPExpectEqualStr(store2.recentSearches[0], @"daft punk", "most recent search first");

    [db2 deleteFile];
    [NSFileManager.defaultManager removeItemAtURL:dir error:nil];
}

SP_TEST(StoreFavoriteToggleInPlace) {
    NSURL *dir = SPTestTempDirectory(@"sp-store-fav");
    NSURL *dbURL = [dir URLByAppendingPathComponent:@"fav.sqlite"];
    SPDatabase *db = [SPDatabase databaseAtURL:dbURL];
    SPStore *store = [[SPStore alloc] initWithDatabase:db];

    SPTrack *t1 = MakeTrack(@"t1", @"Alpha", @"Artist A", @"Album A", 180000);
    SPTrack *t2 = MakeTrack(@"t2", @"Beta", @"Artist B", @"Album B", 200000);
    SPTrack *t3 = MakeTrack(@"t3", @"Gamma", @"Artist C", @"Album C", 210000);
    [store upsertTracks:@[ t1, t2, t3 ]];
    [store setLibraryTrackIDs:@[ @"t1", @"t2" ] addedAtByID:nil];
    SPFlushChanges();

    SPTestChangeRecorder *rec = [SPTestChangeRecorder new];
    [store addObserver:rec];

    // Toggle t3 ON -> prepended to libraryTracks in place and searchable immediately.
    BOOL nowFav = [store toggleFavoriteTrackID:@"t3"];
    SPExpect(nowFav, @"t3 toggled on");
    SPExpect([store isFavoriteTrackID:@"t3"], @"t3 is favorite");
    SPExpectEqualInt(store.libraryTracks.count, 3, "libraryTracks updated in place to 3");
    SPExpectEqualStr(store.libraryTracks[0].trackID, @"t3", "newly favorited track at position 0");
    SPExpectEqualInt([store searchLocal:@"Gamma"].tracks.count, 1, "local search index updated in place on add");

    SPFlushChanges();
    SPExpectEqualInt(rec.received.count, 1, "single coalesced change delivered");
    SPExpect([rec.received[0].favorites containsObject:@"t3"], @"favorites change includes t3");

    // Toggle t1 OFF -> removed in place from libraryTracks and local search index.
    [rec.received removeAllObjects];
    BOOL afterOff = [store toggleFavoriteTrackID:@"t1"];
    SPExpect(!afterOff, @"t1 toggled off");
    SPExpect(![store isFavoriteTrackID:@"t1"], @"t1 no longer favorite");
    SPExpectEqualInt(store.libraryTracks.count, 2, "libraryTracks updated in place to 2");
    SPExpectEqualInt([store searchLocal:@"Alpha"].tracks.count, 0, "local search index updated in place on remove");

    // Verify SQLite matches in-memory state after reopen.
    [db close];
    SPDatabase *db2 = [SPDatabase databaseAtURL:dbURL];
    SPStore *store2 = [[SPStore alloc] initWithDatabase:db2];
    SPExpectEqualInt(store2.libraryTracks.count, 2, "reopened favorites count after toggle");
    SPExpect([store2 isFavoriteTrackID:@"t3"] && ![store2 isFavoriteTrackID:@"t1"], @"reopened favorite flags match");

    [db2 deleteFile];
    [NSFileManager.defaultManager removeItemAtURL:dir error:nil];
}

SP_TEST(StoreLocalSearch5000TracksBenchmark) {
    // In-memory store (also verifies nil-database transaction safety).
    SPStore *store = [[SPStore alloc] initWithDatabase:nil];

    const NSUInteger N = 5000;
    NSMutableArray<SPTrack *> *tracks = [NSMutableArray arrayWithCapacity:N];
    NSMutableArray<NSString *> *ids = [NSMutableArray arrayWithCapacity:N];

    for (NSUInteger i = 0; i < N; i++) {
        NSString *tid = [NSString stringWithFormat:@"trk_%05lu", (unsigned long)i];
        NSString *name = nil;
        NSString *artist = nil;
        NSString *album = [NSString stringWithFormat:@"Album %lu", (unsigned long)(i % 200)];
        if (i == 42) {
            name = @"Café del Mar";
            artist = @"Energy 52";
        } else if (i == 1337) {
            name = @"Midnight Café Groove";
            artist = @"Daft Punk";
        } else if (i == 3999) {
            name = @"Cafe";
            artist = @"Exact Prefix Band";
        } else {
            name = [NSString stringWithFormat:@"Synthetic Track Number %lu", (unsigned long)i];
            artist = [NSString stringWithFormat:@"Artist Group %lu", (unsigned long)(i % 150)];
        }
        [tracks addObject:MakeTrack(tid, name, artist, album, 180000 + (NSInteger)(i % 60) * 1000)];
        [ids addObject:tid];
    }

    [store upsertTracks:tracks];
    [store setLibraryTrackIDs:ids addedAtByID:nil];
    SPExpectEqualInt(store.libraryTracks.count, N, "5000 library tracks loaded");

    // Diacritic- and case-insensitive match + ranking: Exact ("Cafe") > Prefix ("Café del Mar") > Substring ("Midnight Café Groove").
    SPSearchResults *r = [store searchLocal:@"CAFE" limitPerKind:20];
    SPExpectEqualInt(r.tracks.count, 3, "matched all 3 cafe variants diacritic-insensitively");
    SPExpectEqualStr(r.tracks[0].trackID, @"trk_03999", "exact match ranked #1");
    SPExpectEqualStr(r.tracks[1].trackID, @"trk_00042", "prefix match ranked #2");
    SPExpectEqualStr(r.tracks[2].trackID, @"trk_01337", "substring match ranked #3");

    // Benchmark 100 local searches over 5,000 tracks; average must be well under 1.0 ms.
    NSArray<NSString *> *queries = @[ @"cafe", @"daft", @"track number 499", @"artist group 77", @"zzzznomatch" ];
    // Warmup
    (void)[store searchLocal:@"cafe"];

    const int iterations = 100;
    double t0 = MachNowMs();
    for (int i = 0; i < iterations; i++) {
        @autoreleasepool {
            SPSearchResults *res = [store searchLocal:queries[(NSUInteger)i % queries.count] limitPerKind:20];
            (void)res.tracks.count;
        }
    }
    double avgMs = (MachNowMs() - t0) / (double)iterations;
    fprintf(stderr, "    [Bench] searchLocal over %lu tracks: %.3f ms avg (%d queries)\n",
            (unsigned long)N, avgMs, iterations);
    SPExpect(avgMs < 1.0, @"local search over 5,000 tracks must be <1.0 ms (got %.3f ms)", avgMs);
}

SP_TEST(StoreDatabaseTxFailedRecoveryAndAppendFavoriteConsistency) {
    NSURL *dir = SPTestTempDirectory(@"txfail");
    NSURL *dbURL = [dir URLByAppendingPathComponent:@"txfail.sqlite"];
    SPDatabase *db1 = [SPDatabase databaseAtURL:dbURL];
    SPDatabase *db2 = [SPDatabase databaseAtURL:dbURL];
    SPExpect(db1 != nil && db2 != nil, @"two database handles opened");
    [db2 setBusyTimeoutMs:1];

    SPTrack *t1 = MakeTrack(@"t1", @"Alpha", @"A1", @"Alb1", 100000);
    SPTrack *t2 = MakeTrack(@"t2", @"Beta", @"A2", @"Alb2", 120000);
    SPTrack *t3 = MakeTrack(@"t3", @"Gamma", @"A3", @"Alb3", 140000);

    // Hold a write transaction on db1 so db2's BEGIN IMMEDIATE fails with SQLITE_BUSY.
    [db1 transaction:^{
        [db1 upsertTrack:t1];
        [db2 transaction:^{
            [db2 upsertTrack:t2]; // Fails BEGIN IMMEDIATE and latches _txFailed inside this tx.
        }];
    }];

    // After db1 commits, db2 MUST recover (_txFailed reset) and persist subsequent writes.
    [db2 transaction:^{
        [db2 upsertTrack:t2];
    }];
    SPDatabase *dbVerify = [SPDatabase databaseAtURL:dbURL];
    SPExpectEqualInt([dbVerify allTracks].count, 2, "db2 recovered after BEGIN IMMEDIATE failure and persisted t2");

    // Verify appendLibraryTrackIDs preserves prior pages' added_at timestamps.
    SPStore *store = [[SPStore alloc] initWithDatabase:dbVerify];
    [store upsertTracks:@[ t1, t2, t3 ]];
    [store setLibraryTrackIDs:@[ @"t1" ] addedAtByID:@{@"t1" : @1700001000.0}];
    [store appendLibraryTrackIDs:@[ @"t2" ] addedAtByID:@{@"t2" : @1700002000.0}];
    NSDictionary<NSString *, NSNumber *> *addedMap = [dbVerify libraryTrackAddedAtByID];
    SPExpect(fabs(addedMap[@"t1"].doubleValue - 1700001000.0) < 0.1, @"page 0 added_at preserved after append");
    SPExpect(fabs(addedMap[@"t2"].doubleValue - 1700002000.0) < 0.1, @"page 1 added_at persisted");

    // Verify updateFavoriteStatuses keeps _favoriteTrackIDs, libraryTracks, and searchLocal consistent (no duplicate rows).
    [store updateFavoriteStatuses:@{@"t1" : @NO, @"t3" : @YES}];
    SPExpect(![store isFavoriteTrackID:@"t1"] && [store isFavoriteTrackID:@"t3"], @"updateFavoriteStatuses updated flags");
    SPExpectEqualInt(store.libraryTracks.count, 2, "libraryTracks count stays synced after updateFavoriteStatuses");
    SPExpectEqualInt([store searchLocal:@"Alpha"].tracks.count, 0, "unliked t1 removed from search index");
    SPExpectEqualInt([store searchLocal:@"Gamma"].tracks.count, 1, "liked t3 added to search index");

    // Re-favoriting t1 must not duplicate or corrupt _libraryTracks.
    [store setFavorite:YES forTrackID:@"t1"];
    SPExpectEqualInt(store.libraryTracks.count, 3, "re-favoriting t1 adds it cleanly without duplicates");
    SPExpectEqualStr(store.libraryTracks[0].trackID, @"t1", "re-favorited t1 placed at index 0");

    [db1 close];
    [db2 close];
    [dbVerify close];
}
