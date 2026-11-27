// Owns the SQLite file: schema and its version, statements, transactions and JSON (de)serialisation.
#import <sqlite3.h>

#import "store/database.h"

// Linked here, beside the only code that uses it, so the shared Makefile needs no change.
__asm__(".linker_option \"-lsqlite3\"");

/// The tables' layout. Version 0 is a new file or one from before versions were kept (the same
/// tables); any other version is rebuilt.
static const int SNSchemaVersion = 1;

static void RemoveFiles(NSURL *url) {
    for (NSString *suffix in @[ @"", @"-wal", @"-shm" ]) [NSFileManager.defaultManager removeItemAtPath:[url.path stringByAppendingString:suffix] error:nil];
}

@implementation SNDatabase {
    sqlite3 *_db;
    NSURL *_url;
    NSMutableDictionary<NSString *, NSValue *> *_statements;
    NSInteger _depth;
    /// A SQLite transaction was lazily started by the first write inside -transaction:.
    BOOL _inTransaction;
    /// A statement of the open transaction failed: the rest of it is skipped and it rolls back.
    BOOL _failed;
}

+ (NSURL *)folder {
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    return [support URLByAppendingPathComponent:@"Slack Native" isDirectory:YES];
}

+ (NSURL *)URLForWorkspace:(NSString *)workspaceID {
    return [self.folder URLByAppendingPathComponent:[workspaceID stringByAppendingPathExtension:@"sqlite"]];
}

