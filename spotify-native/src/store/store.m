// Normalized domain store backed by SQLite WAL with in-place derived lists and <1 ms local search.
#import "store/store.h"
#import "model/json.h"

#import <CoreFoundation/CoreFoundation.h>
#import <stdlib.h>
#import <string.h>

static const NSUInteger kSPRecentSearchLimit = 10;

/// Folds a string to lowercase diacritic-stripped UTF-8 for fast C substring/prefix scanning.
/// Caller frees returned buffer.
static char *SPFoldUTF8(NSString *input, size_t *outLen) {
    if (!input.length) {
        char *empty = (char *)malloc(1);
        empty[0] = '\0';
        if (outLen) *outLen = 0;
        return empty;
    }

    const char *utf8 = input.UTF8String;
    if (utf8) {
        BOOL allASCII = YES;
        size_t len = 0;
        for (const unsigned char *p = (const unsigned char *)utf8; *p; p++) {
            if (*p >= 0x80) { allASCII = NO; break; }
            len++;
        }
        if (allASCII) {
            char *buf = (char *)malloc(len + 1);
            for (size_t i = 0; i < len; i++) {
                unsigned char c = (unsigned char)utf8[i];
                buf[i] = (char)((c >= 'A' && c <= 'Z') ? (c + ('a' - 'A')) : c);
            }
            buf[len] = '\0';
            if (outLen) *outLen = len;
            return buf;
        }
    }

    CFMutableStringRef m = CFStringCreateMutableCopy(kCFAllocatorDefault, 0, (__bridge CFStringRef)input);
    CFStringTransform(m, NULL, kCFStringTransformStripCombiningMarks, false);
    CFStringLowercase(m, NULL);
    NSString *folded = CFBridgingRelease(m);
    const char *futf8 = folded.UTF8String ?: "";
    size_t flen = strlen(futf8);
    char *buf = (char *)malloc(flen + 1);
    memcpy(buf, futf8, flen + 1);
    if (outLen) *outLen = flen;
    return buf;
}

typedef struct {
    /// Offsets into `SPFoldedIndex.arena` (0 for secondaryOff/tertiaryOff means absent).
    uint32_t primaryOff;
    uint32_t primaryLen;
    uint32_t secondaryOff;
    uint32_t tertiaryOff;
} SPFoldedEntry;

typedef struct {
    SPFoldedEntry *entries;
    NSUInteger count;
    NSUInteger capacity;
    char *arena;
    size_t arenaLen;
    size_t arenaCap;
    size_t arenaDeadBytes;
} SPFoldedIndex;

static void FoldedIndexFree(SPFoldedIndex *idx) {
    free(idx->entries);
    free(idx->arena);
    idx->entries = NULL;
    idx->count = 0;
    idx->capacity = 0;
    idx->arena = NULL;
    idx->arenaLen = 0;
    idx->arenaCap = 0;
    idx->arenaDeadBytes = 0;
}

static void FoldedIndexReserve(SPFoldedIndex *idx, NSUInteger needed) {
    if (needed <= idx->capacity) return;
    NSUInteger cap = idx->capacity ? idx->capacity * 2 : 64;
    while (cap < needed) cap *= 2;
    idx->entries = (SPFoldedEntry *)realloc(idx->entries, cap * sizeof(SPFoldedEntry));
    idx->capacity = cap;
}

static void FoldedIndexReserveArena(SPFoldedIndex *idx, size_t extra) {
    size_t needed = idx->arenaLen + extra;
    if (needed <= idx->arenaCap) return;
    size_t cap = idx->arenaCap ? idx->arenaCap * 2 : 4096;
    while (cap < needed) cap *= 2;
    idx->arena = (char *)realloc(idx->arena, cap);
    idx->arenaCap = cap;
}

static size_t FoldedEntryBytes(const SPFoldedIndex *idx, const SPFoldedEntry *e) {
    size_t bytes = (size_t)e->primaryLen + 1;
    if (e->secondaryOff) bytes += strlen(idx->arena + e->secondaryOff) + 1;
    if (e->tertiaryOff) bytes += strlen(idx->arena + e->tertiaryOff) + 1;
    return bytes;
}

