// Renders every conversation and thread of a signed-in workspace's cache whole, to see real
// messages as the app shows them: SN_RENDER_CACHE=<the workspace's .sqlite> make snapshot. The
// cache is copied first (the running app keeps writing it); copy and renders hold company
// content, so both stay in design/_diff/cache. Without the variable nothing runs.
#import <sqlite3.h>

#import "render/strings.h"
#import "snapshot.h"
#import "store/database.h"
#import "store/store.h"
#import "test.h"
#import "ui/channel/list.h"

/// The cache's threads as SNThreadKey()s.
static NSArray<NSString *> *CachedThreadKeys(NSURL *url) {
    NSMutableArray *keys = [NSMutableArray new];
    sqlite3 *db = NULL;
    sqlite3_stmt *statement = NULL;
    if (sqlite3_open_v2(url.fileSystemRepresentation, &db, SQLITE_OPEN_READONLY, NULL) == SQLITE_OK &&
        sqlite3_prepare_v2(db, "SELECT DISTINCT conversation, thread FROM messages WHERE thread != ''", -1, &statement, NULL) == SQLITE_OK)
        while (sqlite3_step(statement) == SQLITE_ROW)
            [keys addObject:SNThreadKey(@((const char *)sqlite3_column_text(statement, 0)), @((const char *)sqlite3_column_text(statement, 1)))];
    sqlite3_finalize(statement);
    sqlite3_close(db);
    return keys;
}

static void RenderList(SNStore *store, NSString *conversationID, NSString *threadTS, NSURL *folder) {
    CGFloat width = threadTS ? 393 : 840;
    SNMessageListView *list = [[SNMessageListView alloc] initWithSource:store mode:threadTS ? SNMessageListThread : SNMessageListChannel];
    NSArray<SNMessage *> *messages = threadTS ? [store threadInConversation:conversationID ts:threadTS] : [store messagesInConversation:conversationID];
    NSView *background = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, 400)];
    background.wantsLayer = YES;
    background.layer.backgroundColor = SNCGColor(SNColorBasePry);
    list.frame = background.bounds;
    list.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [background addSubview:list];
    [list showMessages:messages inConversation:conversationID threadTS:threadTS lastRead:nil];
    [list layoutSubtreeIfNeeded];
    NSSize size = NSMakeSize(width, MAX(100, ceil(list.contentHeight)));
    SNRenderView(background, size);
    [list scrollToOffset:0];
    SNPixels *pixels = SNRenderView(background, size);
    NSString *name = threadTS ? [NSString stringWithFormat:@"%@-%@", conversationID, threadTS] : conversationID;
    SNExpect([pixels writePNG:[folder URLByAppendingPathComponent:[name stringByAppendingPathExtension:@"png"]]], name.UTF8String);
}

SN_SNAPSHOT(ChannelRendersACachedWorkspace) {
    const char *path = getenv("SN_RENDER_CACHE");
    if (!path) return;
    NSFileManager *files = NSFileManager.defaultManager;
    NSURL *folder = [SNRepository() URLByAppendingPathComponent:@"design/_diff/cache" isDirectory:YES];
    [files removeItemAtURL:folder error:nil];
    [files createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *copy = [folder URLByAppendingPathComponent:@"workspace.sqlite"];
    for (NSString *suffix in @[ @"", @"-wal" ])
        [files copyItemAtPath:[@(path) stringByAppendingString:suffix] toPath:[copy.path stringByAppendingString:suffix] error:nil];
    SNStore *store = [[SNStore alloc] initWithDatabase:[SNDatabase databaseAtURL:copy] api:nil];
    SNExpect(store.hasState, "the cache opens");
    if (!store.hasState) return;
    NSString *language = SNLanguage();
    SNSetLanguage(store.me.locale ?: store.preferences[@"locale"] ?: @"en");
    for (NSString *conversationID in store.cachedConversationIDs) RenderList(store, conversationID, nil, folder);
    for (NSString *key in CachedThreadKeys(copy)) {
        NSRange slash = [key rangeOfString:@"/"];
        RenderList(store, [key substringToIndex:slash.location], [key substringFromIndex:NSMaxRange(slash)], folder);
    }
    SNSetLanguage(language);
}
