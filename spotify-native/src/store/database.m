// SQLite WAL persistence with cached prepared statements and normalized domain tables.
#import "store/database.h"
#import "model/json.h"

#import <sqlite3.h>

static const int kSPSchemaVersion = 1;

static void RemoveSQLiteFiles(NSURL *url) {
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *suffix in @[ @"", @"-wal", @"-shm" ]) {
        [fm removeItemAtPath:[url.path stringByAppendingString:suffix] error:nil];
    }
}

static NSString *JoinList(NSArray<NSString *> *list) {
    return list.count ? [list componentsJoinedByString:@"\x1F"] : @"";
}

static NSArray<NSString *> *SplitList(NSString *raw) {
    if (!raw.length) return @[];
    return [raw componentsSeparatedByString:@"\x1F"];
}

static NSString *ColString(sqlite3_stmt *stmt, int col) {
    const unsigned char *text = sqlite3_column_text(stmt, col);
    if (!text) return nil;
    int bytes = sqlite3_column_bytes(stmt, col);
    return [[NSString alloc] initWithBytes:text length:(NSUInteger)bytes encoding:NSUTF8StringEncoding];
}

static void BindOptText(sqlite3_stmt *stmt, int idx, NSString *val) {
    if (val) {
        const char *utf8 = val.UTF8String;
        sqlite3_bind_text(stmt, idx, utf8, -1, SQLITE_TRANSIENT);
    } else {
        sqlite3_bind_null(stmt, idx);
    }
}

static void BindText(sqlite3_stmt *stmt, int idx, NSString *val) {
    const char *utf8 = (val ?: @"").UTF8String;
    sqlite3_bind_text(stmt, idx, utf8, -1, SQLITE_TRANSIENT);
}

@implementation SPDatabase {
    sqlite3 *_db;
    NSURL *_url;
    NSMutableDictionary<NSString *, NSValue *> *_statements;
    NSInteger _txDepth;
    BOOL _inTransaction;
    BOOL _txFailed;
}

+ (NSURL *)defaultFolder {
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    return [support URLByAppendingPathComponent:@"Spotify Native" isDirectory:YES];
}

+ (NSURL *)URLForAccount:(NSString *)account {
    NSString *safe = account.length ? account : @"default";
    return [self.defaultFolder URLByAppendingPathComponent:[safe stringByAppendingPathExtension:@"sqlite"]];
}

+ (instancetype)databaseAtURL:(NSURL *)url {
    NSURL *folder = url.URLByDeletingLastPathComponent;
    [NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:nil];
    [folder setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
    SPDatabase *db = [self openAtURL:url];
    if (db) return db;
    RemoveSQLiteFiles(url);
    return [self openAtURL:url];
}

+ (instancetype)openAtURL:(NSURL *)url {
    sqlite3 *handle = NULL;
    int rc = sqlite3_open_v2(url.fileSystemRepresentation,
                             &handle,
                             SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX,
                             NULL);
    if (rc != SQLITE_OK) {
        if (handle) sqlite3_close(handle);
        return nil;
    }
    sqlite3_busy_timeout(handle, 2000);
    SPDatabase *database = [self new];
    database->_db = handle;
    database->_url = [url copy];
    database->_statements = [NSMutableDictionary new];
    return [database prepareSchema] ? database : nil;
}

- (void)dealloc {
    [self close];
}

- (void)setBusyTimeoutMs:(int)timeoutMs {
    if (_db) sqlite3_busy_timeout(_db, timeoutMs);
}

- (void)releaseMemory {
    if (!_db) return;
    sqlite3_db_release_memory(_db);
    sqlite3_exec(_db, "PRAGMA shrink_memory;", NULL, NULL, NULL);
}

- (void)close {
    if (!_db) return;
    for (NSValue *val in _statements.allValues) {
        sqlite3_finalize((sqlite3_stmt *)val.pointerValue);
    }
    [_statements removeAllObjects];
    sqlite3_close(_db);
    _db = NULL;
}

- (void)deleteFile {
    [self close];
    if (_url) RemoveSQLiteFiles(_url);
}

- (int)schemaVersion {
    if (!_db) return -1;
    sqlite3_stmt *stmt = NULL;
    int ver = -1;
    if (sqlite3_prepare_v2(_db, "PRAGMA user_version", -1, &stmt, NULL) == SQLITE_OK && sqlite3_step(stmt) == SQLITE_ROW) {
        ver = sqlite3_column_int(stmt, 0);
    }
    sqlite3_finalize(stmt);
    return ver;
}

- (NSString *)journalMode {
    if (!_db) return @"";
    sqlite3_stmt *stmt = NULL;
    NSString *mode = @"";
    if (sqlite3_prepare_v2(_db, "PRAGMA journal_mode", -1, &stmt, NULL) == SQLITE_OK && sqlite3_step(stmt) == SQLITE_ROW) {
        mode = ColString(stmt, 0) ?: @"";
    }
    sqlite3_finalize(stmt);
    return mode;
}

- (void)ensureArtistTopTracksColumn {
    if (!_db) return;
    sqlite3_stmt *stmt = NULL;
    BOOL hasCol = NO;
    if (sqlite3_prepare_v2(_db, "PRAGMA table_info(artists)", -1, &stmt, NULL) == SQLITE_OK) {
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            NSString *colName = ColString(stmt, 1);
            if ([colName isEqualToString:@"top_track_ids"]) {
                hasCol = YES;
                break;
            }
        }
    }
    sqlite3_finalize(stmt);
    if (!hasCol) {
        sqlite3_exec(_db, "ALTER TABLE artists ADD COLUMN top_track_ids TEXT NOT NULL DEFAULT '';", NULL, NULL, NULL);
    }
}