static void FoldedIndexCompactArenaIfNeeded(SPFoldedIndex *idx) {
    if (idx->arenaDeadBytes < 65536 || idx->arenaDeadBytes * 2 < idx->arenaLen) return;
    size_t liveBytes = idx->arenaLen > idx->arenaDeadBytes ? (idx->arenaLen - idx->arenaDeadBytes) : 4096;
    size_t newCap = MAX((size_t)4096, liveBytes + 4096);
    char *next = (char *)malloc(newCap);
    next[0] = '\0';
    size_t off = 1;
    for (NSUInteger i = 0; i < idx->count; i++) {
        SPFoldedEntry *e = &idx->entries[i];
        size_t pBytes = (size_t)e->primaryLen + 1;
        size_t sBytes = e->secondaryOff ? (strlen(idx->arena + e->secondaryOff) + 1) : 0;
        size_t tBytes = e->tertiaryOff ? (strlen(idx->arena + e->tertiaryOff) + 1) : 0;
        size_t total = pBytes + sBytes + tBytes;
        if (off + total > newCap) {
            while (off + total > newCap) newCap *= 2;
            next = (char *)realloc(next, newCap);
        }
        uint32_t newPOff = (uint32_t)off;
        memcpy(next + off, idx->arena + e->primaryOff, pBytes);
        off += pBytes;
        uint32_t newSOff = 0;
        if (sBytes > 0) {
            newSOff = (uint32_t)off;
            memcpy(next + off, idx->arena + e->secondaryOff, sBytes);
            off += sBytes;
        }
        uint32_t newTOff = 0;
        if (tBytes > 0) {
            newTOff = (uint32_t)off;
            memcpy(next + off, idx->arena + e->tertiaryOff, tBytes);
            off += tBytes;
        }
        e->primaryOff = newPOff;
        e->secondaryOff = newSOff;
        e->tertiaryOff = newTOff;
    }
    free(idx->arena);
    idx->arena = next;
    idx->arenaLen = off;
    idx->arenaCap = newCap;
    idx->arenaDeadBytes = 0;
}

static size_t FoldIntoStackOrHeap(NSString *input, char *stackBuf, size_t stackCap, char **heapOut) {
    *heapOut = NULL;
    if (!input.length) {
        stackBuf[0] = '\0';
        return 0;
    }
    const char *utf8 = input.UTF8String;
    if (utf8) {
        BOOL allASCII = YES;
        size_t len = 0;
        for (const unsigned char *p = (const unsigned char *)utf8; *p; p++) {
            if (*p >= 0x80) { allASCII = NO; break; }
            len++;
        }
        if (allASCII) {
            char *dst = (len + 1 <= stackCap) ? stackBuf : (char *)malloc(len + 1);
            if (dst != stackBuf) *heapOut = dst;
            for (size_t i = 0; i < len; i++) {
                unsigned char c = (unsigned char)utf8[i];
                dst[i] = (char)((c >= 'A' && c <= 'Z') ? (c + ('a' - 'A')) : c);
            }
            dst[len] = '\0';
            return len;
        }
    }
    size_t outLen = 0;
    *heapOut = SPFoldUTF8(input, &outLen);
    return outLen;
}

static SPFoldedEntry MakeFoldedEntry(SPFoldedIndex *idx, NSString *p, NSString *s, NSString *t) {
    SPFoldedEntry e = {0};
    char pStack[256], sStack[256], tStack[256];
    char *pHeap = NULL, *sHeap = NULL, *tHeap = NULL;
    size_t pLen = FoldIntoStackOrHeap(p, pStack, sizeof(pStack), &pHeap);
    size_t sLen = s.length ? FoldIntoStackOrHeap(s, sStack, sizeof(sStack), &sHeap) : 0;
    size_t tLen = t.length ? FoldIntoStackOrHeap(t, tStack, sizeof(tStack), &tHeap) : 0;

    if (idx->arenaLen == 0) {
        FoldedIndexReserveArena(idx, 1);
        idx->arena[0] = '\0';
        idx->arenaLen = 1; // Reserve offset 0 as sentinel for "absent".
    }
    size_t total = pLen + 1 + (sLen ? (sLen + 1) : 0) + (tLen ? (tLen + 1) : 0);
    FoldedIndexReserveArena(idx, total);

    size_t off = idx->arenaLen;
    e.primaryOff = (uint32_t)off;
    e.primaryLen = (uint32_t)pLen;
    memcpy(idx->arena + off, pHeap ?: pStack, pLen + 1);
    off += pLen + 1;
    if (sLen > 0) {
        e.secondaryOff = (uint32_t)off;
        memcpy(idx->arena + off, sHeap ?: sStack, sLen + 1);
        off += sLen + 1;
    }
    if (tLen > 0) {
        e.tertiaryOff = (uint32_t)off;
        memcpy(idx->arena + off, tHeap ?: tStack, tLen + 1);
        off += tLen + 1;
    }
    idx->arenaLen = off;
    free(pHeap);
    free(sHeap);
    free(tHeap);
    return e;
}

