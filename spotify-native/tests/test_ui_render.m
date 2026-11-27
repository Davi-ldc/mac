// Milestone 2 headless UI, render, zero-cache image lifetime, instant search, and lifecycle self-tests.
#import "test.h"
#import "mockserver.h"

#import "app/app.h"
#import "audio/fairplay.h"
#import "auth/auth.h"
#import "auth/keychain.h"
#import "net/client.h"
#import "render/icons.h"
#import "render/images.h"
#import "render/waveform.h"
#import "store/store.h"
#import "ui/detail/detail.h"
#import "ui/kit/controls.h"
#import "ui/kit/grid.h"
#import "ui/kit/list.h"
#import "ui/library/library.h"
#import "ui/prefs/prefs.h"
#import "ui/search/search.h"
#import "ui/shell/shell.h"

#import <AppKit/AppKit.h>
#import <ImageIO/ImageIO.h>
#import <QuartzCore/QuartzCore.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static CGImageRef MakeSyntheticCGImage(int width, int height) CF_RETURNS_RETAINED {
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(NULL, (size_t)width, (size_t)height, 8, (size_t)width * 4, cs,
                                             (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGContextSetRGBFillColor(ctx, 0.11, 0.72, 0.33, 1.0);
    CGContextFillRect(ctx, CGRectMake(0, 0, width, height));
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    return img;
}

static NSData *MakeSyntheticPNG(int width, int height) {
    CGImageRef img = MakeSyntheticCGImage(width, height);
    NSMutableData *out = [NSMutableData new];
    CGImageDestinationRef dest = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)out,
                                                                  (__bridge CFStringRef)UTTypePNG.identifier,
                                                                  1, NULL);
    CGImageDestinationAddImage(dest, img, NULL);
    CGImageDestinationFinalize(dest);
    CFRelease(dest);
    CGImageRelease(img);
    return out;
}

static SPTrack *MakeUITrack(NSString *tid, NSString *name, NSString *artist, NSString *album) {
    return [[SPTrack alloc] initWithTrackID:tid
                                        uri:[NSString stringWithFormat:@"spotify:track:%@", tid]
                                       name:name
                                    albumID:@"alb1"
                                  albumName:album
                                   artistID:@"art1"
                                 artistName:artist
                                artistNames:@[ artist ]
                                 durationMs:210000
                                trackNumber:1
                                 discNumber:1
                                 artworkURL:nil
                            artworkSmallURL:nil
                                   playable:YES
                           unplayableReason:nil];
}

static SPStore *MakeSampleStore(NSUInteger trackCount) {
    SPStore *store = [[SPStore alloc] initWithDatabase:nil];
    NSMutableArray<SPTrack *> *tracks = [NSMutableArray arrayWithCapacity:trackCount];
    NSMutableArray<NSString *> *ids = [NSMutableArray arrayWithCapacity:trackCount];
    for (NSUInteger i = 0; i < trackCount; i++) {
        NSString *tid = [NSString stringWithFormat:@"t-%lu", (unsigned long)i];
        NSString *name = (i == 0) ? @"Around the World" : (i == 1 ? @"Digital Love" : [NSString stringWithFormat:@"Track %lu", (unsigned long)i]);
        NSString *artist = (i <= 1) ? @"Daft Punk" : [NSString stringWithFormat:@"Artist %lu", (unsigned long)(i % 10)];
        [tracks addObject:MakeUITrack(tid, name, artist, @"Discovery")];
        [ids addObject:tid];
    }
    [store upsertTracks:tracks];
    [store setLibraryTrackIDs:ids addedAtByID:nil];

    SPAlbum *al = [[SPAlbum alloc] initWithAlbumID:@"alb1" uri:@"spotify:album:alb1" name:@"Discovery" albumType:@"ALBUM"
                                          artistID:@"art1" artistName:@"Daft Punk" artistNames:@[ @"Daft Punk" ]
                                       releaseDate:@"2001-03-12" artworkURL:nil artworkSmallURL:nil
                                          trackIDs:@[ @"t-0", @"t-1" ] totalTrackCount:2 totalDurationMs:420000 detailsLoaded:YES];
    [store upsertAlbums:@[ al ]];
    [store setLibraryAlbumIDs:@[ @"alb1" ] addedAtByID:nil];

    SPShelfItem *si = [[SPShelfItem alloc] initWithKind:SPShelfItemAlbum entityID:@"alb1" title:@"Discovery" subtitle:@"Daft Punk" artworkURL:nil];
    SPHomeShelf *sh = [[SPHomeShelf alloc] initWithShelfID:@"recent" title:@"Recently Played" isRecentlyPlayed:YES items:@[ si ]];
    [store applyHomePage:[[SPHomePage alloc] initWithShelves:@[ sh ] albums:@[ al ] artists:@[] playlists:@[]]];
    SPFlushChanges();
    return store;
}