+ (instancetype)databaseAtURL:(NSURL *)url {
    NSURL *folder = url.URLByDeletingLastPathComponent;
    [NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:nil];
    // The folder holds caches of what Slack keeps (and the WAL files come and go), so the whole
    // folder stays out of Time Machine.
    [folder setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
    SNDatabase *database = [self openAtURL:url];
    if (database) return database;
    // Unreadable, damaged or of another version: being a cache, it starts over.
    RemoveFiles(url);
    return [self openAtURL:url];
}

+ (instancetype)openAtURL:(NSURL *)url {
    sqlite3 *db = NULL;
    if (sqlite3_open_v2(url.fileSystemRepresentation, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, NULL) != SQLITE_OK) {
        sqlite3_close(db);
        return nil;
    }
    // Another connection to the file (a check, a second build) is waited for, not failed on.
    sqlite3_busy_timeout(db, 2000);
    SNDatabase *database = [self new];
    database->_db = db;
    database->_url = url;
    database->_statements = [NSMutableDictionary new];
    // A database that is not returned closes its handle in -dealloc.
    return [database prepareSchema] ? database : nil;
}

- (int)userVersion {
    sqlite3_stmt *statement = NULL;
    int version = -1;
    if (sqlite3_prepare_v2(_db, "PRAGMA user_version", -1, &statement, NULL) == SQLITE_OK && sqlite3_step(statement) == SQLITE_ROW)
        version = sqlite3_column_int(statement, 0);
    sqlite3_finalize(statement);
    return version;
}

- (BOOL)prepareSchema {
    // NORMAL in WAL mode syncs only at checkpoints: a lost last transaction after a power cut
    // costs a cache refresh, never corruption. A file that is not a database fails here.
    if (sqlite3_exec(_db, "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;", NULL, NULL, NULL) != SQLITE_OK) return NO;
    int version = [self userVersion];
    if (version == SNSchemaVersion) return YES;
    if (version != 0) return NO;
    NSString *schema = [NSString stringWithFormat:@"BEGIN;"
                                                  @"CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value BLOB NOT NULL);"
                                                  @"CREATE TABLE IF NOT EXISTS users (id TEXT PRIMARY KEY, json BLOB NOT NULL);"
                                                  @"CREATE TABLE IF NOT EXISTS conversations (id TEXT PRIMARY KEY, json BLOB NOT NULL);"
                                                  @"CREATE TABLE IF NOT EXISTS messages (conversation TEXT NOT NULL, thread TEXT NOT NULL, ts TEXT NOT NULL,"
                                                  @" json BLOB NOT NULL, PRIMARY KEY (conversation, thread, ts)) WITHOUT ROWID;"
                                                  @"PRAGMA user_version = %d; COMMIT;",
                                                  SNSchemaVersion];
    if (sqlite3_exec(_db, schema.UTF8String, NULL, NULL, NULL) == SQLITE_OK) return YES;
    sqlite3_exec(_db, "ROLLBACK", NULL, NULL, NULL);
    return NO;
}

- (void)closeHandle {
    for (NSValue *statement in _statements.allValues) sqlite3_finalize(statement.pointerValue);
    [_statements removeAllObjects];
    sqlite3_close(_db);
    _db = NULL;
}

- (void)dealloc { [self closeHandle]; }

- (void)deleteFile {
    [self closeHandle];
    RemoveFiles(_url);
}

/// Whether `result` is a success. A failure fails the open transaction; a damaged file is closed
/// and deleted, so the session goes on from memory and the next launch starts a new cache.
- (BOOL)check:(int)result {
    if (result == SQLITE_OK || result == SQLITE_ROW || result == SQLITE_DONE) return YES;
    if (_depth) _failed = YES;
    int primary = result & 0xff;
    if (primary == SQLITE_CORRUPT || primary == SQLITE_NOTADB) {
        [self closeHandle];
        RemoveFiles(_url);
    }
    return NO;
}

- (void)transaction:(void (^)(void))block {
    if (_depth++ == 0) {
        _failed = NO;
        _inTransaction = NO;
    }
    block();
    if (--_depth > 0 || !_db) return;
    if (_inTransaction) {
        _inTransaction = NO;
        // A change is kept whole or not at all, and the transaction never stays open.
        if (_failed || ![self check:sqlite3_exec(_db, "COMMIT", NULL, NULL, NULL)]) sqlite3_exec(_db, "ROLLBACK", NULL, NULL, NULL);
    }
    _failed = NO;
}

/// Prepared once per SQL text; bound with NSString, NSData or NSNumber arguments in order. NULL
/// when the database is gone or the statement could not be prepared or bound.
- (sqlite3_stmt *)statement:(NSString *)sql arguments:(NSArray *)arguments {
    if (!_db) return NULL;
    sqlite3_stmt *statement = _statements[sql].pointerValue;
    if (!statement) {
        if (![self check:sqlite3_prepare_v3(_db, sql.UTF8String, -1, SQLITE_PREPARE_PERSISTENT, &statement, NULL)]) return NULL;
        _statements[sql] = [NSValue valueWithPointer:statement];
    }
    sqlite3_reset(statement);
    sqlite3_clear_bindings(statement);
    for (NSUInteger i = 0; i < arguments.count; i++) {
        id argument = arguments[i];
        int index = (int)i + 1, result = SQLITE_MISMATCH;
        if ([argument isKindOfClass:NSString.class]) result = sqlite3_bind_text(statement, index, [argument UTF8String], -1, SQLITE_TRANSIENT);
        else if ([argument isKindOfClass:NSData.class]) result = sqlite3_bind_blob(statement, index, [argument bytes], (int)[argument length], SQLITE_TRANSIENT);
        else if ([argument isKindOfClass:NSNumber.class]) result = sqlite3_bind_int64(statement, index, [argument longLongValue]);
        if (![self check:result]) return NULL;
    }
    return statement;
}

/// Rows changed, or -1 when it failed (or a failed transaction skipped it).
- (int)run:(NSString *)sql arguments:(NSArray *)arguments {
    if (_depth && _failed) return -1;
    if (_depth && !_inTransaction) {
        if (!_db || ![self check:sqlite3_exec(_db, "BEGIN", NULL, NULL, NULL)]) return -1;
        _inTransaction = YES;
    }
    sqlite3_stmt *statement = [self statement:sql arguments:arguments];
    if (!statement) return -1;
    BOOL ok = [self check:sqlite3_step(statement)];
    // Reset at once: a statement left mid-step would hold its read snapshot open.
    if (_db) sqlite3_reset(statement);
    return ok && _db ? sqlite3_changes(_db) : -1;
}

/// Calls `row` for each row (stopping when it returns NO), then resets the statement.
- (void)rows:(NSString *)sql arguments:(NSArray *)arguments each:(BOOL (^)(sqlite3_stmt *statement))row {
    sqlite3_stmt *statement = [self statement:sql arguments:arguments];
    if (!statement) return;
    int result;
    while ((result = sqlite3_step(statement)) == SQLITE_ROW)
        if (!row(statement)) break;
    if (result != SQLITE_ROW) [self check:result];
    if (_db) sqlite3_reset(statement);
}

static id DecodeColumn(sqlite3_stmt *statement, int column) {
    NSData *data = [NSData dataWithBytesNoCopy:(void *)sqlite3_column_blob(statement, column) length:(NSUInteger)sqlite3_column_bytes(statement, column) freeWhenDone:NO];
    return data.length ? [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingFragmentsAllowed error:nil] : nil;
}

/// The JSON in column `column` of each row.
- (NSArray *)objects:(NSString *)sql arguments:(NSArray *)arguments column:(int)column {
    NSMutableArray *objects = [NSMutableArray new];
    [self rows:sql arguments:arguments each:^BOOL(sqlite3_stmt *statement) {
        id object = DecodeColumn(statement, column);
        if (object) [objects addObject:object];
        return YES;
    }];
    return objects;
}

static NSData *Encode(id object) { return [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingFragmentsAllowed error:nil]; }

- (id)jsonForKey:(NSString *)key { return [self objects:@"SELECT value FROM kv WHERE key = ?" arguments:@[ key ] column:0].firstObject; }

- (void)setJSON:(id)value forKey:(NSString *)key {
    NSData *data = value ? Encode(value) : nil;
    if (data) [self run:@"INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)" arguments:@[ key, data ]];
    else [self run:@"DELETE FROM kv WHERE key = ?" arguments:@[ key ]];
}

- (NSDictionary<NSString *, id> *)jsonWithKeyPrefix:(NSString *)prefix {
    NSMutableDictionary *values = [NSMutableDictionary new];
    // Keys between the prefix and the prefix followed by the highest character share it.
    [self rows:@"SELECT key, value FROM kv WHERE key >= ? AND key < ?" arguments:@[ prefix, [prefix stringByAppendingString:@"\U0010FFFF"] ]
          each:^BOOL(sqlite3_stmt *statement) {
              const char *key = (const char *)sqlite3_column_text(statement, 0);
              id value = DecodeColumn(statement, 1);
              if (key && value) values[@(key)] = value;
              return YES;
          }];
    return values;
}

/// Only the two object tables exist; anything else would be SQL from a caller's typo.
static NSString *Table(NSString *table) { return [table isEqualToString:@"users"] ? @"users" : @"conversations"; }

- (NSArray<NSDictionary *> *)allObjectsInTable:(NSString *)table {
    return [self objects:[NSString stringWithFormat:@"SELECT json FROM %@", Table(table)] arguments:@[] column:0];
}

- (NSDictionary *)objectWithID:(NSString *)objectID inTable:(NSString *)table {
    return [self objects:[NSString stringWithFormat:@"SELECT json FROM %@ WHERE id = ?", Table(table)] arguments:@[ objectID ] column:0].firstObject;
}

- (NSDictionary *)userWithHandle:(NSString *)handle {
    if (!handle.length) return nil;
    // Substring pre-filter skips rows without parsing JSON when handle has no escape characters.
    if ([handle rangeOfString:@"\""].location == NSNotFound && [handle rangeOfString:@"\\"].location == NSNotFound) {
        NSString *needle = [NSString stringWithFormat:@"\"%@\"", handle];
        return [self objects:@"SELECT json FROM users WHERE instr(CAST(json AS TEXT), ?) > 0 AND json_extract(CAST(json AS TEXT), '$.name') = ? LIMIT 1"
                   arguments:@[ needle, handle ]
                      column:0].firstObject;
    }
    return [self objects:@"SELECT json FROM users WHERE json_extract(CAST(json AS TEXT), '$.name') = ? LIMIT 1" arguments:@[ handle ] column:0].firstObject;
}

- (void)putObject:(NSDictionary *)json withID:(NSString *)objectID inTable:(NSString *)table {
    NSData *data = Encode(json);
    if (data) [self run:[NSString stringWithFormat:@"INSERT OR REPLACE INTO %@ (id, json) VALUES (?, ?)", Table(table)] arguments:@[ objectID, data ]];
}

// ts strings have ten digits of seconds until 2286, so they sort as text.
- (NSArray<NSDictionary *> *)messagesInConversation:(NSString *)conversationID thread:(NSString *)threadTS before:(NSString *)ts limit:(NSInteger)limit {
    NSArray *rows = ts ? [self objects:@"SELECT json FROM messages WHERE conversation = ? AND thread = ? AND ts < ? ORDER BY ts DESC LIMIT ?"
                             arguments:@[ conversationID, threadTS ?: @"", ts, @(limit) ]
                                column:0]
                       : [self objects:@"SELECT json FROM messages WHERE conversation = ? AND thread = ? ORDER BY ts DESC LIMIT ?"
                             arguments:@[ conversationID, threadTS ?: @"", @(limit) ]
                                column:0];
    return rows.reverseObjectEnumerator.allObjects;
}

- (NSDictionary *)messageWithTS:(NSString *)ts inConversation:(NSString *)conversationID thread:(NSString *)threadTS {
    return [self objects:@"SELECT json FROM messages WHERE conversation = ? AND thread = ? AND ts = ?" arguments:@[ conversationID, threadTS ?: @"", ts ] column:0].firstObject;
}

- (void)putMessage:(NSDictionary *)json ts:(NSString *)ts inConversation:(NSString *)conversationID thread:(NSString *)threadTS {
    NSData *data = Encode(json);
    if (data) [self run:@"INSERT OR REPLACE INTO messages (conversation, thread, ts, json) VALUES (?, ?, ?, ?)" arguments:@[ conversationID, threadTS ?: @"", ts, data ]];
}

- (void)deleteMessageWithTS:(NSString *)ts inConversation:(NSString *)conversationID thread:(NSString *)threadTS {
    [self run:@"DELETE FROM messages WHERE conversation = ? AND thread = ? AND ts = ?" arguments:@[ conversationID, threadTS ?: @"", ts ]];
}

- (void)deleteMessagesInConversation:(NSString *)conversationID thread:(NSString *)threadTS from:(NSString *)ts {
    [self run:@"DELETE FROM messages WHERE conversation = ? AND thread = ? AND ts >= ?" arguments:@[ conversationID, threadTS ?: @"", ts ?: @"" ]];
}

- (BOOL)trimConversation:(NSString *)conversationID keeping:(NSInteger)count {
    __block NSString *oldestKept = nil;
    [self rows:@"SELECT ts FROM messages WHERE conversation = ? AND thread = '' ORDER BY ts DESC LIMIT 1 OFFSET ?" arguments:@[ conversationID, @(MAX(count, 1) - 1) ]
          each:^BOOL(sqlite3_stmt *statement) {
              const char *ts = (const char *)sqlite3_column_text(statement, 0);
              oldestKept = ts ? @(ts) : nil;
              return NO;
          }];
    if (!oldestKept) return NO;
    int deleted = [self run:@"DELETE FROM messages WHERE conversation = ? AND thread = '' AND ts < ?" arguments:@[ conversationID, oldestKept ]];
    // A thread is keyed by its parent's ts: threads of deleted parents go with them.
    [self run:@"DELETE FROM messages WHERE conversation = ? AND thread != '' AND thread < ?" arguments:@[ conversationID, oldestKept ]];
    return deleted > 0;
}

@end