static void FoldedIndexClear(SPFoldedIndex *idx) {
    idx->count = 0;
    idx->arenaLen = 0;
    idx->arenaDeadBytes = 0;
}

static void FoldedIndexAppend(SPFoldedIndex *idx, NSString *p, NSString *s, NSString *t) {
    FoldedIndexReserve(idx, idx->count + 1);
    idx->entries[idx->count++] = MakeFoldedEntry(idx, p, s, t);
}

static void FoldedIndexInsertAtZero(SPFoldedIndex *idx, NSString *p, NSString *s, NSString *t) {
    FoldedIndexReserve(idx, idx->count + 1);
    SPFoldedEntry entry = MakeFoldedEntry(idx, p, s, t);
    if (idx->count > 0) {
        memmove(&idx->entries[1], &idx->entries[0], idx->count * sizeof(SPFoldedEntry));
    }
    idx->entries[0] = entry;
    idx->count++;
}

static void FoldedIndexRemoveAt(SPFoldedIndex *idx, NSUInteger pos) {
    if (pos >= idx->count) return;
    idx->arenaDeadBytes += FoldedEntryBytes(idx, &idx->entries[pos]);
    if (pos + 1 < idx->count) {
        memmove(&idx->entries[pos], &idx->entries[pos + 1], (idx->count - pos - 1) * sizeof(SPFoldedEntry));
    }
    idx->count--;
    FoldedIndexCompactArenaIfNeeded(idx);
}

static void FoldedIndexReplaceAt(SPFoldedIndex *idx, NSUInteger pos, NSString *p, NSString *s, NSString *t) {
    if (pos >= idx->count) return;
    idx->arenaDeadBytes += FoldedEntryBytes(idx, &idx->entries[pos]);
    idx->entries[pos] = MakeFoldedEntry(idx, p, s, t);
    FoldedIndexCompactArenaIfNeeded(idx);
}

/// Returns match score 0..4, or -1 if no match.
static inline int ScoreFoldedEntry(const char *arena, const SPFoldedEntry *e, const char *needle, size_t needleLen) {
    const char *primary = arena + e->primaryOff;
    if (e->primaryLen >= needleLen) {
        if (e->primaryLen == needleLen && memcmp(primary, needle, needleLen) == 0) return 4; // exact
        if (memcmp(primary, needle, needleLen) == 0) return 3;                                // prefix
        const char *hit = strstr(primary, needle);
        if (hit) return (hit > primary && hit[-1] == ' ') ? 2 : 1;                           // word-prefix / substring
    }
    if (e->secondaryOff) {
        const char *secondary = arena + e->secondaryOff;
        const char *hit = strstr(secondary, needle);
        if (hit) return (hit == secondary || hit[-1] == ' ') ? 1 : 0;
    }
    if (e->tertiaryOff) {
        const char *tertiary = arena + e->tertiaryOff;
        if (strstr(tertiary, needle)) return 0;
    }
    return -1;
}

typedef struct {
    NSUInteger index;
    int score;
} SPMatchRank;

/// Scans `idx` and returns top `limit` matching objects from `source` sorted by score desc, then original order.
static NSArray *ScanFoldedIndex(const SPFoldedIndex *idx, NSArray *source, const char *needle, size_t needleLen, NSUInteger limit) {
    if (idx->count == 0 || needleLen == 0 || limit == 0) return @[];
    // Bucket by score (0..4) for O(N) stable top-K without sorting all matches.
    NSUInteger buckets[5][64];
    NSUInteger counts[5] = {0, 0, 0, 0, 0};
    NSUInteger cap = limit < 64 ? limit : 64;

    for (NSUInteger i = 0; i < idx->count; i++) {
        int score = ScoreFoldedEntry(idx->arena, &idx->entries[i], needle, needleLen);
        if (score >= 0 && counts[score] < cap) {
            buckets[score][counts[score]++] = i;
        }
    }

    NSMutableArray *out = [NSMutableArray arrayWithCapacity:limit];
    for (int s = 4; s >= 0 && out.count < limit; s--) {
        for (NSUInteger j = 0; j < counts[s] && out.count < limit; j++) {
            [out addObject:source[buckets[s][j]]];
        }
    }
    return out;
}