- (BOOL)prepareSchema {
    if (sqlite3_exec(_db, "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;", NULL, NULL, NULL) != SQLITE_OK) return NO;
    int ver = [self schemaVersion];
    if (ver == kSPSchemaVersion) {
        [self ensureArtistTopTracksColumn];
        return YES;
    }
    if (ver != 0) return NO;

    NSString *ddl = [NSString stringWithFormat:
        @"BEGIN;"
        @"CREATE TABLE IF NOT EXISTS tracks ("
        @"  id TEXT PRIMARY KEY, uri TEXT NOT NULL, name TEXT NOT NULL,"
        @"  album_id TEXT, album_name TEXT, artist_id TEXT, artist_name TEXT NOT NULL,"
        @"  artist_names TEXT NOT NULL, duration_ms INTEGER NOT NULL,"
        @"  track_number INTEGER NOT NULL, disc_number INTEGER NOT NULL,"
        @"  artwork_url TEXT, artwork_small_url TEXT,"
        @"  playable INTEGER NOT NULL, unplayable_reason TEXT"
        @");"
        @"CREATE TABLE IF NOT EXISTS albums ("
        @"  id TEXT PRIMARY KEY, uri TEXT NOT NULL, name TEXT NOT NULL,"
        @"  album_type TEXT, artist_id TEXT, artist_name TEXT NOT NULL,"
        @"  artist_names TEXT NOT NULL, release_date TEXT,"
        @"  artwork_url TEXT, artwork_small_url TEXT,"
        @"  track_ids TEXT NOT NULL, total_track_count INTEGER NOT NULL,"
        @"  total_duration_ms INTEGER NOT NULL, details_loaded INTEGER NOT NULL"
        @");"
        @"CREATE TABLE IF NOT EXISTS artists ("
        @"  id TEXT PRIMARY KEY, uri TEXT NOT NULL, name TEXT NOT NULL,"
        @"  artwork_url TEXT, artwork_small_url TEXT,"
        @"  album_ids TEXT NOT NULL, top_track_ids TEXT NOT NULL DEFAULT '', details_loaded INTEGER NOT NULL"
        @");"
        @"CREATE TABLE IF NOT EXISTS playlists ("
        @"  id TEXT PRIMARY KEY, uri TEXT NOT NULL, name TEXT NOT NULL,"
        @"  description TEXT, owner_id TEXT NOT NULL, owner_name TEXT NOT NULL,"
        @"  artwork_url TEXT, artwork_small_url TEXT, is_public INTEGER NOT NULL,"
        @"  total_track_count INTEGER NOT NULL, details_loaded INTEGER NOT NULL"
        @");"
        @"CREATE TABLE IF NOT EXISTS playlist_tracks ("
        @"  playlist_id TEXT NOT NULL, position INTEGER NOT NULL,"
        @"  track_id TEXT NOT NULL, uid TEXT NOT NULL, added_at REAL NOT NULL,"
        @"  PRIMARY KEY (playlist_id, position)"
        @") WITHOUT ROWID;"
        @"CREATE TABLE IF NOT EXISTS library_tracks ("
        @"  position INTEGER NOT NULL, track_id TEXT PRIMARY KEY, added_at REAL NOT NULL"
        @");"
        @"CREATE INDEX IF NOT EXISTS idx_library_tracks_pos ON library_tracks(position);"
        @"CREATE TABLE IF NOT EXISTS library_albums ("
        @"  position INTEGER NOT NULL, album_id TEXT PRIMARY KEY, added_at REAL NOT NULL"
        @");"
        @"CREATE INDEX IF NOT EXISTS idx_library_albums_pos ON library_albums(position);"
        @"CREATE TABLE IF NOT EXISTS library_artists ("
        @"  position INTEGER NOT NULL, artist_id TEXT PRIMARY KEY"
        @");"
        @"CREATE INDEX IF NOT EXISTS idx_library_artists_pos ON library_artists(position);"
        @"CREATE TABLE IF NOT EXISTS library_playlists ("
        @"  position INTEGER NOT NULL, playlist_id TEXT PRIMARY KEY"
        @");"
        @"CREATE INDEX IF NOT EXISTS idx_library_playlists_pos ON library_playlists(position);"
        @"CREATE TABLE IF NOT EXISTS home_shelves ("
        @"  position INTEGER NOT NULL, shelf_id TEXT PRIMARY KEY,"
        @"  title TEXT, is_recently_played INTEGER NOT NULL, items_json BLOB NOT NULL"
        @");"
        @"CREATE INDEX IF NOT EXISTS idx_home_shelves_pos ON home_shelves(position);"
        @"CREATE TABLE IF NOT EXISTS recent_searches ("
        @"  position INTEGER NOT NULL, query TEXT PRIMARY KEY"
        @");"
        @"CREATE INDEX IF NOT EXISTS idx_recent_searches_pos ON recent_searches(position);"
        @"CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value BLOB NOT NULL);"
        @"PRAGMA user_version = %d;"
        @"COMMIT;",
        kSPSchemaVersion];
    if (sqlite3_exec(_db, ddl.UTF8String, NULL, NULL, NULL) == SQLITE_OK) return YES;
    sqlite3_exec(_db, "ROLLBACK", NULL, NULL, NULL);
    return NO;
}

