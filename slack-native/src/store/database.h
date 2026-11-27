// The workspace's cache on disk: one SQLite file (WAL) holding the JSON the store decodes, so a
// launch draws the last state before any network. Used from the main thread only; writes made
// inside -transaction: commit together or, when one fails, not at all. A file that cannot be read
// or holds another schema version is deleted and started over; one found damaged while running is
// dropped (the store goes on from memory).
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SNDatabase : NSObject
/// Opens or creates the file; nil when it cannot be opened (the caller starts without a cache).
/// Its folder is kept out of Time Machine.
+ (nullable instancetype)databaseAtURL:(NSURL *)url;
/// ~/Library/Application Support/Slack Native, the app's folder for caches and its instance lock.
@property (class, nonatomic, readonly) NSURL *folder;
/// <folder>/<workspace ID>.sqlite
+ (NSURL *)URLForWorkspace:(NSString *)workspaceID;
- (void)transaction:(void (^)(void))block;
/// Closes the file and deletes it (signing out); what uses the database goes on from memory.
- (void)deleteFile;

/// Small JSON values: the workspace, prefs, sections, emoji, history flags, drafts.
- (nullable id)jsonForKey:(NSString *)key;
/// nil deletes.
- (void)setJSON:(nullable id)value forKey:(NSString *)key;
/// Every value whose key starts with `prefix`, by key.
- (NSDictionary<NSString *, id> *)jsonWithKeyPrefix:(NSString *)prefix;

/// Users and conversations by ID.
- (NSArray<NSDictionary *> *)allObjectsInTable:(NSString *)table;
- (nullable NSDictionary *)objectWithID:(NSString *)objectID inTable:(NSString *)table;
/// Looks up one user row by handle ("name") without decoding the rest of the users table.
- (nullable NSDictionary *)userWithHandle:(NSString *)handle;
- (void)putObject:(NSDictionary *)json withID:(NSString *)objectID inTable:(NSString *)table;

/// Messages of a conversation's history (`thread` nil) or of a thread (parent included), oldest
/// first: the newest `limit` before `ts` (nil: the newest of all).
- (NSArray<NSDictionary *> *)messagesInConversation:(NSString *)conversationID
                                             thread:(nullable NSString *)threadTS
                                             before:(nullable NSString *)ts
                                              limit:(NSInteger)limit;
- (nullable NSDictionary *)messageWithTS:(NSString *)ts inConversation:(NSString *)conversationID thread:(nullable NSString *)threadTS;
- (void)putMessage:(NSDictionary *)json ts:(NSString *)ts inConversation:(NSString *)conversationID thread:(nullable NSString *)threadTS;
- (void)deleteMessageWithTS:(NSString *)ts inConversation:(NSString *)conversationID thread:(nullable NSString *)threadTS;
/// Deletes the history's (or thread's) messages from `ts` on (inclusive); nil deletes them all.
- (void)deleteMessagesInConversation:(NSString *)conversationID thread:(nullable NSString *)threadTS from:(nullable NSString *)ts;
/// Keeps the newest `count` messages of the conversation's history and the threads of those it
/// keeps; YES when older ones were deleted.
- (BOOL)trimConversation:(NSString *)conversationID keeping:(NSInteger)count;
@end

NS_ASSUME_NONNULL_END