@implementation SPStore {
    NSMutableDictionary<NSString *, SPTrack *> *_tracksByID;
    NSMutableDictionary<NSString *, SPAlbum *> *_albumsByID;
    NSMutableDictionary<NSString *, SPArtist *> *_artistsByID;
    NSMutableDictionary<NSString *, SPPlaylist *> *_playlistsByID;

    NSMutableArray<NSString *> *_libraryTrackIDs;
    NSMutableArray<SPTrack *> *_libraryTracks;
    NSMutableDictionary<NSString *, NSNumber *> *_libraryTrackPos; // trackID -> index in _libraryTracks
    NSMutableSet<NSString *> *_favoriteTrackIDs;
    NSMutableSet<NSString *> *_resolvedFavoriteIDs;

    NSMutableArray<NSString *> *_libraryAlbumIDs;
    NSMutableArray<SPAlbum *> *_libraryAlbums;
    NSMutableArray<NSString *> *_libraryArtistIDs;
    NSMutableArray<SPArtist *> *_libraryArtists;
    NSMutableArray<NSString *> *_libraryPlaylistIDs;
    NSMutableArray<SPPlaylist *> *_libraryPlaylists;

    NSArray<SPHomeShelf *> *_homeShelves;
    NSMutableArray<NSString *> *_recentSearches;

    SPFoldedIndex _trackSearchIndex;
    SPFoldedIndex _albumSearchIndex;
    SPFoldedIndex _artistSearchIndex;
    SPFoldedIndex _playlistSearchIndex;
}

- (instancetype)init {
    return [self initWithDatabase:nil];
}

- (instancetype)initWithDatabase:(SPDatabase *)database {
    if (!(self = [super init])) return nil;
    _database = database;
    _changes = [SPChangeQueue new];

    _tracksByID = [NSMutableDictionary new];
    _albumsByID = [NSMutableDictionary new];
    _artistsByID = [NSMutableDictionary new];
    _playlistsByID = [NSMutableDictionary new];

    _libraryTrackIDs = [NSMutableArray new];
    _libraryTracks = [NSMutableArray new];
    _libraryTrackPos = [NSMutableDictionary new];
    _favoriteTrackIDs = [NSMutableSet new];
    _resolvedFavoriteIDs = [NSMutableSet new];

    _libraryAlbumIDs = [NSMutableArray new];
    _libraryAlbums = [NSMutableArray new];
    _libraryArtistIDs = [NSMutableArray new];
    _libraryArtists = [NSMutableArray new];
    _libraryPlaylistIDs = [NSMutableArray new];
    _libraryPlaylists = [NSMutableArray new];

    _homeShelves = @[];
    _recentSearches = [NSMutableArray new];
    _devices = @[];

    if (_database) [self restoreFromDatabase];
    return self;
}

- (void)dealloc {
    FoldedIndexFree(&_trackSearchIndex);
    FoldedIndexFree(&_albumSearchIndex);
    FoldedIndexFree(&_artistSearchIndex);
    FoldedIndexFree(&_playlistSearchIndex);
}

- (void)restoreFromDatabase {
    @autoreleasepool {
        for (SPTrack *t in [_database allTracks]) _tracksByID[t.trackID] = t;
        for (SPAlbum *a in [_database allAlbums]) _albumsByID[a.albumID] = a;
        for (SPArtist *ar in [_database allArtists]) _artistsByID[ar.artistID] = ar;
        for (SPPlaylist *pl in [_database allPlaylists]) _playlistsByID[pl.playlistID] = pl;

        [self rebuildLibraryTracksFromIDs:[_database libraryTrackIDs]];
        [self rebuildLibraryAlbumsFromIDs:[_database libraryAlbumIDs]];
        [self rebuildLibraryArtistsFromIDs:[_database libraryArtistIDs]];
        [self rebuildLibraryPlaylistsFromIDs:[_database libraryPlaylistIDs]];

        _homeShelves = [_database allHomeShelves];
        [_recentSearches addObjectsFromArray:[_database allRecentSearches]];

        NSDictionary *prof = SPJSONDict([_database jsonForKey:@"user_profile"]);
        if (prof) {
            NSString *u = SPJSONString(prof[@"username"]);
            if (u.length) {
                _userProfile = [[SPUserProfile alloc] initWithUsername:u
                                                           displayName:SPJSONString(prof[@"displayName"]) ?: u
                                                                   uri:SPJSONString(prof[@"uri"]) ?: @""
                                                             avatarURL:SPJSONString(prof[@"avatarURL"])];
            }
        }
    }
    // Release SQLite scan page buffers immediately after hydrating into memory.
    [_database releaseMemory];
}

- (void)addObserver:(id<SPChangeObserver>)observer { [_changes addObserver:observer]; }
- (void)removeObserver:(id<SPChangeObserver>)observer { [_changes removeObserver:observer]; }