#pragma mark - Render: Zero-Cache Images & Post-CA Deferred Release

SP_TEST(RenderImagesZeroCacheSharingAndPostCALifetime) {
    NSData *png = MakeSyntheticPNG(64, 64);
    __block NSUInteger fetchCount = 0;
    SPSetImageFetcher(^(NSURL *url, void (^completion)(NSData *data)) {
        (void)url;
        fetchCount++;
        completion(png);
    });

    NSURL *url = [NSURL URLWithString:@"https://i.scdn.co/image/test-art-1"];
    NSView *v1 = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 64, 64)];
    NSView *v2 = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 64, 64)];
    NSView *child = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 32, 32)];
    [v1 addSubview:child];

    (void)[v1.imageHolder imageWithURL:url pixels:64];
    (void)[v2.imageHolder imageWithURL:url pixels:64];

    BOOL loaded = SPWaitUntil(1.0, ^BOOL {
        return SPImageLoadsInFlight() == 0 && [v1.imageHolder imageWithURL:url pixels:64] != NULL;
    });
    SPExpect(loaded, @"image decoded in background");
    SPExpectEqualInt(fetchCount, 1, "shared URL+size fetches only once across two views");

    CGImageRef img1 = [v1.imageHolder imageWithURL:url pixels:64];
    CGImageRef img2 = [v2.imageHolder imageWithURL:url pixels:64];
    SPExpect(img1 != NULL && img1 == img2, @"both views share the exact same CGImageRef");
    SPExpectEqualInt(SPImageLiveCount(), 1, "weak map tracks exactly 1 live shared bitmap");

    // Release on both views: deferred until kCFRunLoopBeforeWaiting (order 2500000, AFTER CA commit at 2000000).
    // Immediate re-acquire in the same run-loop turn must hit the still-alive bitmap without re-fetching!
    SPReleaseViewImages(v1);
    SPReleaseViewImages(v2);
    SPExpect(SPImageDeferredReleaseCount() >= 2, @"deferred releases queued before run-loop waits");

    CGImageRef reacquired = [v1.imageHolder imageWithURL:url pixels:64];
    SPExpect(reacquired == img1, @"same-frame redraw re-acquires bitmap without flash or re-download");
    SPExpectEqualInt(fetchCount, 1, "still only 1 fetch after same-frame re-acquire");

    // Now truly drop all holders and let the run loop pass kCFRunLoopBeforeWaiting (order 2500000).
    @autoreleasepool {
        SPReleaseViewImages(v1);
        SPReleaseViewImages(v2);
        v1 = nil;
        v2 = nil;
        child = nil;
    }
    BOOL freed = SPWaitUntil(0.5, ^BOOL { return SPImageLiveCount() == 0; });
    SPExpect(freed, @"zero-cache bitmap released after post-CA observer once no holder remains (live=%lu)",
             (unsigned long)SPImageLiveCount());
    SPSetImageFetcher(nil);
}

#pragma mark - Render: 30 fps Waveform Pause on Pause & Occlusion

SP_TEST(RenderWaveformPauseOnPauseAndOcclusion) {
    NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 200, 100)
                                                styleMask:NSWindowStyleMaskTitled
                                                  backing:NSBackingStoreBuffered
                                                    defer:NO];
    win.releasedWhenClosed = NO;
    SPWaveformView *wf = [[SPWaveformView alloc] initWithFrame:NSMakeRect(10, 10, 14, 14)];
    [win.contentView addSubview:wf];
    // Offscreen test window reports occluded until cleared; simulate visible window state explicitly.
    wf.occluded = NO;
    wf.playing = YES;
    SPExpect(wf.isAnimating, @"waveform animates when visible and playing");

    wf.playing = NO;
    SPExpect(!wf.isAnimating, @"waveform pauses automatically when playback pauses");

    wf.playing = YES;
    SPExpect(wf.isAnimating, @"waveform resumes when playback resumes");

    wf.occluded = YES;
    SPExpect(!wf.isAnimating, @"waveform pauses automatically when window is occluded");

    wf.occluded = NO;
    SPExpect(wf.isAnimating, @"waveform resumes when window becomes visible again");

    [wf removeFromSuperview];
    SPExpect(!wf.isAnimating, @"waveform stops when removed from window");
    [win close];
}

#pragma mark - UI Kit: Virtualized List Recycling Without Blank Subviews

@interface SPTestLayeredChildRow : SPListRowView
@property (nonatomic, readonly) NSView *layeredChild;
@property (nonatomic, copy, nullable) NSString *boundText;
@end

@implementation SPTestLayeredChildRow
- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _layeredChild = [[NSView alloc] initWithFrame:NSMakeRect(4, 4, 24, 24)];
    _layeredChild.wantsLayer = YES;
    [self addSubview:_layeredChild];
    return self;
}
@end

