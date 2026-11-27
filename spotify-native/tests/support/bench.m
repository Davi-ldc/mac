// Headless memory, cold-startup first-frame, and performance benchmarks (--memory and --bench).
#import <AppKit/AppKit.h>
#import <ImageIO/ImageIO.h>
#import <QuartzCore/QuartzCore.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <malloc/malloc.h>
#import <stdio.h>
#import <stdlib.h>
#import <sys/wait.h>
#import <unistd.h>

#import "app/trace.h"
#import "audio/fairplay.h"
#import "auth/auth.h"
#import "auth/keychain.h"
#import "net/client.h"
#import "render/images.h"
#import "store/change.h"
#import "store/database.h"
#import "store/store.h"
#import "ui/library/library.h"
#import "ui/shell/shell.h"

static NSArray<NSString *> *GenerateSyntheticArtworkURLsInDir(NSURL *dir, NSUInteger count) {
    NSURL *artDir = [dir URLByAppendingPathComponent:@"art" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:artDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSMutableArray<NSString *> *urls = [NSMutableArray arrayWithCapacity:count];
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    const size_t dim = 128;
    for (NSUInteger i = 0; i < count; i++) {
        NSURL *fileURL = [artDir URLByAppendingPathComponent:[NSString stringWithFormat:@"art_%02lu.png", (unsigned long)i]];
        CGContextRef ctx = CGBitmapContextCreate(NULL, dim, dim, 8, dim * 4, cs,
                                                 kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
        if (!ctx) continue;
        CGFloat r = (CGFloat)((i * 53 + 40) % 215) / 255.0;
        CGFloat g = (CGFloat)((i * 97 + 60) % 195) / 255.0;
        CGFloat b = (CGFloat)((i * 131 + 80) % 175) / 255.0;
        CGContextSetRGBFillColor(ctx, r, g, b, 1.0);
        CGContextFillRect(ctx, CGRectMake(0, 0, dim, dim));
        CGContextSetRGBFillColor(ctx, 1.0 - r * 0.5, 1.0 - g * 0.5, 1.0 - b * 0.5, 0.85);
        CGContextFillEllipseInRect(ctx, CGRectMake(24, 24, dim - 48, dim - 48));
        CGImageRef img = CGBitmapContextCreateImage(ctx);
        CGContextRelease(ctx);
        if (img) {
            CGImageDestinationRef dst = CGImageDestinationCreateWithURL((__bridge CFURLRef)fileURL,
                                                                        (__bridge CFStringRef)UTTypePNG.identifier,
                                                                        1, NULL);
            if (dst) {
                CGImageDestinationAddImage(dst, img, NULL);
                if (CGImageDestinationFinalize(dst)) {
                    [urls addObject:fileURL.absoluteString];
                }
                CFRelease(dst);
            }
            CGImageRelease(img);
        }
    }
    CGColorSpaceRelease(cs);
    return urls;
}

static void PopulateSyntheticSQLiteAtURL(NSURL *dbURL, NSArray<NSString *> *artworkURLs) {
    @autoreleasepool {
        SPDatabase *db = [SPDatabase databaseAtURL:dbURL];
        SPStore *builder = [[SPStore alloc] initWithDatabase:db];
        NSUInteger artCount = artworkURLs.count;

        // 200 artists
        NSMutableArray<SPArtist *> *artists = [NSMutableArray arrayWithCapacity:200];
        NSMutableArray<NSString *> *artistIDs = [NSMutableArray arrayWithCapacity:200];
        for (NSUInteger i = 0; i < 200; i++) {
            NSString *aid = [NSString stringWithFormat:@"art%04lu", (unsigned long)i];
            NSString *name = [NSString stringWithFormat:@"Artist %lu", (unsigned long)i];
            NSString *art = artCount ? artworkURLs[i % artCount] : nil;
            SPArtist *a = [[SPArtist alloc] initWithArtistID:aid
                                                         uri:[NSString stringWithFormat:@"spotify:artist:%@", aid]
                                                        name:name
                                                  artworkURL:art
                                             artworkSmallURL:art
                                                    albumIDs:@[]
                                               detailsLoaded:NO];
            [artists addObject:a];
            [artistIDs addObject:aid];
        }

        // 200 albums
        NSMutableArray<SPAlbum *> *albums = [NSMutableArray arrayWithCapacity:200];
        NSMutableArray<NSString *> *albumIDs = [NSMutableArray arrayWithCapacity:200];
        for (NSUInteger i = 0; i < 200; i++) {
            NSString *alid = [NSString stringWithFormat:@"alb%04lu", (unsigned long)i];
            NSString *aid = artistIDs[i % 200];
            NSString *art = artCount ? artworkURLs[(i + 7) % artCount] : nil;
            SPAlbum *al = [[SPAlbum alloc] initWithAlbumID:alid
                                                       uri:[NSString stringWithFormat:@"spotify:album:%@", alid]
                                                      name:[NSString stringWithFormat:@"Album %lu", (unsigned long)i]
                                                 albumType:@"ALBUM"
                                                  artistID:aid
                                                artistName:[NSString stringWithFormat:@"Artist %lu", (unsigned long)(i % 200)]
                                               artistNames:@[ [NSString stringWithFormat:@"Artist %lu", (unsigned long)(i % 200)] ]
                                               releaseDate:@"2024-01-01"
                                                artworkURL:art
                                           artworkSmallURL:art
                                                  trackIDs:@[]
                                           totalTrackCount:25
                                           totalDurationMs:5000000
                                             detailsLoaded:NO];
            [albums addObject:al];
            [albumIDs addObject:alid];
        }

        // 5,000 tracks
        NSMutableArray<SPTrack *> *tracks = [NSMutableArray arrayWithCapacity:5000];
        NSMutableArray<NSString *> *trackIDs = [NSMutableArray arrayWithCapacity:5000];
        for (NSUInteger i = 0; i < 5000; i++) {
            NSString *tid = [NSString stringWithFormat:@"trk%05lu", (unsigned long)i];
            NSUInteger ai = i % 200;
            NSString *art = artCount ? artworkURLs[ai % artCount] : nil;
            SPTrack *t = [[SPTrack alloc] initWithTrackID:tid
                                                      uri:[NSString stringWithFormat:@"spotify:track:%@", tid]
                                                     name:(i == 1337 ? @"Digital Love Midnight" : [NSString stringWithFormat:@"Track Number %lu", (unsigned long)i])
                                                  albumID:albumIDs[ai]
                                                albumName:[NSString stringWithFormat:@"Album %lu", (unsigned long)ai]
                                                 artistID:artistIDs[ai]
                                               artistName:(i % 97 == 0 ? @"Daft Punk" : [NSString stringWithFormat:@"Artist %lu", (unsigned long)ai])
                                              artistNames:@[ i % 97 == 0 ? @"Daft Punk" : [NSString stringWithFormat:@"Artist %lu", (unsigned long)ai] ]
                                               durationMs:180000 + (NSInteger)(i % 120) * 1000
                                              trackNumber:(NSInteger)(i % 12) + 1
                                               discNumber:1
                                               artworkURL:art
                                          artworkSmallURL:art
                                                 playable:YES
                                         unplayableReason:nil];
            [tracks addObject:t];
            [trackIDs addObject:tid];
        }

        // 50 playlists
        NSMutableArray<SPPlaylist *> *playlists = [NSMutableArray arrayWithCapacity:50];
        NSMutableArray<NSString *> *playlistIDs = [NSMutableArray arrayWithCapacity:50];
        for (NSUInteger i = 0; i < 50; i++) {
            NSString *pid = [NSString stringWithFormat:@"pl%03lu", (unsigned long)i];
            NSMutableArray<SPPlaylistItem *> *items = [NSMutableArray arrayWithCapacity:20];
            for (NSUInteger j = 0; j < 20; j++) {
                NSString *tid = trackIDs[(i * 20 + j) % 5000];
                [items addObject:[[SPPlaylistItem alloc] initWithTrackID:tid uid:[NSString stringWithFormat:@"u%lu", (unsigned long)j] addedAt:1700000000.0 + j]];
            }
            NSString *art = artCount ? artworkURLs[(i + 13) % artCount] : nil;
            SPPlaylist *pl = [[SPPlaylist alloc] initWithPlaylistID:pid
                                                                uri:[NSString stringWithFormat:@"spotify:playlist:%@", pid]
                                                               name:[NSString stringWithFormat:@"Playlist Mix %lu", (unsigned long)i]
                                                playlistDescription:@"Curated synthetic benchmark playlist"
                                                            ownerID:@"benchuser"
                                                          ownerName:@"Bench User"
                                                         artworkURL:art
                                                    artworkSmallURL:art
                                                           isPublic:YES
                                                              items:items
                                                    totalTrackCount:20
                                                      detailsLoaded:YES];
            [playlists addObject:pl];
            [playlistIDs addObject:pid];
        }

        // 6 Home shelves
        NSMutableArray<SPHomeShelf *> *shelves = [NSMutableArray arrayWithCapacity:6];
        for (NSUInteger s = 0; s < 6; s++) {
            NSMutableArray<SPShelfItem *> *sItems = [NSMutableArray arrayWithCapacity:10];
            for (NSUInteger j = 0; j < 10; j++) {
                if (s % 3 == 0) {
                    SPAlbum *al = albums[(s * 10 + j) % 200];
                    [sItems addObject:[[SPShelfItem alloc] initWithKind:SPShelfItemAlbum entityID:al.albumID title:al.name subtitle:al.artistName artworkURL:al.artworkURL]];
                } else if (s % 3 == 1) {
                    SPPlaylist *pl = playlists[(s * 10 + j) % 50];
                    [sItems addObject:[[SPShelfItem alloc] initWithKind:SPShelfItemPlaylist entityID:pl.playlistID title:pl.name subtitle:pl.ownerName artworkURL:pl.artworkURL]];
                } else {
                    SPArtist *ar = artists[(s * 10 + j) % 200];
                    [sItems addObject:[[SPShelfItem alloc] initWithKind:SPShelfItemArtist entityID:ar.artistID title:ar.name subtitle:@"Artist" artworkURL:ar.artworkURL]];
                }
            }
            [shelves addObject:[[SPHomeShelf alloc] initWithShelfID:[NSString stringWithFormat:@"shelf-%lu", (unsigned long)s]
                                                              title:(s == 0 ? @"Recently Played" : [NSString stringWithFormat:@"Recommended Shelf %lu", (unsigned long)s])
                                                   isRecentlyPlayed:(s == 0)
                                                              items:sItems]];
        }

        [db transaction:^{
            [builder upsertArtists:artists];
            [builder upsertAlbums:albums];
            [builder upsertTracks:tracks];
            [builder upsertPlaylists:playlists];
            [builder setLibraryArtistIDs:artistIDs];
            [builder setLibraryAlbumIDs:albumIDs addedAtByID:nil];
            [builder setLibraryTrackIDs:trackIDs addedAtByID:nil];
            [builder setLibraryPlaylistIDs:playlistIDs];
            SPHomePage *hp = [[SPHomePage alloc] initWithShelves:shelves albums:@[] artists:@[] playlists:@[]];
            [builder applyHomePage:hp];
            [builder setUserProfile:[[SPUserProfile alloc] initWithUsername:@"benchuser" displayName:@"Bench User" uri:@"spotify:user:benchuser" avatarURL:nil]];
        }];

        SPFlushChanges();
        [db close];
    }
}

static int CompareDoubles(const void *a, const void *b) {
    double da = *(const double *)a;
    double db = *(const double *)b;
    return (da < db) ? -1 : (da > db ? 1 : 0);
}

int SPRunMemoryFixtureGen(NSString *dirPath) {
    @autoreleasepool {
        NSURL *dir = [NSURL fileURLWithPath:dirPath isDirectory:YES];
        [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSURL *dbURL = [dir URLByAppendingPathComponent:@"synthetic.sqlite"];
        NSArray<NSString *> *artURLs = GenerateSyntheticArtworkURLsInDir(dir, 24);
        PopulateSyntheticSQLiteAtURL(dbURL, artURLs);
        return 0;
    }
}

int SPRunMemoryBenchmark(void) {
    @autoreleasepool {
        // Generate synthetic 5,000-track fixture + 24 local PNG artwork fixtures in a clean child process
        // BEFORE initializing AppKit so the parent measures a genuine cold launch without builder heap pollution.
        NSString *dirName = [NSString stringWithFormat:@"sp-memory-%@", NSUUID.UUID.UUIDString];
        NSURL *dir = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES] URLByAppendingPathComponent:dirName isDirectory:YES];
        [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSURL *dbURL = [dir URLByAppendingPathComponent:@"synthetic.sqlite"];

        NSTask *genTask = [NSTask new];
        genTask.executableURL = [NSURL fileURLWithPath:NSProcessInfo.processInfo.arguments.firstObject];
        genTask.arguments = @[ @"--memory-gen-fixture", dir.path ];
        if ([genTask launchAndReturnError:nil]) {
            [genTask waitUntilExit];
        } else {
            NSArray<NSString *> *artURLs = GenerateSyntheticArtworkURLsInDir(dir, 24);
            PopulateSyntheticSQLiteAtURL(dbURL, artURLs);
        }

        NSApplication *app = [NSApplication sharedApplication];
        app.activationPolicy = NSApplicationActivationPolicyProhibited;
        app.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
        SPSetImageNetworkEnabled(NO);

        double baselineMB = SPProcessFootprintMB();

        double tStart = SPMonotonicNowMs();
        SPDatabase *db = [SPDatabase databaseAtURL:dbURL];
        SPStore *store = [[SPStore alloc] initWithDatabase:db];
        double dbLoadedMs = SPMonotonicNowMs() - tStart;

        SPMemorySecretStore *secrets = [SPMemorySecretStore new];
        SPAuth *auth = [[SPAuth alloc] initWithSecretStore:secrets];
        SPNetClient *net = [[SPNetClient alloc] initWithAuth:auth];
        SPFairPlayEngine *engine = [[SPFairPlayEngine alloc] initWithNetClient:net store:store];
        engine.dryRunMode = YES;

        NSUserDefaults *benchDefaults = [[NSUserDefaults alloc] initWithSuiteName:@"local.spotify-native.bench"];
        SPShell *shell = [[SPShell alloc] initWithStore:store audioEngine:engine netClient:nil connectClient:nil defaults:benchDefaults];

        // Order window back (never steals focus under Prohibited policy) so WindowServer allocates a real backing store
        // and decodes visible artwork bitmaps before measuring open vs closed physical footprint.
        __weak NSWindow *weakWin = nil;
        double firstFrameMs = 0.0;
        double openFootprintMB = 0.0;
        NSUInteger openImageCount = 0;
        @autoreleasepool {
            SPWindow *win = [shell ensureWindow];
            weakWin = win;
            [win orderBack:nil];
            [win.contentView layoutSubtreeIfNeeded];
            [win displayIfNeeded];
            [CATransaction flush];
            firstFrameMs = SPMonotonicNowMs() - tStart;

            // Wait for visible synthetic artwork decodes and draw one settled frame with decoded bitmaps.
            double waitDeadline = SPMonotonicNowMs() + 500.0;
            while (SPImageLoadsInFlight() > 0 && SPMonotonicNowMs() < waitDeadline) {
                [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
            }
            [win displayIfNeeded];
            [CATransaction flush];
            [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.15]];
            malloc_zone_pressure_relief(NULL, 0);
            openImageCount = SPImageLiveCount();
            openFootprintMB = SPProcessFootprintMB();

            [shell closeWindowReleasingViews];
            win = nil;
        }
        [CATransaction flush];
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
        malloc_zone_pressure_relief(NULL, 0);
        double closedFootprintMB = SPProcessFootprintMB();
        NSUInteger closedImageCount = SPImageLiveCount();

        printf("spotify-native --memory (5,000 tracks, 200 albums, 200 artists, 50 playlists, 6 shelves, 24 artworks)\n");
        printf("  baseline_mb     : %.2f MB\n", baselineMB);
        printf("  sqlite_load_ms  : %.2f ms\n", dbLoadedMs);
        printf("  first_frame_ms  : %.2f ms (target < 150 ms)\n", firstFrameMs);
        printf("  open_ram_mb     : %.2f MB (target < 50.0 MB, %lu live bitmaps)\n",
               openFootprintMB, (unsigned long)openImageCount);
        printf("  closed_ram_mb   : %.2f MB (target < 25.0 MB, %lu live bitmaps, windowReleased=%s)\n",
               closedFootprintMB, (unsigned long)closedImageCount, weakWin == nil ? "yes" : "no");
        fflush(stdout);

        [db close];
        [NSFileManager.defaultManager removeItemAtURL:dir error:nil];

        BOOL ok = (firstFrameMs < 150.0) && (openFootprintMB < 50.0) && (closedFootprintMB < 25.0) &&
                  (closedFootprintMB < openFootprintMB) && (openImageCount > 0) && (closedImageCount == 0) && (weakWin == nil);
        if (!ok) {
            fprintf(stderr, "FAIL: memory/startup budget exceeded\n");
            return 1;
        }
        return 0;
    }
}

@interface SPBenchCoalesceObserver : NSObject <SPChangeObserver>
@property (nonatomic) NSUInteger deliveredCount;
@property (nonatomic) NSUInteger lastTrackCount;
@end

@implementation SPBenchCoalesceObserver
- (void)storeChanged:(SPChange *)change {
    _deliveredCount++;
    _lastTrackCount = change.tracks.count;
}
@end

int SPRunPerfBenchmark(void) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        app.activationPolicy = NSApplicationActivationPolicyProhibited;
        app.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
        SPSetImageNetworkEnabled(NO);

        NSString *dirName = [NSString stringWithFormat:@"sp-bench-%@", NSUUID.UUID.UUIDString];
        NSURL *dir = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES] URLByAppendingPathComponent:dirName isDirectory:YES];
        [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSURL *dbURL = [dir URLByAppendingPathComponent:@"bench.sqlite"];
        PopulateSyntheticSQLiteAtURL(dbURL, @[]);

        SPDatabase *db = [SPDatabase databaseAtURL:dbURL];
        SPStore *store = [[SPStore alloc] initWithDatabase:db];

        // 1. Local search latency over 5,000 tracks
        NSArray<NSString *> *queries = @[ @"daft", @"digital", @"track number 4", @"album 19", @"playlist mix", @"midnight", @"artist 88", @"zzzznone" ];
        enum { kSearchIters = 200 };
        double searchTimes[kSearchIters];
        for (int i = 0; i < kSearchIters; i++) {
            NSString *q = queries[(NSUInteger)i % queries.count];
            double t0 = SPMonotonicNowMs();
            SPSearchResults *res = [store searchLocal:q];
            (void)res;
            searchTimes[i] = SPMonotonicNowMs() - t0;
        }
        qsort(searchTimes, kSearchIters, sizeof(double), CompareDoubles);
        double searchSum = 0;
        for (int i = 0; i < kSearchIters; i++) searchSum += searchTimes[i];
        double searchAvg = searchSum / kSearchIters;
        double searchP99 = searchTimes[(int)(kSearchIters * 0.99)];

        // 2. Favorite toggle latency + single-row list redraw
        SPMemorySecretStore *secrets = [SPMemorySecretStore new];
        SPAuth *auth = [[SPAuth alloc] initWithSecretStore:secrets];
        SPNetClient *net = [[SPNetClient alloc] initWithAuth:auth];
        SPFairPlayEngine *engine = [[SPFairPlayEngine alloc] initWithNetClient:net store:store];
        engine.dryRunMode = YES;
        SPShell *shell = [[SPShell alloc] initWithStore:store audioEngine:engine netClient:nil connectClient:nil defaults:nil];
        SPWindow *win = [shell ensureWindow];
        [shell openFavorites];
        [win.contentView layoutSubtreeIfNeeded];
        [win displayIfNeeded];

        enum { kFavIters = 100 };
        double favTimes[kFavIters];
        NSString *targetTrackID = store.libraryTracks[2].trackID;
        for (int i = 0; i < kFavIters; i++) {
            double t0 = SPMonotonicNowMs();
            [store toggleFavoriteTrackID:targetTrackID];
            SPFlushChanges();
            favTimes[i] = SPMonotonicNowMs() - t0;
        }
        qsort(favTimes, kFavIters, sizeof(double), CompareDoubles);
        double favSum = 0;
        for (int i = 0; i < kFavIters; i++) favSum += favTimes[i];
        double favAvg = favSum / kFavIters;
        double favP99 = favTimes[(int)(kFavIters * 0.99)];

        // 3. Virtualized list scroll p99 across 5,000 tracks
        SPFavoritesView *favView = (SPFavoritesView *)shell.currentContentView;
        SPTrackListView *trackList = favView.trackList;
        enum { kScrollIters = 500 };
        double scrollTimes[kScrollIters];
        for (int i = 0; i < kScrollIters; i++) {
            CGFloat y = (CGFloat)((i * 380) % 210000);
            double t0 = SPMonotonicNowMs();
            [trackList scrollToY:y];
            scrollTimes[i] = SPMonotonicNowMs() - t0;
        }
        qsort(scrollTimes, kScrollIters, sizeof(double), CompareDoubles);
        double scrollSum = 0;
        for (int i = 0; i < kScrollIters; i++) scrollSum += scrollTimes[i];
        double scrollAvg = scrollSum / kScrollIters;
        double scrollP99 = scrollTimes[(int)(kScrollIters * 0.99)];

        // 4. SPChangeQueue burst coalescing (10,000 notes -> 1 delivery)
        SPChangeQueue *q = [SPChangeQueue new];
        SPBenchCoalesceObserver *obs = [SPBenchCoalesceObserver new];
        [q addObserver:obs];
        double tBurst0 = SPMonotonicNowMs();
        for (int i = 0; i < 10000; i++) {
            [q note:SPChangeTracks value:[NSString stringWithFormat:@"t%d", i % 500]];
            if (i % 10 == 0) [q note:SPChangePlayback value:nil];
        }
        SPFlushChanges();
        double burstMs = SPMonotonicNowMs() - tBurst0;
        [q removeObserver:obs];

        [shell closeWindowReleasingViews];
        [db close];
        [NSFileManager.defaultManager removeItemAtURL:dir error:nil];

        printf("spotify-native --bench (5,000-track synthetic store)\n");
        printf("  local_search    : avg %.3f ms, p99 %.3f ms (200 queries, target < 1.0 ms)\n", searchAvg, searchP99);
        printf("  favorite_toggle : avg %.3f ms, p99 %.3f ms (100 toggles)\n", favAvg, favP99);
        printf("  list_scroll     : avg %.3f ms, p99 %.3f ms (500 jumps over 5,000 rows)\n", scrollAvg, scrollP99);
        printf("  change_coalesce : %.3f ms for 10,000 notes -> %lu delivery (%lu unique IDs)\n",
               burstMs, (unsigned long)obs.deliveredCount, (unsigned long)obs.lastTrackCount);
        fflush(stdout);

        return (searchAvg < 1.0 && obs.deliveredCount == 1) ? 0 : 1;
    }
}