- (sqlite3_stmt *)statementForSQL:(NSString *)sql {
    if (!_db) return NULL;
    NSValue *cached = _statements[sql];
    if (cached) {
        sqlite3_stmt *stmt = (sqlite3_stmt *)cached.pointerValue;
        sqlite3_reset(stmt);
        sqlite3_clear_bindings(stmt);
        return stmt;
    }
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(_db, sql.UTF8String, -1, &stmt, NULL) != SQLITE_OK) return NULL;
    _statements[sql] = [NSValue valueWithPointer:stmt];
    return stmt;
}

- (BOOL)ensureWriteTransaction {
    if (!_db || _txFailed) return NO;
    if (_txDepth > 0 && !_inTransaction) {
        if (sqlite3_exec(_db, "BEGIN IMMEDIATE", NULL, NULL, NULL) != SQLITE_OK) {
            _txFailed = YES;
            return NO;
        }
        _inTransaction = YES;
    }
    return YES;
}

- (void)transaction:(void (^)(void))block {
    if (!_db) { block(); return; }
    if (_txDepth == 0) {
        _txFailed = NO;
    }
    _txDepth++;
    block();
    _txDepth--;
    if (_txDepth == 0) {
        if (_inTransaction) {
            sqlite3_exec(_db, _txFailed ? "ROLLBACK" : "COMMIT", NULL, NULL, NULL);
            _inTransaction = NO;
        }
        _txFailed = NO;
    }
}

- (BOOL)stepWrite:(sqlite3_stmt *)stmt {
    if (!stmt) return NO;
    int rc = sqlite3_step(stmt);
    sqlite3_reset(stmt);
    if (rc != SQLITE_DONE) {
        if (_inTransaction) _txFailed = YES;
        return NO;
    }
    return YES;
}

#pragma mark - Tracks

- (void)upsertTrack:(SPTrack *)t {
    if (![self ensureWriteTransaction]) return;
    sqlite3_stmt *s = [self statementForSQL:
        @"INSERT OR REPLACE INTO tracks "
        @"(id, uri, name, album_id, album_name, artist_id, artist_name, artist_names, "
        @" duration_ms, track_number, disc_number, artwork_url, artwork_small_url, playable, unplayable_reason) "
        @"VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"];
    if (!s) return;
    BindText(s, 1, t.trackID);
    BindText(s, 2, t.uri);
    BindText(s, 3, t.name);
    BindOptText(s, 4, t.albumID);
    BindOptText(s, 5, t.albumName);
    BindOptText(s, 6, t.artistID);
    BindText(s, 7, t.artistName);
    BindText(s, 8, JoinList(t.artistNames));
    sqlite3_bind_int64(s, 9, (sqlite3_int64)t.durationMs);
    sqlite3_bind_int(s, 10, (int)t.trackNumber);
    sqlite3_bind_int(s, 11, (int)t.discNumber);
    BindOptText(s, 12, t.artworkURL);
    BindOptText(s, 13, t.artworkSmallURL);
    sqlite3_bind_int(s, 14, t.playable ? 1 : 0);
    BindOptText(s, 15, t.unplayableReason);
    [self stepWrite:s];
}

static NSString *InternString(NSMutableSet<NSString *> *pool, NSString *s) {
    if (!s) return nil;
    NSString *existing = [pool member:s];
    if (existing) return existing;
    [pool addObject:s];
    return s;
}

- (NSArray<SPTrack *> *)allTracks {
    sqlite3_stmt *s = [self statementForSQL:
        @"SELECT id, uri, name, album_id, album_name, artist_id, artist_name, artist_names, "
        @"duration_ms, track_number, disc_number, artwork_url, artwork_small_url, playable, unplayable_reason FROM tracks"];
    if (!s) return @[];
    NSMutableArray<SPTrack *> *out = [NSMutableArray new];
    NSMutableSet<NSString *> *intern = [NSMutableSet new];
    NSMutableDictionary<NSString *, NSArray<NSString *> *> *singleArtistArrays = [NSMutableDictionary new];
    while (sqlite3_step(s) == SQLITE_ROW) {
        @autoreleasepool {
            NSString *artistName = InternString(intern, ColString(s, 6) ?: @"Unknown");
            NSString *rawArtistNames = ColString(s, 7);
            NSArray<NSString *> *artistNames = nil;
            if (!rawArtistNames.length || [rawArtistNames isEqualToString:artistName]) {
                artistNames = singleArtistArrays[artistName];
                if (!artistNames) {
                    artistNames = @[ artistName ];
                    singleArtistArrays[artistName] = artistNames;
                }
            } else {
                NSArray<NSString *> *parts = SplitList(rawArtistNames);
                NSMutableArray<NSString *> *deduped = [NSMutableArray arrayWithCapacity:parts.count];
                for (NSString *p in parts) [deduped addObject:InternString(intern, p)];
                artistNames = [deduped copy];
            }
            SPTrack *t = [[SPTrack alloc] initWithTrackID:ColString(s, 0) ?: @""
                                                      uri:ColString(s, 1) ?: @""
                                                     name:ColString(s, 2) ?: @""
                                                  albumID:InternString(intern, ColString(s, 3))
                                                albumName:InternString(intern, ColString(s, 4))
                                                 artistID:InternString(intern, ColString(s, 5))
                                               artistName:artistName
                                              artistNames:artistNames
                                               durationMs:(NSInteger)sqlite3_column_int64(s, 8)
                                              trackNumber:(NSInteger)sqlite3_column_int(s, 9)
                                               discNumber:(NSInteger)sqlite3_column_int(s, 10)
                                               artworkURL:InternString(intern, ColString(s, 11))
                                          artworkSmallURL:InternString(intern, ColString(s, 12))
                                                 playable:sqlite3_column_int(s, 13) != 0
                                         unplayableReason:InternString(intern, ColString(s, 14))];
            [out addObject:t];
        }
    }
    sqlite3_reset(s);
    return out;
}