@interface SPTestVirtualList : SPListView
@property (nonatomic) NSUInteger lastActivatedIndex;
@end

@implementation SPTestVirtualList
- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _lastActivatedIndex = NSNotFound;
    return self;
}
- (SPListRowView *)makeRow { return [[SPTestLayeredChildRow alloc] initWithFrame:NSZeroRect]; }
- (CGFloat)heightOfIndex:(NSUInteger)index width:(CGFloat)width { (void)index; (void)width; return 40.0; }
- (void)showIndex:(NSUInteger)index inRow:(SPTestLayeredChildRow *)row {
    row.boundText = [NSString stringWithFormat:@"Item %lu", (unsigned long)index];
}
- (void)didActivateIndex:(NSUInteger)index { _lastActivatedIndex = index; }
@end

SP_TEST(UIKitListVirtualizationRecyclingNoBlankSubviews) {
    NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 500, 400)
                                                styleMask:NSWindowStyleMaskTitled
                                                  backing:NSBackingStoreBuffered
                                                    defer:NO];
    win.releasedWhenClosed = NO;
    SPTestVirtualList *list = [[SPTestVirtualList alloc] initWithFrame:NSMakeRect(0, 0, 500, 400)];
    [win.contentView addSubview:list];

    NSMutableArray<NSString *> *keys = [NSMutableArray arrayWithCapacity:1000];
    for (NSUInteger i = 0; i < 1000; i++) [keys addObject:[NSString stringWithFormat:@"k-%lu", (unsigned long)i]];
    [list showKeys:keys];
    [win.contentView layoutSubtreeIfNeeded];

    SPExpect(list.visibleRowCount > 0 && list.visibleRowCount < 30,
             @"virtualized list renders only visible+overscan rows (got %lu)", (unsigned long)list.visibleRowCount);
    SPTestLayeredChildRow *row0 = (SPTestLayeredChildRow *)[list rowAtIndex:0];
    SPExpect(row0 != nil && !row0.wantsLayer, @"static list row has zero wantsLayer bloat");
    SPExpectEqualStr(row0.boundText, @"Item 0", "row 0 bound");

    // Give layered child fake contents, then scroll far away so rows recycle and dequeue cleanly.
    CGImageRef dummyImg = MakeSyntheticCGImage(8, 8);
    row0.layeredChild.layer.contents = (__bridge id)dummyImg;
    CGImageRelease(dummyImg);
    row0.layeredChild.needsDisplay = NO;

    [list scrollToY:12000.0];
    SPTestLayeredChildRow *row300 = (SPTestLayeredChildRow *)[list rowAtIndex:300];
    SPExpect(row300 != nil, @"scrolled row 300 materialized");
    SPExpectEqualStr(row300.boundText, @"Item 300", "reused row rebound to Item 300");
    SPExpect(row300.needsDisplay && row300.layeredChild.needsDisplay,
             @"recycled row and subviews marked needsDisplay=YES so recycled rows never go blank");

    // Keyboard Down + Return navigation.
    list.selectedIndex = 300;
    NSEvent *downEvt = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0
                                    windowNumber:win.windowNumber context:nil
                                      characters:[NSString stringWithFormat:@"%C", (unichar)NSDownArrowFunctionKey]
                     charactersIgnoringModifiers:[NSString stringWithFormat:@"%C", (unichar)NSDownArrowFunctionKey]
                                       isARepeat:NO keyCode:125];
    [list keyDown:downEvt];
    SPExpectEqualInt(list.selectedIndex, 301, "Down arrow moves selection to 301");

    NSEvent *retEvt = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0
                                   windowNumber:win.windowNumber context:nil characters:@"\r"
                    charactersIgnoringModifiers:@"\r" isARepeat:NO keyCode:36];
    [list keyDown:retEvt];
    SPExpectEqualInt(list.lastActivatedIndex, 301, "Return activates selected row");

    [win close];
}

#pragma mark - UI Kit: Responsive Card Grid Virtualization

SP_TEST(UIKitCardGridResponsiveColumns) {
    NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1100, 500)
                                                styleMask:NSWindowStyleMaskTitled
                                                  backing:NSBackingStoreBuffered
                                                    defer:NO];
    win.releasedWhenClosed = NO;
    SPCardGridView *grid = [[SPCardGridView alloc] initWithFrame:NSMakeRect(0, 0, 1100, 500)];
    [win.contentView addSubview:grid];

    NSMutableArray<SPCardItem *> *items = [NSMutableArray arrayWithCapacity:80];
    for (NSUInteger i = 0; i < 80; i++) {
        [items addObject:[[SPCardItem alloc] initWithKey:[NSString stringWithFormat:@"c-%lu", (unsigned long)i]
                                                   title:[NSString stringWithFormat:@"Album %lu", (unsigned long)i]
                                                subtitle:@"Artist"
                                              artworkURL:nil circular:NO
                                              contextURI:@"spotify:album:alb1"
                                       representedObject:nil]];
    }
    grid.items = items;
    [win.contentView layoutSubtreeIfNeeded];
    NSUInteger wideCols = grid.columnCount;
    SPExpect(wideCols >= 4, @"wide grid computes multiple responsive columns (%lu)", (unsigned long)wideCols);
    SPExpect(grid.visibleCellCount < 80, @"card grid virtualizes offscreen items (%lu visible)", (unsigned long)grid.visibleCellCount);

    grid.frame = NSMakeRect(0, 0, 420, 500);
    [grid layoutSubtreeIfNeeded];
    SPExpect(grid.columnCount < wideCols && grid.columnCount >= 1, @"narrow resize reduces column count cleanly");
    [win close];
}