- (NSArray<SPTrack *> *)libraryTracks { return _libraryTracks; }
- (NSArray<SPAlbum *> *)libraryAlbums { return _libraryAlbums; }
- (NSArray<SPArtist *> *)libraryArtists { return _libraryArtists; }
- (NSArray<SPPlaylist *> *)libraryPlaylists { return _libraryPlaylists; }
- (NSArray<SPHomeShelf *> *)homeShelves { return _homeShelves; }
- (NSArray<NSString *> *)recentSearches { return _recentSearches; }

- (SPTrack *)trackWithID:(NSString *)trackID { return trackID ? _tracksByID[trackID] : nil; }
- (SPAlbum *)albumWithID:(NSString *)albumID { return albumID ? _albumsByID[albumID] : nil; }
- (SPArtist *)artistWithID:(NSString *)artistID { return artistID ? _artistsByID[artistID] : nil; }
- (SPPlaylist *)playlistWithID:(NSString *)playlistID { return playlistID ? _playlistsByID[playlistID] : nil; }
- (BOOL)isFavoriteTrackID:(NSString *)trackID { return trackID && [_favoriteTrackIDs containsObject:trackID]; }
- (BOOL)hasResolvedFavoriteStatusForTrackID:(NSString *)trackID {
    return trackID && ([_favoriteTrackIDs containsObject:trackID] || [_resolvedFavoriteIDs containsObject:trackID]);
}

#pragma mark - Derived List Maintenance (In-Place on Write)

- (void)rebuildLibraryTracksFromIDs:(NSArray<NSString *> *)ids {
    [_libraryTrackIDs removeAllObjects];
    [_libraryTracks removeAllObjects];
    [_libraryTrackPos removeAllObjects];
    [_favoriteTrackIDs removeAllObjects];
    FoldedIndexClear(&_trackSearchIndex);
    FoldedIndexReserve(&_trackSearchIndex, ids.count);

    for (NSString *tid in ids) {
        SPTrack *t = _tracksByID[tid];
        NSString *key = t ? t.trackID : tid;
        if ([_favoriteTrackIDs containsObject:key]) continue;
        [_favoriteTrackIDs addObject:key];
        [_resolvedFavoriteIDs removeObject:key];
        [_libraryTrackIDs addObject:key];
        if (t) {
            NSUInteger idx = _libraryTracks.count;
            [_libraryTracks addObject:t];
            _libraryTrackPos[key] = @(idx);
            FoldedIndexAppend(&_trackSearchIndex, t.name, t.artistName, t.albumName);
        }
    }
}

- (void)rebuildLibraryAlbumsFromIDs:(NSArray<NSString *> *)ids {
    [_libraryAlbumIDs removeAllObjects];
    [_libraryAlbums removeAllObjects];
    FoldedIndexClear(&_albumSearchIndex);
    FoldedIndexReserve(&_albumSearchIndex, ids.count);
    for (NSString *aid in ids) {
        [_libraryAlbumIDs addObject:aid];
        SPAlbum *a = _albumsByID[aid];
        if (a) {
            [_libraryAlbums addObject:a];
            FoldedIndexAppend(&_albumSearchIndex, a.name, a.artistName, nil);
        }
    }
}

- (void)rebuildLibraryArtistsFromIDs:(NSArray<NSString *> *)ids {
    [_libraryArtistIDs removeAllObjects];
    [_libraryArtists removeAllObjects];
    FoldedIndexClear(&_artistSearchIndex);
    FoldedIndexReserve(&_artistSearchIndex, ids.count);
    for (NSString *aid in ids) {
        [_libraryArtistIDs addObject:aid];
        SPArtist *ar = _artistsByID[aid];
        if (ar) {
            [_libraryArtists addObject:ar];
            FoldedIndexAppend(&_artistSearchIndex, ar.name, nil, nil);
        }
    }
}

- (void)rebuildLibraryPlaylistsFromIDs:(NSArray<NSString *> *)ids {
    [_libraryPlaylistIDs removeAllObjects];
    [_libraryPlaylists removeAllObjects];
    FoldedIndexClear(&_playlistSearchIndex);
    FoldedIndexReserve(&_playlistSearchIndex, ids.count);
    for (NSString *pid in ids) {
        [_libraryPlaylistIDs addObject:pid];
        SPPlaylist *pl = _playlistsByID[pid];
        if (pl) {
            [_libraryPlaylists addObject:pl];
            FoldedIndexAppend(&_playlistSearchIndex, pl.name, pl.ownerName, nil);
        }
    }
}

#pragma mark - Entity Upserts

- (void)withTransaction:(void (^)(void))block {
    if (_database) [_database transaction:block];
    else block();
}