#pragma mark - Albums

- (void)upsertAlbum:(SPAlbum *)a {
    if (![self ensureWriteTransaction]) return;
    sqlite3_stmt *s = [self statementForSQL:
        @"INSERT OR REPLACE INTO albums "
        @"(id, uri, name, album_type, artist_id, artist_name, artist_names, release_date, "
        @" artwork_url, artwork_small_url, track_ids, total_track_count, total_duration_ms, details_loaded) "
        @"VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"];
    if (!s) return;
    BindText(s, 1, a.albumID);
    BindText(s, 2, a.uri);
    BindText(s, 3, a.name);
    BindOptText(s, 4, a.albumType);
    BindOptText(s, 5, a.artistID);
    BindText(s, 6, a.artistName);
    BindText(s, 7, JoinList(a.artistNames));
    BindOptText(s, 8, a.releaseDate);
    BindOptText(s, 9, a.artworkURL);
    BindOptText(s, 10, a.artworkSmallURL);
    BindText(s, 11, JoinList(a.trackIDs));
    sqlite3_bind_int64(s, 12, (sqlite3_int64)a.totalTrackCount);
    sqlite3_bind_int64(s, 13, (sqlite3_int64)a.totalDurationMs);
    sqlite3_bind_int(s, 14, a.detailsLoaded ? 1 : 0);
    [self stepWrite:s];
}

- (NSArray<SPAlbum *> *)allAlbums {
    sqlite3_stmt *s = [self statementForSQL:
        @"SELECT id, uri, name, album_type, artist_id, artist_name, artist_names, release_date, "
        @"artwork_url, artwork_small_url, track_ids, total_track_count, total_duration_ms, details_loaded FROM albums"];
    if (!s) return @[];
    NSMutableArray<SPAlbum *> *out = [NSMutableArray new];
    while (sqlite3_step(s) == SQLITE_ROW) {
        SPAlbum *a = [[SPAlbum alloc] initWithAlbumID:ColString(s, 0) ?: @""
                                                  uri:ColString(s, 1) ?: @""
                                                 name:ColString(s, 2) ?: @""
                                            albumType:ColString(s, 3)
                                             artistID:ColString(s, 4)
                                           artistName:ColString(s, 5) ?: @"Unknown"
                                          artistNames:SplitList(ColString(s, 6))
                                          releaseDate:ColString(s, 7)
                                           artworkURL:ColString(s, 8)
                                      artworkSmallURL:ColString(s, 9)
                                             trackIDs:SplitList(ColString(s, 10))
                                      totalTrackCount:(NSInteger)sqlite3_column_int64(s, 11)
                                      totalDurationMs:(NSInteger)sqlite3_column_int64(s, 12)
                                        detailsLoaded:sqlite3_column_int(s, 13) != 0];
        [out addObject:a];
    }
    sqlite3_reset(s);
    return out;
}

#pragma mark - Artists

- (void)upsertArtist:(SPArtist *)ar {
    if (![self ensureWriteTransaction]) return;
    sqlite3_stmt *s = [self statementForSQL:
        @"INSERT OR REPLACE INTO artists (id, uri, name, artwork_url, artwork_small_url, album_ids, top_track_ids, details_loaded) "
        @"VALUES (?, ?, ?, ?, ?, ?, ?, ?)"];
    if (!s) return;
    BindText(s, 1, ar.artistID);
    BindText(s, 2, ar.uri);
    BindText(s, 3, ar.name);
    BindOptText(s, 4, ar.artworkURL);
    BindOptText(s, 5, ar.artworkSmallURL);
    BindText(s, 6, JoinList(ar.albumIDs));
    BindText(s, 7, JoinList(ar.topTrackIDs));
    sqlite3_bind_int(s, 8, ar.detailsLoaded ? 1 : 0);
    [self stepWrite:s];
}

