// Owns the "Files and links" tab's layout and what its controls change.
#import "render/icon.h"
#import "render/images.h"
#import "render/strings.h"
#import "ui/files/controls.h"
#import "ui/files/fileview.h"
#import "ui/files/rows.h"
#import "ui/files/tab.h"
#import "ui/kit/forms.h"

/// files_tab_view: 20 pt above the explorer; .p-explorer_search__content (1000 pt at most, 16 pt
/// in) and 16 pt under the field; .p-explorer_results__contained-result (968 pt at most, 16 pt
/// from either side); the controls 5 pt down; 16 pt under the list.
static const CGFloat kTop = 20, kSearchMax = 1000, kInset = 16, kSearchBottom = 16, kListMax = 968, kControlsTop = 5, kBottom = 16;
/// The media grid: 140 pt columns at least (minColumnWidth) and 140 pt tall cards
/// (.files_tab_view_content .p-file_card__container); the strip shows one row, a 16 pt spacer under it.
static const CGFloat kTileMin = 140, kTileHeight = 140, kTileGap = 8, kStripSpacer = 16;
/// The explorer's listLoadingFragment: the first, five more and the last skeleton row.
static const NSUInteger kSkeletonRows = 7;

/// A photo or video of the grid: its picture covering the card, a play mark on videos.
@interface SNMediaTile : SNHoverView
- (instancetype)initWithFile:(SNFile *)file source:(id<SNSource>)source;
@property (nonatomic, readonly) SNFile *file;
@end

@implementation SNMediaTile {
    id<SNSource> _source;
}

- (instancetype)initWithFile:(SNFile *)file source:(id<SNSource>)source {
    if (!(self = [super initWithFrame:NSZeroRect])) return nil;
    _file = file;
    _source = source;
    self.overlayRadius = SNRadiusXlarge;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;
    self.action = ^(SNMediaTile *tile) { SNOpenFile(tile.file, tile->_source); };
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)drawRect:(NSRect)dirtyRect {
    BOOL video = [_file.mimeType hasPrefix:@"video/"];
    NSURL *url = video ? _file.videoThumbnailURL : [_file thumbnailURLForPixels:MAX(NSWidth(self.bounds), NSHeight(self.bounds)) * 2];
    SNDrawFilePicture(url, self.bounds, SNRadiusXlarge, self);
    if (video) {
        NSRect mark = NSMakeRect(NSMidX(self.bounds) - 16, NSMidY(self.bounds) - 16, 32, 32);
        [SNColor(SNColorWithAlpha(0x000000ff, 0.6)) setFill];
        [[NSBezierPath bezierPathWithOvalInRect:mark] fill];
        SNDrawIcon(@"play-filled", 16, 0xffffffff, mark);
    }
}

@end

@interface SNConversationFilesDocument : NSView
@end

@implementation SNConversationFilesDocument
- (BOOL)isFlipped { return YES; }
@end

@implementation SNConversationFilesView {
    id<SNSource> _source;
    SNFormInput *_field;
    NSScrollView *_scroll;
    SNConversationFilesDocument *_document;
    SNExplorerSegments *_kinds;
    SNExplorerSelect *_sort;
    NSMutableArray<NSView *> *_items;
}

- (instancetype)initWithSource:(id<SNSource>)source {
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, 800, 600)])) return nil;
    _source = source;
    _items = [NSMutableArray new];
    __weak SNConversationFilesView *weakSelf = self;
    _field = [[SNFormInput alloc] initWithPlaceholder:SNLocalized(@"files.tab.search") icon:@"search"];
    _field.keyCommand = ^BOOL(SEL command) {
        if (command != @selector(insertNewline:)) return NO;
        SNConversationFilesView *view = weakSelf;
        [view search:view->_field.text];
        return YES;
    };
    // Emptying the field resets the search.
    _field.changed = ^(NSString *text) {
        SNConversationFilesView *view = weakSelf;
        if (!text.length && view.attachments.query.length) [view search:@""];
    };
    _scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    _scroll.drawsBackground = NO;
    _scroll.hasVerticalScroller = YES;
    _scroll.scrollerStyle = NSScrollerStyleOverlay;
    _scroll.autohidesScrollers = YES;
    _document = [[SNConversationFilesDocument alloc] initWithFrame:NSZeroRect];
    _scroll.documentView = _document;
    _kinds = [[SNExplorerSegments alloc] initWithFrame:NSZeroRect];
    _kinds.options = @[
        [SNExplorerOption optionWithTitle:SNLocalized(@"files.tab.all") value:@"all"], [SNExplorerOption optionWithTitle:SNLocalized(@"files.tab.files") value:@"files"],
        [SNExplorerOption optionWithTitle:SNLocalized(@"files.tab.media") value:@"media"], [SNExplorerOption optionWithTitle:SNLocalized(@"files.tab.links") value:@"links"]
    ];
    _kinds.value = @"all";
    _kinds.changed = ^(NSString *value) {
        NSDictionary *kinds = @{@"all" : @(SNAttachmentAll), @"files" : @(SNAttachmentFiles), @"media" : @(SNAttachmentMedia), @"links" : @(SNAttachmentLinks)};
        weakSelf.kind = (SNAttachmentKind)[kinds[value] integerValue];
    };
    _sort = [[SNExplorerSelect alloc] initWithFrame:NSZeroRect];
    _sort.defaultValue = @"newest";
    _sort.value = @"newest";
    _sort.changed = ^(NSString *value) {
        SNConversationFilesView *view = weakSelf;
        view.attachments.sort = [value isEqualToString:@"oldest"] ? SNAttachmentOldest : [value isEqualToString:@"relevant"] ? SNAttachmentRelevant : SNAttachmentNewest;
    };
    for (NSView *view in @[ _field, _scroll ]) [self addSubview:view];
    return self;
}