- (void)upsertTracks:(NSArray<SPTrack *> *)tracks {
    if (!tracks.count) return;
    [self withTransaction:^{
        for (SPTrack *t in tracks) {
            self->_tracksByID[t.trackID] = t;
            [self->_database upsertTrack:t];
            NSNumber *pos = self->_libraryTrackPos[t.trackID];
            if (pos) {
                NSUInteger idx = pos.unsignedIntegerValue;
                self->_libraryTracks[idx] = t;
                FoldedIndexReplaceAt(&self->_trackSearchIndex, idx, t.name, t.artistName, t.albumName);
            } else if ([self->_favoriteTrackIDs containsObject:t.trackID]) {
                NSUInteger idx = self->_libraryTracks.count;
                [self->_libraryTracks addObject:t];
                self->_libraryTrackPos[t.trackID] = @(idx);
                FoldedIndexAppend(&self->_trackSearchIndex, t.name, t.artistName, t.albumName);
            }
            [self->_changes note:SPChangeTracks value:t.trackID];
        }
    }];
}

- (void)upsertAlbums:(NSArray<SPAlbum *> *)albums {
    if (!albums.count) return;
    [self withTransaction:^{
        for (SPAlbum *a in albums) {
            SPAlbum *existing = self->_albumsByID[a.albumID];
            // Never overwrite a detailsLoaded album with a summary stub.
            SPAlbum *merged = a;
            if (existing && existing.detailsLoaded && !a.detailsLoaded) {
                merged = existing;
            } else {
                self->_albumsByID[a.albumID] = merged;
                [self->_database upsertAlbum:merged];
            }
            for (NSUInteger i = 0; i < self->_libraryAlbums.count; i++) {
                if ([self->_libraryAlbums[i].albumID isEqualToString:merged.albumID]) {
                    self->_libraryAlbums[i] = merged;
                    FoldedIndexReplaceAt(&self->_albumSearchIndex, i, merged.name, merged.artistName, nil);
                    break;
                }
            }
            [self->_changes note:SPChangeAlbums value:merged.albumID];
        }
    }];
}

- (void)upsertArtists:(NSArray<SPArtist *> *)artists {
    if (!artists.count) return;
    [self withTransaction:^{
        for (SPArtist *ar in artists) {
            SPArtist *existing = self->_artistsByID[ar.artistID];
            SPArtist *merged = (existing && existing.detailsLoaded && !ar.detailsLoaded) ? existing : ar;
            if (merged != existing) {
                self->_artistsByID[ar.artistID] = merged;
                [self->_database upsertArtist:merged];
            }
            for (NSUInteger i = 0; i < self->_libraryArtists.count; i++) {
                if ([self->_libraryArtists[i].artistID isEqualToString:merged.artistID]) {
                    self->_libraryArtists[i] = merged;
                    FoldedIndexReplaceAt(&self->_artistSearchIndex, i, merged.name, nil, nil);
                    break;
                }
            }
            [self->_changes note:SPChangeArtists value:merged.artistID];
        }
    }];
}

- (void)upsertPlaylists:(NSArray<SPPlaylist *> *)playlists {
    if (!playlists.count) return;
    [self withTransaction:^{
        for (SPPlaylist *pl in playlists) {
            SPPlaylist *existing = self->_playlistsByID[pl.playlistID];
            SPPlaylist *merged = (existing && existing.detailsLoaded && !pl.detailsLoaded) ? existing : pl;
            if (merged != existing) {
                self->_playlistsByID[pl.playlistID] = merged;
                [self->_database upsertPlaylist:merged];
            }
            for (NSUInteger i = 0; i < self->_libraryPlaylists.count; i++) {
                if ([self->_libraryPlaylists[i].playlistID isEqualToString:merged.playlistID]) {
                    self->_libraryPlaylists[i] = merged;
                    FoldedIndexReplaceAt(&self->_playlistSearchIndex, i, merged.name, merged.ownerName, nil);
                    break;
                }
            }
            [self->_changes note:SPChangePlaylists value:merged.playlistID];
        }
    }];
}

#pragma mark - Library Lists & Favorites

- (void)setLibraryTrackIDs:(NSArray<NSString *> *)trackIDs addedAtByID:(NSDictionary<NSString *, NSNumber *> *)addedAt {
    [self rebuildLibraryTracksFromIDs:trackIDs];
    [_database replaceLibraryTrackIDs:_libraryTrackIDs addedAtByID:addedAt];
    [_changes note:SPChangeLibraryLists value:nil];
}