- (NSArray<SPArtist *> *)allArtists {
    sqlite3_stmt *s = [self statementForSQL:
        @"SELECT id, uri, name, artwork_url, artwork_small_url, album_ids, top_track_ids, details_loaded FROM artists"];
    if (!s) return @[];
    NSMutableArray<SPArtist *> *out = [NSMutableArray new];
    while (sqlite3_step(s) == SQLITE_ROW) {
        SPArtist *ar = [[SPArtist alloc] initWithArtistID:ColString(s, 0) ?: @""
                                                      uri:ColString(s, 1) ?: @""
                                                     name:ColString(s, 2) ?: @""
                                               artworkURL:ColString(s, 3)
                                          artworkSmallURL:ColString(s, 4)
                                                 albumIDs:SplitList(ColString(s, 5))
                                              topTrackIDs:SplitList(ColString(s, 6))
                                            detailsLoaded:sqlite3_column_int(s, 7) != 0];
        [out addObject:ar];
    }
    sqlite3_reset(s);
    return out;
}

#pragma mark - Playlists

- (void)upsertPlaylist:(SPPlaylist *)pl {
    if (![self ensureWriteTransaction]) return;
    [self transaction:^{
        sqlite3_stmt *s = [self statementForSQL:
            @"INSERT OR REPLACE INTO playlists "
            @"(id, uri, name, description, owner_id, owner_name, artwork_url, artwork_small_url, "
            @" is_public, total_track_count, details_loaded) "
            @"VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"];
        if (!s) return;
        BindText(s, 1, pl.playlistID);
        BindText(s, 2, pl.uri);
        BindText(s, 3, pl.name);
        BindOptText(s, 4, pl.playlistDescription);
        BindText(s, 5, pl.ownerID);
        BindText(s, 6, pl.ownerName);
        BindOptText(s, 7, pl.artworkURL);
        BindOptText(s, 8, pl.artworkSmallURL);
        sqlite3_bind_int(s, 9, pl.isPublic ? 1 : 0);
        sqlite3_bind_int64(s, 10, (sqlite3_int64)pl.totalTrackCount);
        sqlite3_bind_int(s, 11, pl.detailsLoaded ? 1 : 0);
        [self stepWrite:s];
        if (pl.detailsLoaded) {
            [self replacePlaylistTracks:pl.items forPlaylistID:pl.playlistID];
        }
    }];
}

- (void)replacePlaylistTracks:(NSArray<SPPlaylistItem *> *)items forPlaylistID:(NSString *)playlistID {
    if (![self ensureWriteTransaction]) return;
    [self transaction:^{
        sqlite3_stmt *del = [self statementForSQL:@"DELETE FROM playlist_tracks WHERE playlist_id = ?"];
        if (del) {
            BindText(del, 1, playlistID);
            [self stepWrite:del];
        }
        sqlite3_stmt *ins = [self statementForSQL:
            @"INSERT INTO playlist_tracks (playlist_id, position, track_id, uid, added_at) VALUES (?, ?, ?, ?, ?)"];
        if (!ins) return;
        for (NSUInteger i = 0; i < items.count; i++) {
            SPPlaylistItem *item = items[i];
            BindText(ins, 1, playlistID);
            sqlite3_bind_int64(ins, 2, (sqlite3_int64)i);
            BindText(ins, 3, item.trackID);
            BindText(ins, 4, item.uid);
            sqlite3_bind_double(ins, 5, item.addedAt);
            [self stepWrite:ins];
        }
    }];
}

- (NSArray<SPPlaylistItem *> *)playlistTracksForPlaylistID:(NSString *)playlistID {
    sqlite3_stmt *s = [self statementForSQL:
        @"SELECT track_id, uid, added_at FROM playlist_tracks WHERE playlist_id = ? ORDER BY position ASC"];
    if (!s) return @[];
    BindText(s, 1, playlistID);
    NSMutableArray<SPPlaylistItem *> *items = [NSMutableArray new];
    while (sqlite3_step(s) == SQLITE_ROW) {
        [items addObject:[[SPPlaylistItem alloc] initWithTrackID:ColString(s, 0) ?: @""
                                                             uid:ColString(s, 1) ?: @""
                                                         addedAt:sqlite3_column_double(s, 2)]];
    }
    sqlite3_reset(s);
    return items;
}

- (NSArray<SPPlaylist *> *)allPlaylists {
    sqlite3_stmt *s = [self statementForSQL:
        @"SELECT id, uri, name, description, owner_id, owner_name, artwork_url, artwork_small_url, "
        @"is_public, total_track_count, details_loaded FROM playlists"];
    if (!s) return @[];
    NSMutableArray<NSDictionary *> *rows = [NSMutableArray new];
    while (sqlite3_step(s) == SQLITE_ROW) {
        [rows addObject:@{
            @"id" : ColString(s, 0) ?: @"",
            @"uri" : ColString(s, 1) ?: @"",
            @"name" : ColString(s, 2) ?: @"",
            @"desc" : ColString(s, 3) ?: (id)NSNull.null,
            @"oid" : ColString(s, 4) ?: @"",
            @"oname" : ColString(s, 5) ?: @"",
            @"art" : ColString(s, 6) ?: (id)NSNull.null,
            @"artSmall" : ColString(s, 7) ?: (id)NSNull.null,
            @"pub" : @(sqlite3_column_int(s, 8) != 0),
            @"total" : @((NSInteger)sqlite3_column_int64(s, 9)),
            @"loaded" : @(sqlite3_column_int(s, 10) != 0),
        }];
    }
    sqlite3_reset(s);

    NSMutableArray<SPPlaylist *> *out = [NSMutableArray arrayWithCapacity:rows.count];
    for (NSDictionary *r in rows) {
        NSString *pid = r[@"id"];
        BOOL loaded = [r[@"loaded"] boolValue];
        NSArray<SPPlaylistItem *> *items = loaded ? [self playlistTracksForPlaylistID:pid] : @[];
        [out addObject:[[SPPlaylist alloc] initWithPlaylistID:pid
                                                          uri:r[@"uri"]
                                                         name:r[@"name"]
                                          playlistDescription:SPJSONString(r[@"desc"])
                                                      ownerID:r[@"oid"]
                                                    ownerName:r[@"oname"]
                                                   artworkURL:SPJSONString(r[@"art"])
                                              artworkSmallURL:SPJSONString(r[@"artSmall"])
                                                     isPublic:[r[@"pub"] boolValue]
                                                        items:items
                                              totalTrackCount:[r[@"total"] integerValue]
                                                detailsLoaded:loaded]];
    }
    return out;
}