- (BOOL)isFlipped { return YES; }

- (NSArray<NSView *> *)items { return _items; }

- (void)setAttachments:(SNConversationAttachments *)attachments {
    if (attachments != _attachments) {
        _kind = SNAttachmentAll;
        _kinds.value = @"all";
        _field.text = attachments.query ?: @"";
    }
    _attachments = attachments;
    [self update];
}

- (void)setKind:(SNAttachmentKind)kind {
    _kind = kind;
    _kinds.value = @[ @"all", @"files", @"media", @"links" ][kind];
    // Most relevant is not an All choice: it falls back to Newest.
    if (kind == SNAttachmentAll && _attachments.sort == SNAttachmentRelevant) _attachments.sort = SNAttachmentNewest;
    [self update];
    [_scroll.contentView scrollToPoint:NSZeroPoint];
}

- (void)search:(NSString *)query {
    NSString *trimmed = [query stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    _field.text = query;
    // A search on one kind sorts by relevance, as submitting the query does.
    if (trimmed.length && _kind != SNAttachmentAll) _attachments.sort = SNAttachmentRelevant;
    _attachments.query = trimmed;
}

- (void)focusSearch { [_field focus]; }

/// Width of the list (.p-explorer_results__contained-result) and where it starts.
- (NSRect)listRect {
    CGFloat width = MIN(kListMax, NSWidth(self.bounds) - 2 * kInset);
    return NSMakeRect(round((NSWidth(self.bounds) - width) / 2), 0, MAX(0, width), 0);
}

- (void)layout {
    [super layout];
    CGFloat search = MIN(kSearchMax, NSWidth(self.bounds));
    _field.frame = NSMakeRect(round((NSWidth(self.bounds) - search) / 2) + kInset, kTop, MAX(0, search - 2 * kInset), SNFormControlHeight);
    CGFloat top = kTop + SNFormControlHeight + kSearchBottom;
    _scroll.frame = NSMakeRect(0, top, NSWidth(self.bounds), MAX(0, NSHeight(self.bounds) - top));
    [self layoutItems];
}

#pragma mark Building

- (void)update {
    for (NSView *view in _items) [view removeFromSuperview];
    [_items removeAllObjects];
    SNConversationAttachments *attachments = _attachments;
    if (!attachments) return;
    NSMutableArray<SNExplorerOption *> *sorts = [NSMutableArray new];
    if (attachments.query.length && _kind != SNAttachmentAll) [sorts addObject:[SNExplorerOption optionWithTitle:SNLocalized(@"files.sort.relevant") value:@"relevant"]];
    [sorts addObject:[SNExplorerOption optionWithTitle:SNLocalized(@"files.tab.newest") value:@"newest"]];
    [sorts addObject:[SNExplorerOption optionWithTitle:SNLocalized(@"files.tab.oldest") value:@"oldest"]];
    _sort.options = sorts;
    _sort.value = @[ @"newest", @"oldest", @"relevant" ][attachments.sort];
    [_items addObject:_kinds];
    [_items addObject:_sort];
    switch (_kind) {
    case SNAttachmentAll: [self addAll]; break;
    case SNAttachmentFiles: [self addFiles:attachments.files kind:SNAttachmentFiles]; break;
    case SNAttachmentMedia: [self addMedia:attachments.media expanded:YES]; break;
    case SNAttachmentLinks: [self addLinks]; break;
    }
    for (NSView *view in _items) [_document addSubview:view];
    [self layoutItems];
}

- (NSString *)emptyText:(NSString *)key {
    NSString *query = _attachments.query;
    return query.length ? SNLocalizedFormat([key stringByAppendingString:@".query"], query) : SNLocalized(key);
}

- (void)addEmpty:(NSString *)key {
    [_items addObject:[[SNExplorerEmptyState alloc] initWithTitle:[self emptyText:key] description:nil action:nil]];
}

- (void)addSkeleton {
    for (NSUInteger i = 0; i < kSkeletonRows; i++) [_items addObject:[[SNFileSkeletonRow alloc] initWithStyle:SNFileRowList index:i last:i + 1 == kSkeletonRows]];
}

- (void)addLoadMore:(SNAttachmentKind)kind {
    if (![_attachments hasMore:kind]) return;
    SNButton *more = SNExplorerLoadMoreButton();
    more.enabled = ![_attachments isLoading:kind];
    __weak SNConversationFilesView *weakSelf = self;
    more.action = ^(SNButton *button) { [weakSelf.attachments loadMore:kind]; };
    [_items addObject:more];
}

/// getChannelAttachmentsMixedRows with the media strip above them while not searching.
- (void)addAll {
    SNConversationAttachments *attachments = _attachments;
    BOOL query = attachments.query.length > 0;
    NSArray<SNAttachment *> *mixed = [attachments mixedIncludingMedia:query];
    BOOL media = !query && attachments.media.count > 0;
    if (!mixed.count && !media && [attachments isLoading:SNAttachmentAll]) return [self addSkeleton];
    if (media) {
        SNExplorerSection *section = [[SNExplorerSection alloc] initWithTitle:SNLocalized(@"files.tab.photos") action:SNLocalized(@"files.tab.seeAll")];
        __weak SNConversationFilesView *weakSelf = self;
        section.button.action = ^(SNButton *button) { weakSelf.kind = SNAttachmentMedia; };
        section.button.tooltip = nil;
        [_items addObject:section];
        [self addMedia:attachments.media expanded:NO];
    }
    if (!mixed.count) {
        if (!media) [self addEmpty:@"files.tab.empty"];
        return;
    }
    [self addMixed:mixed];
    NSMutableArray *kinds = [NSMutableArray new];
    if ([attachments hasMore:SNAttachmentFiles]) [kinds addObject:@[ SNLocalized(@"files.tab.files"), @"files", @"files" ]];
    if ([attachments hasMore:SNAttachmentMedia]) [kinds addObject:@[ SNLocalized(@"files.tab.media"), @"image", @"media" ]];
    if ([attachments hasMore:SNAttachmentLinks]) [kinds addObject:@[ SNLocalized(@"files.tab.links"), @"link", @"links" ]];
    if (kinds.count) {
        __weak SNConversationFilesView *weakSelf = self;
        [_items addObject:[[SNExplorerMoreByType alloc] initWithKinds:kinds chosen:^(NSString *value) {
                    weakSelf.kind = [value isEqualToString:@"media"] ? SNAttachmentMedia : [value isEqualToString:@"links"] ? SNAttachmentLinks : SNAttachmentFiles;
                }]];
    }
}

- (void)addMixed:(NSArray<SNAttachment *> *)items {
    for (NSUInteger i = 0; i < items.count; i++) {
        SNAttachment *item = items[i];
        BOOL first = i == 0, last = i + 1 == items.count;
        if (item.file) {
            SNFileRow *row = [[SNFileRow alloc] initWithSource:_source style:SNFileRowList];
            row.file = item.file;
            row.detail = SNFileRowDetailShared;
            row.showsActionOnHover = YES;
            row.first = first;
            row.last = last;
            [_items addObject:row];
        } else {
            SNLinkRow *row = [[SNLinkRow alloc] initWithStyle:SNFileRowList];
            row.link = item.link;
            row.first = first;
            row.last = last;
            [_items addObject:row];
        }
    }
}

- (void)addFiles:(NSArray<SNFile *> *)files kind:(SNAttachmentKind)kind {
    if (!files.count) {
        if ([_attachments isLoading:kind]) [self addSkeleton];
        else [self addEmpty:@"files.tab.empty.files"];
        return;
    }
    NSMutableArray *items = [NSMutableArray new];
    for (SNAttachment *item in [_attachments mixedIncludingMedia:NO])
        if (item.file) [items addObject:item];
    [self addMixed:items];
    [self addLoadMore:kind];
}

- (void)addMedia:(NSArray<SNFile *> *)media expanded:(BOOL)expanded {
    if (!media.count) {
        if (!expanded) return;
        if ([_attachments isLoading:SNAttachmentMedia]) [self addSkeleton];
        else [self addEmpty:@"files.tab.empty.media"];
        return;
    }
    for (SNFile *file in media) [_items addObject:[[SNMediaTile alloc] initWithFile:file source:_source]];
    if (expanded) [self addLoadMore:SNAttachmentMedia];
}

- (void)addLinks {
    NSArray<SNChannelLink *> *links = _attachments.links;
    if (!links.count) {
        if ([_attachments isLoading:SNAttachmentLinks]) [self addSkeleton];
        else [self addEmpty:@"files.tab.empty.links"];
        return;
    }
    NSMutableArray *items = [NSMutableArray new];
    for (SNAttachment *item in [_attachments mixedIncludingMedia:NO])
        if (item.link) [items addObject:item];
    [self addMixed:items];
    [self addLoadMore:SNAttachmentLinks];
}

#pragma mark Layout

- (void)layoutItems {
    NSRect list = self.listRect;
    CGFloat x = NSMinX(list), width = MAX(0, NSWidth(list)), y = kControlsTop;
    CGFloat kindsWidth = MIN(width, _kinds.fittingWidth), sortWidth = MIN(width, _sort.fittingWidth);
    _kinds.frame = NSMakeRect(x, y, kindsWidth, SNExplorerControlHeight);
    CGFloat sortY = y;
    if (kindsWidth + 8 + sortWidth > width) {
        sortY = y + SNExplorerControlHeight + 8;
        _sort.frame = NSMakeRect(x, sortY, sortWidth, SNExplorerControlHeight);
    } else {
        _sort.frame = NSMakeRect(NSMaxX(list) - sortWidth, sortY, sortWidth, SNExplorerControlHeight);
    }
    y = sortY + SNExplorerControlHeight + SNExplorerControlsBottom;
    // The media grid: as many 140 pt columns as fit, one row in the strip.
    NSInteger columns = MAX(1, (NSInteger)floor((width + kTileGap) / (kTileMin + kTileGap)));
    CGFloat tile = (width - kTileGap * (columns - 1)) / columns;
    NSInteger column = 0;
    BOOL strip = _kind == SNAttachmentAll;
    for (NSView *view in _items) {
        if (view == _kinds || view == _sort) continue;
        if ([view isKindOfClass:SNMediaTile.class]) {
            if (strip && column >= columns) {
                view.hidden = YES;
                continue;
            }
            view.hidden = NO;
            NSInteger index = column % columns;
            if (index == 0 && column > 0) y += kTileHeight + kTileGap;
            view.frame = NSMakeRect(x + index * (tile + kTileGap), y, tile, kTileHeight);
            column++;
            continue;
        }
        if (column) {
            y += kTileHeight + (strip ? kStripSpacer : kTileGap);
            column = 0;
        }
        if ([view isKindOfClass:SNFileRow.class]) {
            SNFileRow *row = (SNFileRow *)view;
            view.frame = NSMakeRect(x, y, width, SNFileRowHeight(SNFileRowList, row.last));
        } else if ([view isKindOfClass:SNLinkRow.class]) {
            SNLinkRow *row = (SNLinkRow *)view;
            view.frame = NSMakeRect(x, y, width, SNLinkRowHeight(SNFileRowList, row.last));
        } else if ([view isKindOfClass:SNFileSkeletonRow.class]) {
            BOOL last = view == _items.lastObject;
            view.frame = NSMakeRect(x, y, width, SNFileRowHeight(SNFileRowList, last));
        } else if ([view isKindOfClass:SNExplorerSection.class]) {
            // p-explorer_section--focus-ring-room: 8 pt in on either side.
            view.frame = NSMakeRect(x + 8, y, width - 16, 16 + 22 + 8);
        } else if ([view isKindOfClass:SNExplorerEmptyState.class]) {
            // Sized at its width first: its height follows the lines it wraps to.
            view.frame = NSMakeRect(x, y, width, 200);
            view.frame = NSMakeRect(x, y, width, ((SNExplorerEmptyState *)view).preferredHeight);
        } else if ([view isKindOfClass:SNExplorerMoreByType.class]) {
            view.frame = NSMakeRect(x, y, width, ((SNExplorerMoreByType *)view).preferredHeight);
        } else if ([view isKindOfClass:SNButton.class]) {
            // ExplorerLoadMoreButton, centred 4 pt under the list.
            CGFloat buttonWidth = MAX(80, ceil(((SNButton *)view).fittingContentSize.width) + 32);
            view.frame = NSMakeRect(x + round((width - buttonWidth) / 2), y + 4, buttonWidth, 36);
            y += 4;
        }
        y += NSHeight(view.frame);
    }
    if (column) y += kTileHeight;
    _document.frame = NSMakeRect(0, 0, NSWidth(_scroll.frame), MAX(y + kBottom, NSHeight(_scroll.frame)));
}

@end