- (void)appendLibraryTrackIDs:(NSArray<NSString *> *)trackIDs addedAtByID:(NSDictionary<NSString *, NSNumber *> *)addedAt {
    if (!trackIDs.count) return;
    NSMutableArray<NSString *> *addedIDs = [NSMutableArray new];
    for (NSString *tid in trackIDs) {
        if (!tid.length || [_favoriteTrackIDs containsObject:tid]) continue;
        [addedIDs addObject:tid];
        [_favoriteTrackIDs addObject:tid];
        [_resolvedFavoriteIDs removeObject:tid];
        [_libraryTrackIDs addObject:tid];
        SPTrack *t = _tracksByID[tid];
        if (t) {
            NSUInteger idx = _libraryTracks.count;
            [_libraryTracks addObject:t];
            _libraryTrackPos[tid] = @(idx);
            FoldedIndexAppend(&_trackSearchIndex, t.name, t.artistName, t.albumName);
        }
    }
    if (!addedIDs.count) return;
    [_database appendLibraryTrackIDs:addedIDs addedAtByID:addedAt];
    [_changes note:SPChangeLibraryLists value:nil];
}

- (void)setLibraryAlbumIDs:(NSArray<NSString *> *)albumIDs addedAtByID:(NSDictionary<NSString *, NSNumber *> *)addedAt {
    [self rebuildLibraryAlbumsFromIDs:albumIDs];
    [_database replaceLibraryAlbumIDs:_libraryAlbumIDs addedAtByID:addedAt];
    [_changes note:SPChangeLibraryLists value:nil];
}

- (void)setLibraryArtistIDs:(NSArray<NSString *> *)artistIDs {
    [self rebuildLibraryArtistsFromIDs:artistIDs];
    [_database replaceLibraryArtistIDs:_libraryArtistIDs];
    [_changes note:SPChangeLibraryLists value:nil];
}

- (void)setLibraryPlaylistIDs:(NSArray<NSString *> *)playlistIDs {
    [self rebuildLibraryPlaylistsFromIDs:playlistIDs];
    [_database replaceLibraryPlaylistIDs:_libraryPlaylistIDs];
    [_changes note:SPChangeLibraryLists value:nil];
}

- (BOOL)toggleFavoriteTrackID:(NSString *)trackID {
    BOOL next = ![self isFavoriteTrackID:trackID];
    [self setFavorite:next forTrackID:trackID];
    return next;
}

- (void)setFavorite:(BOOL)favorite forTrackID:(NSString *)trackID {
    if (!trackID.length) return;
    if (favorite) {
        [_resolvedFavoriteIDs removeObject:trackID];
    } else {
        [_resolvedFavoriteIDs addObject:trackID];
    }
    BOOL current = [_favoriteTrackIDs containsObject:trackID];
    if (current == favorite) return;

    if (favorite) {
        [_favoriteTrackIDs addObject:trackID];
        [_libraryTrackIDs insertObject:trackID atIndex:0];
        SPTrack *t = _tracksByID[trackID];
        if (t) {
            [_libraryTracks insertObject:t atIndex:0];
            FoldedIndexInsertAtZero(&_trackSearchIndex, t.name, t.artistName, t.albumName);
            // Update position map in place.
            for (NSUInteger i = 0; i < _libraryTracks.count; i++) {
                _libraryTrackPos[_libraryTracks[i].trackID] = @(i);
            }
        }
        [_database insertLibraryTrackID:trackID atPosition:0 addedAt:NSDate.date.timeIntervalSince1970];
    } else {
        [_favoriteTrackIDs removeObject:trackID];
        [_libraryTrackIDs removeObject:trackID];
        NSNumber *posNum = _libraryTrackPos[trackID];
        if (posNum) {
            NSUInteger pos = posNum.unsignedIntegerValue;
            [_libraryTracks removeObjectAtIndex:pos];
            FoldedIndexRemoveAt(&_trackSearchIndex, pos);
            [_libraryTrackPos removeObjectForKey:trackID];
            for (NSUInteger i = pos; i < _libraryTracks.count; i++) {
                _libraryTrackPos[_libraryTracks[i].trackID] = @(i);
            }
        }
        [_database deleteLibraryTrackID:trackID];
    }
    [_changes note:SPChangeFavorites value:trackID];
}

- (void)updateFavoriteStatuses:(NSDictionary<NSString *, NSNumber *> *)statuses {
    if (!statuses.count) return;
    [self withTransaction:^{
        for (NSString *tid in statuses) {
            BOOL fav = statuses[tid].boolValue;
            [self setFavorite:fav forTrackID:tid];
        }
    }];
}

#pragma mark - Home, Profile, Recent Searches, Connect