#pragma mark - Library Lists

- (void)replaceLibraryTrackIDs:(NSArray<NSString *> *)trackIDs addedAtByID:(NSDictionary<NSString *, NSNumber *> *)addedAt {
    if (![self ensureWriteTransaction]) return;
    [self transaction:^{
        sqlite3_stmt *del = [self statementForSQL:@"DELETE FROM library_tracks"];
        if (del) [self stepWrite:del];
        sqlite3_stmt *ins = [self statementForSQL:@"INSERT OR REPLACE INTO library_tracks (position, track_id, added_at) VALUES (?, ?, ?)"];
        if (!ins) return;
        for (NSUInteger i = 0; i < trackIDs.count; i++) {
            NSString *tid = trackIDs[i];
            sqlite3_bind_int64(ins, 1, (sqlite3_int64)i);
            BindText(ins, 2, tid);
            sqlite3_bind_double(ins, 3, addedAt[tid].doubleValue);
            [self stepWrite:ins];
        }
    }];
}

- (void)appendLibraryTrackIDs:(NSArray<NSString *> *)trackIDs addedAtByID:(NSDictionary<NSString *, NSNumber *> *)addedAt {
    if (!trackIDs.count || ![self ensureWriteTransaction]) return;
    [self transaction:^{
        sqlite3_int64 nextPos = 0;
        sqlite3_stmt *maxStmt = [self statementForSQL:@"SELECT COALESCE(MAX(position), -1) FROM library_tracks"];
        if (maxStmt && sqlite3_step(maxStmt) == SQLITE_ROW) {
            nextPos = sqlite3_column_int64(maxStmt, 0) + 1;
        }
        if (maxStmt) sqlite3_reset(maxStmt);

        sqlite3_stmt *ins = [self statementForSQL:@"INSERT OR IGNORE INTO library_tracks (position, track_id, added_at) VALUES (?, ?, ?)"];
        if (!ins) return;
        for (NSString *tid in trackIDs) {
            sqlite3_bind_int64(ins, 1, nextPos++);
            BindText(ins, 2, tid);
            sqlite3_bind_double(ins, 3, addedAt[tid].doubleValue);
            [self stepWrite:ins];
        }
    }];
}

- (NSArray<NSString *> *)libraryTrackIDs {
    sqlite3_stmt *s = [self statementForSQL:@"SELECT track_id FROM library_tracks ORDER BY position ASC"];
    if (!s) return @[];
    NSMutableArray<NSString *> *out = [NSMutableArray new];
    while (sqlite3_step(s) == SQLITE_ROW) {
        NSString *tid = ColString(s, 0);
        if (tid) [out addObject:tid];
    }
    sqlite3_reset(s);
    return out;
}

- (NSDictionary<NSString *, NSNumber *> *)libraryTrackAddedAtByID {
    sqlite3_stmt *s = [self statementForSQL:@"SELECT track_id, added_at FROM library_tracks"];
    if (!s) return @{};
    NSMutableDictionary<NSString *, NSNumber *> *out = [NSMutableDictionary new];
    while (sqlite3_step(s) == SQLITE_ROW) {
        NSString *tid = ColString(s, 0);
        if (tid) out[tid] = @(sqlite3_column_double(s, 1));
    }
    sqlite3_reset(s);
    return out;
}

- (void)insertLibraryTrackID:(NSString *)trackID atPosition:(NSInteger)position addedAt:(double)addedAt {
    if (![self ensureWriteTransaction]) return;
    [self transaction:^{
        sqlite3_stmt *shift = [self statementForSQL:@"UPDATE library_tracks SET position = position + 1 WHERE position >= ?"];
        if (shift) {
            sqlite3_bind_int64(shift, 1, (sqlite3_int64)position);
            [self stepWrite:shift];
        }
        sqlite3_stmt *ins = [self statementForSQL:@"INSERT OR REPLACE INTO library_tracks (position, track_id, added_at) VALUES (?, ?, ?)"];
        if (ins) {
            sqlite3_bind_int64(ins, 1, (sqlite3_int64)position);
            BindText(ins, 2, trackID);
            sqlite3_bind_double(ins, 3, addedAt);
            [self stepWrite:ins];
        }
    }];
}