#pragma mark - UI: Single-Row Heart Redraw Scoping

SP_TEST(UISingleRowHeartRedrawInFavorites) {
    SPStore *store = MakeSampleStore(40);
    SPMemorySecretStore *secrets = [SPMemorySecretStore new];
    SPAuth *auth = [[SPAuth alloc] initWithSecretStore:secrets];
    SPNetClient *net = [[SPNetClient alloc] initWithAuth:auth];
    SPFairPlayEngine *engine = [[SPFairPlayEngine alloc] initWithNetClient:net store:store];
    engine.dryRunMode = YES;

    SPShell *shell = [[SPShell alloc] initWithStore:store audioEngine:engine netClient:nil connectClient:nil defaults:nil];
    SPWindow *win = [shell ensureWindow];
    [shell openFavorites];
    [win.contentView layoutSubtreeIfNeeded];

    SPFavoritesView *fav = (SPFavoritesView *)shell.currentContentView;
    SPExpect([fav isKindOfClass:SPFavoritesView.class], @"Favorites view mounted");

    SPTrackRowView *row0 = (SPTrackRowView *)[fav.trackList rowAtIndex:0];
    SPTrackRowView *row1 = (SPTrackRowView *)[fav.trackList rowAtIndex:1];
    SPTrackRowView *row2 = (SPTrackRowView *)[fav.trackList rowAtIndex:2];
    SPTrackRowView *row3 = (SPTrackRowView *)[fav.trackList rowAtIndex:3];
    SPExpect(row0 && row1 && row2 && row3, @"first four track rows visible");
    SPExpect(row2.heartButton.favorited, @"row 2 starts favorited");

    NSUInteger b0 = row0.bindCount, b1 = row1.bindCount, b2 = row2.bindCount, b3 = row3.bindCount;

    // Toggle favorite on row 2 ONLY.
    [shell toggleFavoriteTrackID:row2.track.trackID];
    SPFlushChanges();

    SPExpect(!row2.heartButton.favorited, @"row 2 heart toggled off");
    SPExpectEqualInt(row2.bindCount, b2 + 1, "target row rebound exactly once");
    SPExpectEqualInt(row0.bindCount, b0, "sibling row 0 untouched");
    SPExpectEqualInt(row1.bindCount, b1, "sibling row 1 untouched");
    SPExpectEqualInt(row3.bindCount, b3, "sibling row 3 untouched");

    [shell closeWindowReleasingViews];
}

#pragma mark - UI: Always-Active Global Search from Home (1-Click Focus + Instant Local + Debounced Remote)

