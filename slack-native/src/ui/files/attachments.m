// Owns the three explorers' pages and merging them.
#import "ui/files/attachments.h"

@implementation SNAttachment

+ (instancetype)attachmentWithFile:(SNFile *)file link:(SNChannelLink *)link {
    SNAttachment *attachment = [self new];
    attachment->_file = file;
    attachment->_link = link;
    // getSortTimestamp: a file's timestamp, else when it was made; a link's share time.
    attachment->_timestamp = file ? file.timestamp ?: file.created : link.timestamp;
    return attachment;
}

@end

/// One explorer: what it loaded, its page and how many there are, the request in flight.
@interface SNAttachmentExplorer : NSObject
@property (nonatomic) NSArray *items;
@property (nonatomic) NSInteger page, pages, request;
@property (nonatomic) BOOL loading;
@end

@implementation SNAttachmentExplorer
@end

@implementation SNConversationAttachments {
    id<SNSource> _source;
    SNAttachmentExplorer *_media, *_files, *_links;
    BOOL _asked;
}

- (instancetype)initWithSource:(id<SNSource>)source conversationID:(NSString *)conversationID {
    if (!(self = [super init])) return nil;
    _source = source;
    _conversationID = [conversationID copy];
    _query = @"";
    _media = [SNAttachmentExplorer new];
    _files = [SNAttachmentExplorer new];
    _links = [SNAttachmentExplorer new];
    for (SNAttachmentExplorer *explorer in @[ _media, _files, _links ]) explorer.items = @[];
    return self;
}

- (void)setQuery:(NSString *)query {
    _query = [query copy] ?: @"";
    // Most relevant is offered only while searching.
    if (!_query.length && _sort == SNAttachmentRelevant) _sort = SNAttachmentNewest;
    [self reload];
}

- (void)setSort:(SNAttachmentSort)sort {
    _sort = sort;
    [self reload];
}

- (NSArray<SNFile *> *)media { return _media.items; }
- (NSArray<SNFile *> *)files { return _files.items; }
- (NSArray<SNChannelLink *> *)links { return _links.items; }

- (SNAttachmentExplorer *)explorer:(SNAttachmentKind)kind { return kind == SNAttachmentMedia ? _media : kind == SNAttachmentLinks ? _links : _files; }

- (BOOL)isLoading:(SNAttachmentKind)kind {
    if (kind == SNAttachmentAll) return _media.loading || _files.loading || _links.loading;
    return [self explorer:kind].loading;
}

- (BOOL)hasMore:(SNAttachmentKind)kind { return [self explorer:kind].page < [self explorer:kind].pages; }

- (void)loadIfNeeded {
    if (!_asked) [self reload];
}

- (void)reload {
    _asked = YES;
    for (SNAttachmentKind kind = SNAttachmentFiles; kind <= SNAttachmentLinks; kind++) {
        SNAttachmentExplorer *explorer = [self explorer:kind];
        explorer.items = @[];
        explorer.page = explorer.pages = 0;
        [self load:kind page:1];
    }
}

- (void)loadMore:(SNAttachmentKind)kind {
    SNAttachmentExplorer *explorer = [self explorer:kind];
    if (kind != SNAttachmentAll && !explorer.loading && [self hasMore:kind]) [self load:kind page:explorer.page + 1];
}

/// The files explorers' searches: photos and videos, or everything else but folders
/// (CHANNEL_TAB_MEDIA and CHANNEL_TAB_FILES).
- (SNFileSearch *)searchFor:(SNAttachmentKind)kind {
    SNFileSearch *search = [SNFileSearch new];
    search.query = _query;
    search.conversationID = _conversationID;
    search.context = @"desktop_files_channel_tab";
    if (kind == SNAttachmentMedia) search.fileTypes = @[ SNFileTypeImages, SNFileTypeVideos ];
    else search.excludedFileTypes = @[ SNFileTypeImages, SNFileTypeVideos, SNFileTypeFolders ];
    search.sort = _sort == SNAttachmentRelevant ? @"score" : @"timestamp";
    search.ascending = _sort == SNAttachmentOldest;
    return search;
}

- (void)load:(SNAttachmentKind)kind page:(NSInteger)page {
    SNAttachmentExplorer *explorer = [self explorer:kind];
    NSInteger request = ++explorer.request;
    explorer.loading = YES;
    __weak SNConversationAttachments *weakSelf = self;
    void (^arrived)(NSArray *, NSInteger) = ^(NSArray *items, NSInteger pages) {
        SNConversationAttachments *me = weakSelf;
        if (!me || request != explorer.request) return;
        explorer.loading = NO;
        if (items) {
            // useFormattedFiles and uniqBy(url): an item a later page repeats shows once.
            NSMutableOrderedSet *merged = [NSMutableOrderedSet orderedSetWithArray:page > 1 ? explorer.items : @[]];
            NSMutableSet *seen = [NSMutableSet new];
            for (id item in merged) [seen addObject:[item isKindOfClass:SNFile.class] ? [item fileID] : [item url]];
            for (id item in items) {
                id key = [item isKindOfClass:SNFile.class] ? [item fileID] : [item url];
                if (![seen containsObject:key]) [merged addObject:item];
                [seen addObject:key];
            }
            explorer.items = merged.array;
            explorer.page = page;
            explorer.pages = pages;
        }
        if (me.changed) me.changed();
    };
    if (kind == SNAttachmentLinks) {
        [_source searchLinksInConversation:_conversationID query:_query oldestFirst:_sort == SNAttachmentOldest page:page
                                completion:^(NSArray<SNChannelLink *> *links, NSInteger pages, NSString *error) { arrived(links, pages); }];
    } else {
        [_source searchFiles:[self searchFor:kind] page:page completion:^(NSArray<SNFile *> *files, NSInteger pages, NSString *error) { arrived(files, pages); }];
    }
}

- (NSArray<SNAttachment *> *)mixedIncludingMedia:(BOOL)media {
    NSMutableArray<SNAttachment *> *items = [NSMutableArray new];
    for (SNFile *file in media ? [_media.items arrayByAddingObjectsFromArray:_files.items] : _files.items) [items addObject:[SNAttachment attachmentWithFile:file link:nil]];
    for (SNChannelLink *link in _links.items) [items addObject:[SNAttachment attachmentWithFile:nil link:link]];
    BOOL oldest = _sort == SNAttachmentOldest;
    // A stable sort keeps each explorer's own order among equal times.
    [items sortWithOptions:NSSortStable usingComparator:^NSComparisonResult(SNAttachment *a, SNAttachment *b) {
        if (a.timestamp == b.timestamp) return NSOrderedSame;
        return (a.timestamp < b.timestamp) == oldest ? NSOrderedAscending : NSOrderedDescending;
    }];
    return items;
}

@end