- (void)deleteLibraryTrackID:(NSString *)trackID {
    if (![self ensureWriteTransaction]) return;
    sqlite3_stmt *del = [self statementForSQL:@"DELETE FROM library_tracks WHERE track_id = ?"];
    if (del) {
        BindText(del, 1, trackID);
        [self stepWrite:del];
    }
}

- (void)replaceLibraryAlbumIDs:(NSArray<NSString *> *)albumIDs addedAtByID:(NSDictionary<NSString *, NSNumber *> *)addedAt {
    if (![self ensureWriteTransaction]) return;
    [self transaction:^{
        sqlite3_stmt *del = [self statementForSQL:@"DELETE FROM library_albums"];
        if (del) [self stepWrite:del];
        sqlite3_stmt *ins = [self statementForSQL:@"INSERT OR REPLACE INTO library_albums (position, album_id, added_at) VALUES (?, ?, ?)"];
        if (!ins) return;
        for (NSUInteger i = 0; i < albumIDs.count; i++) {
            NSString *aid = albumIDs[i];
            sqlite3_bind_int64(ins, 1, (sqlite3_int64)i);
            BindText(ins, 2, aid);
            sqlite3_bind_double(ins, 3, addedAt[aid].doubleValue);
            [self stepWrite:ins];
        }
    }];
}

- (NSArray<NSString *> *)libraryAlbumIDs {
    sqlite3_stmt *s = [self statementForSQL:@"SELECT album_id FROM library_albums ORDER BY position ASC"];
    if (!s) return @[];
    NSMutableArray<NSString *> *out = [NSMutableArray new];
    while (sqlite3_step(s) == SQLITE_ROW) {
        NSString *aid = ColString(s, 0);
        if (aid) [out addObject:aid];
    }
    sqlite3_reset(s);
    return out;
}

- (void)replaceLibraryArtistIDs:(NSArray<NSString *> *)artistIDs {
    if (![self ensureWriteTransaction]) return;
    [self transaction:^{
        sqlite3_stmt *del = [self statementForSQL:@"DELETE FROM library_artists"];
        if (del) [self stepWrite:del];
        sqlite3_stmt *ins = [self statementForSQL:@"INSERT OR REPLACE INTO library_artists (position, artist_id) VALUES (?, ?)"];
        if (!ins) return;
        for (NSUInteger i = 0; i < artistIDs.count; i++) {
            sqlite3_bind_int64(ins, 1, (sqlite3_int64)i);
            BindText(ins, 2, artistIDs[i]);
            [self stepWrite:ins];
        }
    }];
}

- (NSArray<NSString *> *)libraryArtistIDs {
    sqlite3_stmt *s = [self statementForSQL:@"SELECT artist_id FROM library_artists ORDER BY position ASC"];
    if (!s) return @[];
    NSMutableArray<NSString *> *out = [NSMutableArray new];
    while (sqlite3_step(s) == SQLITE_ROW) {
        NSString *aid = ColString(s, 0);
        if (aid) [out addObject:aid];
    }
    sqlite3_reset(s);
    return out;
}

- (void)replaceLibraryPlaylistIDs:(NSArray<NSString *> *)playlistIDs {
    if (![self ensureWriteTransaction]) return;
    [self transaction:^{
        sqlite3_stmt *del = [self statementForSQL:@"DELETE FROM library_playlists"];
        if (del) [self stepWrite:del];
        sqlite3_stmt *ins = [self statementForSQL:@"INSERT OR REPLACE INTO library_playlists (position, playlist_id) VALUES (?, ?)"];
        if (!ins) return;
        for (NSUInteger i = 0; i < playlistIDs.count; i++) {
            sqlite3_bind_int64(ins, 1, (sqlite3_int64)i);
            BindText(ins, 2, playlistIDs[i]);
            [self stepWrite:ins];
        }
    }];
}

- (NSArray<NSString *> *)libraryPlaylistIDs {
    sqlite3_stmt *s = [self statementForSQL:@"SELECT playlist_id FROM library_playlists ORDER BY position ASC"];
    if (!s) return @[];
    NSMutableArray<NSString *> *out = [NSMutableArray new];
    while (sqlite3_step(s) == SQLITE_ROW) {
        NSString *pid = ColString(s, 0);
        if (pid) [out addObject:pid];
    }
    sqlite3_reset(s);
    return out;
}

#pragma mark - Home Shelves & Recent Searches

- (void)replaceHomeShelves:(NSArray<SPHomeShelf *> *)shelves {
    if (![self ensureWriteTransaction]) return;
    [self transaction:^{
        sqlite3_stmt *del = [self statementForSQL:@"DELETE FROM home_shelves"];
        if (del) [self stepWrite:del];
        sqlite3_stmt *ins = [self statementForSQL:
            @"INSERT OR REPLACE INTO home_shelves (position, shelf_id, title, is_recently_played, items_json) "
            @"VALUES (?, ?, ?, ?, ?)"];
        if (!ins) return;
        for (NSUInteger i = 0; i < shelves.count; i++) {
            SPHomeShelf *shelf = shelves[i];
            NSMutableArray *packed = [NSMutableArray arrayWithCapacity:shelf.items.count];
            for (SPShelfItem *item in shelf.items) {
                [packed addObject:@[
                    @(item.kind),
                    item.entityID,
                    item.title,
                    item.subtitle ?: @"",
                    item.artworkURL ?: @"",
                ]];
            }
            NSData *blob = [NSJSONSerialization dataWithJSONObject:packed options:0 error:nil] ?: [NSData data];
            sqlite3_bind_int64(ins, 1, (sqlite3_int64)i);
            BindText(ins, 2, shelf.shelfID);
            BindOptText(ins, 3, shelf.title);
            sqlite3_bind_int(ins, 4, shelf.isRecentlyPlayed ? 1 : 0);
            sqlite3_bind_blob(ins, 5, blob.bytes, (int)blob.length, SQLITE_TRANSIENT);
            [self stepWrite:ins];
        }
    }];
}