- (void)applyHomePage:(SPHomePage *)homePage {
    if (!homePage) return;
    [self withTransaction:^{
        [self upsertAlbums:homePage.albums];
        [self upsertArtists:homePage.artists];
        [self upsertPlaylists:homePage.playlists];
        self->_homeShelves = [homePage.shelves copy];
        [self->_database replaceHomeShelves:self->_homeShelves];
    }];
    [_changes note:SPChangeHomeShelves value:nil];
}

- (void)setUserProfile:(SPUserProfile *)profile {
    _userProfile = profile;
    if (profile) {
        [_database setJSON:@{
            @"username" : profile.username,
            @"displayName" : profile.displayName,
            @"uri" : profile.uri,
            @"avatarURL" : profile.avatarURL ?: @"",
        } forKey:@"user_profile"];
    } else {
        [_database setJSON:nil forKey:@"user_profile"];
    }
    [_changes note:SPChangeProfile value:nil];
}

- (void)recordRecentSearch:(NSString *)query {
    NSString *trimmed = [query stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!trimmed.length) return;
    [_recentSearches removeObject:trimmed];
    [_recentSearches insertObject:trimmed atIndex:0];
    while (_recentSearches.count > kSPRecentSearchLimit) [_recentSearches removeLastObject];
    [_database replaceRecentSearches:_recentSearches];
    [_changes note:SPChangeRecentSearches value:nil];
}

- (void)removeRecentSearch:(NSString *)query {
    [_recentSearches removeObject:query];
    [_database replaceRecentSearches:_recentSearches];
    [_changes note:SPChangeRecentSearches value:nil];
}

- (void)clearRecentSearches {
    [_recentSearches removeAllObjects];
    [_database replaceRecentSearches:_recentSearches];
    [_changes note:SPChangeRecentSearches value:nil];
}

- (void)applyClusterState:(SPClusterState *)cluster {
    if (!cluster) return;
    _activeDeviceID = [cluster.activeDeviceID copy];
    _devices = [cluster.devices copy];
    if (cluster.playbackState || !_playbackState ||
        !cluster.activeDeviceID.length ||
        ![cluster.activeDeviceID isEqualToString:_playbackState.activeDeviceID ?: @""]) {
        _playbackState = cluster.playbackState;
    }
    [_changes note:SPChangeDevices value:nil];
    [_changes note:SPChangePlayback value:nil];
}

- (void)setPlaybackState:(SPPlaybackState *)state {
    _playbackState = state;
    [_changes note:SPChangePlayback value:nil];
}

- (void)setConnected:(BOOL)connected {
    if (_isConnected == connected) return;
    _isConnected = connected;
    [_changes note:SPChangeConnection value:nil];
}

#pragma mark - Sub-millisecond Local Search

- (SPSearchResults *)searchLocal:(NSString *)query {
    return [self searchLocal:query limitPerKind:25];
}

- (SPSearchResults *)searchLocal:(NSString *)query limitPerKind:(NSUInteger)limit {
    NSString *trimmed = [query stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!trimmed.length) {
        return [[SPSearchResults alloc] initWithQuery:@"" topHits:@[] tracks:@[] albums:@[] artists:@[] playlists:@[]
                                          tracksTotal:0 albumsTotal:0 artistsTotal:0 playlistsTotal:0
                                          suggestions:@[] isLocalOnly:YES];
    }

    size_t needleLen = 0;
    char *needle = SPFoldUTF8(trimmed, &needleLen);

    NSArray<SPTrack *> *tracks = ScanFoldedIndex(&_trackSearchIndex, _libraryTracks, needle, needleLen, limit);
    NSArray<SPAlbum *> *albums = ScanFoldedIndex(&_albumSearchIndex, _libraryAlbums, needle, needleLen, limit);
    NSArray<SPArtist *> *artists = ScanFoldedIndex(&_artistSearchIndex, _libraryArtists, needle, needleLen, limit);
    NSArray<SPPlaylist *> *playlists = ScanFoldedIndex(&_playlistSearchIndex, _libraryPlaylists, needle, needleLen, limit);

    free(needle);

    return [[SPSearchResults alloc] initWithQuery:trimmed
                                          topHits:@[]
                                           tracks:tracks
                                           albums:albums
                                          artists:artists
                                        playlists:playlists
                                      tracksTotal:(NSInteger)tracks.count
                                      albumsTotal:(NSInteger)albums.count
                                     artistsTotal:(NSInteger)artists.count
                                   playlistsTotal:(NSInteger)playlists.count
                                      suggestions:@[]
                                      isLocalOnly:YES];
}

@end