SP_TEST(UISearchClickFromHomeInstantLocalAndDebouncedRemote) {
    SPMockHTTPServer *server = [SPMockHTTPServer new];
    SPExpect([server start], @"mock server started");

    __block int remoteDesktopHits = 0;
    server.handler = ^SPMockResponse *(SPMockRequest *req) {
        if ([req.path containsString:@"/pathfinder/v2/query"]) {
            NSDictionary *body = req.jsonBody;
            NSString *op = [body[@"operationName"] isKindOfClass:NSString.class] ? body[@"operationName"] : @"";
            if ([op isEqualToString:@"searchDesktop"]) {
                remoteDesktopHits++;
                NSDictionary *payload = @{
                    @"data" : @{
                        @"searchV2" : @{
                            @"tracksV2" : @{
                                @"totalCount" : @1,
                                @"items" : @[ @{
                                    @"item" : @{
                                        @"data" : @{
                                            @"uri" : @"spotify:track:remote1",
                                            @"name" : @"Daftendirekt (Remote)",
                                            @"duration" : @{ @"totalMilliseconds" : @164000 },
                                            @"artists" : @{ @"items" : @[ @{ @"uri" : @"spotify:artist:art1", @"profile" : @{ @"name" : @"Daft Punk" } } ] },
                                            @"albumOfTrack" : @{ @"uri" : @"spotify:album:alb9", @"name" : @"Homework" },
                                        }
                                    }
                                } ]
                            },
                            @"artists" : @{ @"totalCount" : @0, @"items" : @[] },
                            @"albumsV2" : @{ @"totalCount" : @0, @"items" : @[] },
                            @"playlists" : @{ @"totalCount" : @0, @"items" : @[] },
                            @"topResultsV2" : @{ @"itemsV2" : @[] },
                        }
                    }
                };
                return [SPMockResponse responseWithStatus:200 json:payload];
            }
            if ([op isEqualToString:@"searchSuggestions"]) {
                NSDictionary *payload = @{
                    @"data" : @{
                        @"searchV2" : @{
                            @"topResultsV2" : @{
                                @"itemsV2" : @[ @{ @"item" : @{ @"__typename" : @"SearchAutocompleteQuery", @"text" : @"daft punk homework" } } ]
                            }
                        }
                    }
                };
                return [SPMockResponse responseWithStatus:200 json:payload];
            }
        }
        return [SPMockResponse responseWithStatus:200 json:@{}];
    };

    SPStore *store = MakeSampleStore(20);
    SPMemorySecretStore *secrets = [SPMemorySecretStore new];
    SPSessionBlob *blob = [[SPSessionBlob alloc] initWithAccessToken:@"tok" refreshToken:@"ref"
                                                accessTokenExpiresAt:NSDate.date.timeIntervalSince1970 + 3600
                                                            username:@"u" deviceID:@"dev1"
                                                         clientToken:@"ct" clientTokenExpiresAt:NSDate.date.timeIntervalSince1970 + 3600
                                                          soloistKey:nil];
    SPAuth *auth = [[SPAuth alloc] initWithSecretStore:secrets session:blob urlSession:nil];
    SPNetClient *net = [[SPNetClient alloc] initWithAuth:auth];
    net.pathfinderURL = [server urlForPath:@"/pathfinder/v2/query"];

    SPFairPlayEngine *engine = [[SPFairPlayEngine alloc] initWithNetClient:net store:store];
    engine.dryRunMode = YES;

    SPShell *shell = [[SPShell alloc] initWithStore:store audioEngine:engine netClient:net connectClient:nil defaults:nil];
    shell.searchController.debounceInterval = 0.04;
    SPWindow *win = [shell ensureWindow];
    [win.contentView layoutSubtreeIfNeeded];

    // Verify we start on Home.
    SPExpectEqualInt(shell.currentRoute.kind, SPRouteHome, "shell opens on Home");

    // 1-click directly on toolbar search field while on Home.
    NSEvent *click = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:NSMakePoint(10, 10)
                                   modifierFlags:0 timestamp:0 windowNumber:win.windowNumber context:nil
                                     eventNumber:1 clickCount:1 pressure:1.0];
    [shell.toolbarSearchField mouseDown:click];
    SPExpect(shell.toolbarSearchField.isFocused, @"single click on toolbar search from Home focuses immediately");

    // Typing immediately switches to Search and populates <1 ms local library results before network returns.
    [shell.toolbarSearchField typeString:@"daft"];
    SPExpectEqualInt(shell.currentRoute.kind, SPRouteSearch, "typing switches straight to Search screen");
    SPSearchView *sv = (SPSearchView *)shell.currentContentView;
    SPExpect([sv isKindOfClass:SPSearchView.class], @"Search view mounted");
    SPExpect(sv.results != nil && sv.results.isLocalOnly, @"local results appear synchronously");
    SPExpect(sv.results.tracks.count >= 2, @"local matches found Daft Punk tracks immediately");

    // Wait for debounced remote searchDesktop + searchSuggestions to merge in.
    BOOL remoteMerged = SPWaitUntil(1.5, ^BOOL {
        return sv.results && !sv.results.isLocalOnly && sv.results.tracks.count >= 3 && sv.results.suggestions.count >= 1;
    });
    SPExpect(remoteMerged, @"remote searchDesktop + searchSuggestions merged into Search view (hits=%d)", remoteDesktopHits);

    // Escape clears search and returns cleanly to Home.
    [shell.toolbarSearchField clearAndResign:YES];
    if (shell.toolbarSearchField.onEscape) shell.toolbarSearchField.onEscape();
    SPExpectEqualInt(shell.currentRoute.kind, SPRouteHome, "Escape returns cleanly to Home");

    [shell closeWindowReleasingViews];
    [server stop];
}

#pragma mark - UI: Space Play/Pause Outside Text Fields vs Inside Search Field