- (NSArray<SPHomeShelf *> *)allHomeShelves {
    sqlite3_stmt *s = [self statementForSQL:
        @"SELECT shelf_id, title, is_recently_played, items_json FROM home_shelves ORDER BY position ASC"];
    if (!s) return @[];
    NSMutableArray<SPHomeShelf *> *out = [NSMutableArray new];
    while (sqlite3_step(s) == SQLITE_ROW) {
        NSString *sid = ColString(s, 0) ?: @"";
        NSString *title = ColString(s, 1);
        BOOL isRecent = sqlite3_column_int(s, 2) != 0;
        const void *bytes = sqlite3_column_blob(s, 3);
        int len = sqlite3_column_bytes(s, 3);
        NSData *blob = (bytes && len > 0) ? [NSData dataWithBytes:bytes length:(NSUInteger)len] : nil;
        NSArray *packed = blob ? SPJSONArray([NSJSONSerialization JSONObjectWithData:blob options:0 error:nil]) : nil;
        NSMutableArray<SPShelfItem *> *items = [NSMutableArray arrayWithCapacity:packed.count];
        for (id raw in packed) {
            NSArray *row = SPJSONArray(raw);
            if (row.count < 5) continue;
            NSString *sub = SPJSONString(row[3]);
            NSString *art = SPJSONString(row[4]);
            [items addObject:[[SPShelfItem alloc] initWithKind:(SPShelfItemKind)SPJSONInt(row[0], 0)
                                                      entityID:SPJSONString(row[1]) ?: @""
                                                         title:SPJSONString(row[2]) ?: @""
                                                      subtitle:sub.length ? sub : nil
                                                    artworkURL:art.length ? art : nil]];
        }
        [out addObject:[[SPHomeShelf alloc] initWithShelfID:sid title:title isRecentlyPlayed:isRecent items:items]];
    }
    sqlite3_reset(s);
    return out;
}

- (void)replaceRecentSearches:(NSArray<NSString *> *)queries {
    if (![self ensureWriteTransaction]) return;
    [self transaction:^{
        sqlite3_stmt *del = [self statementForSQL:@"DELETE FROM recent_searches"];
        if (del) [self stepWrite:del];
        sqlite3_stmt *ins = [self statementForSQL:@"INSERT OR REPLACE INTO recent_searches (position, query) VALUES (?, ?)"];
        if (!ins) return;
        for (NSUInteger i = 0; i < queries.count; i++) {
            sqlite3_bind_int64(ins, 1, (sqlite3_int64)i);
            BindText(ins, 2, queries[i]);
            [self stepWrite:ins];
        }
    }];
}

- (NSArray<NSString *> *)allRecentSearches {
    sqlite3_stmt *s = [self statementForSQL:@"SELECT query FROM recent_searches ORDER BY position ASC"];
    if (!s) return @[];
    NSMutableArray<NSString *> *out = [NSMutableArray new];
    while (sqlite3_step(s) == SQLITE_ROW) {
        NSString *q = ColString(s, 0);
        if (q) [out addObject:q];
    }
    sqlite3_reset(s);
    return out;
}

#pragma mark - KV

- (id)jsonForKey:(NSString *)key {
    sqlite3_stmt *s = [self statementForSQL:@"SELECT value FROM kv WHERE key = ?"];
    if (!s) return nil;
    BindText(s, 1, key);
    id result = nil;
    if (sqlite3_step(s) == SQLITE_ROW) {
        const void *bytes = sqlite3_column_blob(s, 0);
        int len = sqlite3_column_bytes(s, 0);
        if (bytes && len > 0) {
            NSData *data = [NSData dataWithBytes:bytes length:(NSUInteger)len];
            result = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingFragmentsAllowed error:nil];
        }
    }
    sqlite3_reset(s);
    return result;
}

- (void)setJSON:(id)value forKey:(NSString *)key {
    if (![self ensureWriteTransaction]) return;
    if (!value) {
        sqlite3_stmt *del = [self statementForSQL:@"DELETE FROM kv WHERE key = ?"];
        if (del) {
            BindText(del, 1, key);
            [self stepWrite:del];
        }
        return;
    }
    NSData *blob = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingFragmentsAllowed error:nil];
    if (!blob) return;
    sqlite3_stmt *ins = [self statementForSQL:@"INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)"];
    if (!ins) return;
    BindText(ins, 1, key);
    sqlite3_bind_blob(ins, 2, blob.bytes, (int)blob.length, SQLITE_TRANSIENT);
    [self stepWrite:ins];
}

@end