SP_TEST(UISpacePlayPauseOutsideTextFieldsVsInsideSearchField) {
    SPStore *store = MakeSampleStore(5);
    SPMemorySecretStore *secrets = [SPMemorySecretStore new];
    SPAuth *auth = [[SPAuth alloc] initWithSecretStore:secrets];
    SPNetClient *net = [[SPNetClient alloc] initWithAuth:auth];
    SPFairPlayEngine *engine = [[SPFairPlayEngine alloc] initWithNetClient:net store:store];
    engine.dryRunMode = YES;

    SPShell *shell = [[SPShell alloc] initWithStore:store audioEngine:engine netClient:nil connectClient:nil defaults:nil];
    SPWindow *win = [shell ensureWindow];
    [engine playTrackURIs:@[ @"spotify:track:t-0" ] completion:nil];
    SPFlushChanges();
    SPExpect(engine.playbackState.isPlaying, @"engine starts playing");

    NSEvent *spaceEvt = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0
                                     windowNumber:win.windowNumber context:nil characters:@" "
                      charactersIgnoringModifiers:@" " isARepeat:NO keyCode:49];

    // Focus NOT in a text field -> Space toggles play/pause.
    [win makeFirstResponder:win.contentView];
    SPExpect([win handleKeyEvent:spaceEvt], @"Space handled as Play/Pause outside text fields");
    SPFlushChanges();
    SPExpect(!engine.playbackState.isPlaying, @"playback paused by Space");

    SPExpect([win handleKeyEvent:spaceEvt], @"Second Space resumes playback");
    SPFlushChanges();
    SPExpect(engine.playbackState.isPlaying, @"playback resumed by Space");

    // Focus IN toolbar search field -> Space must NOT toggle playback.
    [shell focusSearchFieldSelectingAll:NO];
    SPExpect([win isEditingText], @"window detects active text field editor");
    SPExpect(![win handleKeyEvent:spaceEvt], @"Space ignored by global play/pause while typing in search field");
    SPExpect(engine.playbackState.isPlaying, @"playback state unchanged while typing Space in search field");

    [shell closeWindowReleasingViews];
}

#pragma mark - UI: Window Close Keeps Audio Alive & Drops Views

SP_TEST(UIWindowCloseKeepsAudioAliveAndDropsViews) {
    SPStore *store = MakeSampleStore(10);
    SPMemorySecretStore *secrets = [SPMemorySecretStore new];
    SPAuth *auth = [[SPAuth alloc] initWithSecretStore:secrets];
    SPNetClient *net = [[SPNetClient alloc] initWithAuth:auth];
    SPFairPlayEngine *engine = [[SPFairPlayEngine alloc] initWithNetClient:net store:store];
    engine.dryRunMode = YES;

    SPShell *shell = [[SPShell alloc] initWithStore:store audioEngine:engine netClient:nil connectClient:nil defaults:nil];
    [shell ensureWindow];
    [engine playTrackURIs:@[ @"spotify:track:t-0", @"spotify:track:t-1" ] completion:nil];
    SPFlushChanges();
    SPExpect(shell.isWindowOpen && engine.playbackState.isPlaying, @"window open and audio playing");

    // Simulate Cmd+W / red close button.
    [shell closeWindowReleasingViews];
    SPExpect(!shell.isWindowOpen, @"window closed");
    SPExpect(shell.currentContentView == nil && shell.sidebarView == nil && shell.playerBarView == nil,
             @"UI views released on window close");
    SPExpect(engine.playbackState.isPlaying, @"audio engine stays alive and playing after window close");

    // Reopen window from Dock click -> UI restores from live store.
    [shell ensureWindow];
    SPExpect(shell.isWindowOpen && shell.currentContentView != nil, @"window reopens cleanly");
    SPExpect(engine.playbackState.isPlaying, @"playback continues across window reopen");
    [shell closeWindowReleasingViews];
}

#pragma mark - UI: Preferences Conditional Soloist Key & App Menu Bar

SP_TEST(UIPrefsSoloistKeyConditionalAndMenuBar) {
    SPStore *store = MakeSampleStore(3);
    SPPreferencesWindowController *prefs = [[SPPreferencesWindowController alloc] initWithStore:store];
    prefs.enginePreference = SPAudioEnginePrefAuto;
    prefs.activeEngineKind = SPAudioEngineKindFairPlay;
    prefs.soloistKeyMissingOrFailed = YES;
    [prefs refreshState];
    SPExpect(!prefs.soloistKeySectionVisible, @"Soloist key UI hidden by default when FairPlay is primary");

    prefs.enginePreference = SPAudioEnginePrefSoloist;
    [prefs refreshState];
    SPExpect(prefs.soloistKeySectionVisible, @"Soloist key UI shown when Soloist is chosen and missing/failed");

    prefs.soloistKeyMissingOrFailed = NO;
    [prefs refreshState];
    SPExpect(!prefs.soloistKeySectionVisible, @"Soloist key UI hidden once Soloist key is present and working");
    [prefs close];

    SPAppController *app = [SPAppController new];
    NSMenu *menu = [app buildMainMenu];
    SPExpectEqualInt(menu.numberOfItems, 5, "menu bar has Spotify Native, Edit, View, Playback, Window");
    NSMenu *edit = [menu itemWithTitle:@"Edit"].submenu;
    SPExpect([edit itemWithTitle:@"Copy"].action == @selector(copy:), @"Edit menu wires Copy");
    SPExpect([edit itemWithTitle:@"Paste"].action == @selector(paste:), @"Edit menu wires Paste");
    SPExpect([edit itemWithTitle:@"Select All"].action == @selector(selectAll:), @"Edit menu wires Select All");
    NSMenu *view = [menu itemWithTitle:@"View"].submenu;
    SPExpect([view itemWithTitle:@"Search"] != nil, @"View menu includes Search (Cmd+K)");
    NSMenu *winMenu = [menu itemWithTitle:@"Window"].submenu;
    SPExpect([winMenu itemWithTitle:@"Close Window"] != nil, @"Window menu includes Close Window (Cmd+W)");
}

SP_TEST(RenderImagesFailureRetryAndMapKeyCleanup) {
    NSURL *dir = SPTestTempDirectory(@"img-retry");
    NSURL *url = [dir URLByAppendingPathComponent:@"retry.png"];
    NSData *validPNG = MakeSyntheticPNG(64, 64);

    __block int attempts = 0;
    SPSetImageRetryBackoff(0.0);
    SPSetImageFetcher(^(NSURL *reqURL, void (^completion)(NSData *data)) {
        (void)reqURL;
        attempts++;
        if (attempts == 1) {
            completion(nil); // Simulate transient network failure.
        } else {
            completion(validPNG);
        }
    });

    NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 64, 64)];
    SPExpect([v.imageHolder imageWithURL:url pixels:64.0] == NULL, @"first attempt starts loading");
    SPExpect(SPWaitUntil(2.0, ^BOOL { return attempts == 1 && SPImageLoadsInFlight() == 0; }), @"first failed load finished");

    // Must NOT stay poisoned — second request retries and decodes cleanly (BP-M3).
    (void)[v.imageHolder imageWithURL:url pixels:64.0];
    SPExpect(SPWaitUntil(2.0, ^BOOL { return attempts == 2 && SPImageLoadsInFlight() == 0; }), @"second attempt retried");
    CGImageRef decoded = [v.imageHolder imageWithURL:url pixels:64.0];
    SPExpect(decoded != NULL, @"retry succeeded with decoded bitmap");

    // Releasing images and draining post-CA observer must prune strong keys from gPictures (BP-M3).
    [v.imageHolder removeAllImages];
    SPWaitUntil(0.15, ^BOOL { return SPImageLiveCount() == 0 && SPImageMapKeyCount() == 0; });
    SPExpectEqualInt(SPImageLiveCount(), 0, "live bitmaps dropped to 0");
    SPExpectEqualInt(SPImageMapKeyCount(), 0, "dead strong keys pruned from gPictures map table");

    SPSetImageFetcher(nil);
    SPSetImageRetryBackoff(5.0);
}

SP_TEST(UIFocusResignationCmdArrowArtistDetailScrollAndUXRegressions) {
    SPStore *store = MakeSampleStore(12);
    // Attach top tracks & discography to art-0 for Artist Detail verification (UX-H3).
    SPArtist *richArtist = [[SPArtist alloc] initWithArtistID:@"art-0"
                                                          uri:@"spotify:artist:art-0"
                                                         name:@"Daft Punk"
                                                   artworkURL:nil
                                              artworkSmallURL:nil
                                                     albumIDs:@[ @"alb1" ]
                                                  topTrackIDs:@[ @"t-0", @"t-1", @"t-2" ]
                                                detailsLoaded:YES];
    [store upsertArtists:@[ richArtist ]];

    SPAuth *auth = [[SPAuth alloc] initWithSecretStore:[SPMemorySecretStore new]];
    SPNetClient *net = [[SPNetClient alloc] initWithAuth:auth];
    SPFairPlayEngine *engine = [[SPFairPlayEngine alloc] initWithNetClient:net store:store];
    engine.dryRunMode = YES;
    SPShell *shell = [[SPShell alloc] initWithStore:store audioEngine:engine netClient:nil connectClient:nil defaults:nil];
    SPWindow *win = [shell ensureWindow];
    [win.contentView layoutSubtreeIfNeeded];

    // 1. Focus search -> type -> navigate to Artist Detail -> search focus MUST resign so Space pauses (UX-H1).
    [shell.toolbarSearchField focusSelectingAll:NO];
    [shell.toolbarSearchField typeString:@"daft"];
    SPExpect(win.isEditingText, @"window is editing search field");

    // Cmd+Left inside search field must be handled as text caret movement, NOT skipPrevious (UX-H5).
    [engine playTrackURIs:@[ @"spotify:track:t-0", @"spotify:track:t-1" ] completion:nil];
    [engine skipNext];
    SPFlushChanges();
    SPExpectEqualStr(store.playbackState.currentTrackURI, @"spotify:track:t-1", "playing t-1 before Cmd+Left");
    unichar leftChar = NSLeftArrowFunctionKey;
    NSEvent *cmdLeft = [NSEvent keyEventWithType:NSEventTypeKeyDown
                                        location:NSZeroPoint
                                   modifierFlags:NSEventModifierFlagCommand
                                       timestamp:0
                                    windowNumber:win.windowNumber
                                         context:nil
                                      characters:[NSString stringWithCharacters:&leftChar length:1]
                     charactersIgnoringModifiers:[NSString stringWithCharacters:&leftChar length:1]
                                       isARepeat:NO
                                         keyCode:123];
    SPExpect([win performKeyEquivalent:cmdLeft], @"Cmd+Left handled by text field editor");
    SPExpectEqualStr(store.playbackState.currentTrackURI, @"spotify:track:t-1", "Cmd+Left did NOT skip track while editing text");

    // Navigate away from Search -> resigns first responder cleanly so Space toggles playback (UX-H1).
    [shell openArtistWithID:@"art-0"];
    [win.contentView layoutSubtreeIfNeeded];
    SPExpect(!win.isEditingText, @"navigating to Artist Detail resigned search field focus");
    NSEvent *space = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0
                                     timestamp:0 windowNumber:win.windowNumber context:nil
                                    characters:@" " charactersIgnoringModifiers:@" " isARepeat:NO keyCode:49];
    SPExpect([win handleKeyEvent:space], @"Space handled as playback toggle after leaving search");
    SPExpectEqualInt(engine.status, SPAudioEngineStatusPaused, "Space paused playback instead of typing into search");

    // 2. SPArtistDetailView at minimum window height (760x520) MUST keep Discography height > 0 px (UX-H3).
    [win setContentSize:NSMakeSize(760.0, 520.0)];
    [win.contentView layoutSubtreeIfNeeded];
    SPArtistDetailView *artistView = (SPArtistDetailView *)shell.currentContentView;
    SPExpect([artistView isKindOfClass:SPArtistDetailView.class], @"Artist detail mounted");
    SPExpectEqualInt(artistView.topTracksList.tracks.count, 3, "Artist top tracks populated from artist.topTrackIDs");
    SPExpect(artistView.discographyGrid.frame.size.height >= 150.0,
             @"Artist discography grid has non-zero scrollable height at min window size (got %.1f)",
             artistView.discographyGrid.frame.size.height);

    // 3. Escape from Search must not leave duplicate back-stack entry (UX-M5).
    [shell openHome];
    [shell.toolbarSearchField focusSelectingAll:NO];
    [shell.toolbarSearchField typeString:@"daft"];
    SPExpectEqualInt(shell.currentRoute.kind, SPRouteSearch, "in Search route");
    if (shell.toolbarSearchField.onEscape) shell.toolbarSearchField.onEscape();
    SPExpectEqualInt(shell.currentRoute.kind, SPRouteHome, "Escape returned to Home");
    [shell goBack];
    SPExpect(shell.currentRoute.kind != SPRouteHome, @"Back after Search Escape did not navigate Home -> Home");

    // 4. Shuffle button idempotency (UX-M4): setShuffleEnabled:YES keeps shuffle ON when already ON.
    [shell setShuffleEnabled:YES];
    SPExpect(store.playbackState.shuffling, @"shuffle turned ON");
    [shell setShuffleEnabled:YES];
    SPExpect(store.playbackState.shuffling, @"calling setShuffleEnabled:YES again keeps shuffle ON");

    // 5. Closed-window frame restore & search query restore (UX-M2).
    [shell openSearchWithQuery:@"daft" focus:NO];
    NSRect customFrame = NSMakeRect(120.0, 140.0, 920.0, 610.0);
    [win setFrame:customFrame display:NO];
    [shell closeWindowReleasingViews];
    SPWindow *reopened = [shell ensureWindow];
    SPExpect(fabs(reopened.frame.size.width - 920.0) < 2.0 && fabs(reopened.frame.size.height - 610.0) < 2.0,
             @"reopened window restored saved frame size");
    SPExpectEqualStr(shell.toolbarSearchField.stringValue, @"daft", "reopened Search window restored query text");

    // 6. Preferences Change Key toggle & live store observation (UX-M7).
    SPPreferencesWindowController *prefs = [[SPPreferencesWindowController alloc] initWithStore:store];
    prefs.enginePreference = SPAudioEnginePrefSoloist;
    prefs.activeEngineKind = SPAudioEngineKindSoloist;
    prefs.soloistKeyMissingOrFailed = NO;
    [prefs refreshState];
    SPExpect(!prefs.soloistKeySectionVisible && prefs.soloistChangeKeyButtonVisible,
             @"saved Soloist key exposes Change Key button");
    [prefs beginEditingSoloistKey];
    SPExpect(prefs.soloistKeySectionVisible, @"clicking Change Key reveals Soloist key field for editing");
    [prefs close];

    [shell closeWindowReleasingViews];
}
