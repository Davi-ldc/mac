// Owns the Files tab's page: its header, search, filters, sort, pages and rows.
#import "render/icon.h"
#import "render/strings.h"
#import "ui/files/browser.h"
#import "ui/files/controls.h"
#import "ui/files/rows.h"
#import "ui/kit/container.h"
#import "ui/kit/dialog.h"
#import "ui/kit/forms.h"
#import "ui/kit/label.h"
#import "ui/kit/popover.h"
#import "ui/present/names.h"

/// p-explorer_header--matches_view_header: 50 pt, the 18 pt black title 18 pt in, New 12 pt from
/// the right. The search field 16 pt under it (1000 pt at most, 16 pt in) and 16 pt over the
/// list (968 pt at most); the controls 5 pt down the list.
static const CGFloat kHeader = 50, kTitleX = 18, kHeaderRight = 12, kSearchTop = 16, kSearchMax = 1000, kInset = 16, kSearchBottom = 16,
                     kListMax = 968, kControlsTop = 5, kBottom = 16, kPager = 36;
/// The explorer's page and its skeleton (t8: the first, 18 more and the last).
static const NSInteger kPageSize = 50;
static const NSUInteger kSkeletonRows = 20, kPageButtons = 7;
static NSString *const kRecentlyViewed = @"last_engaged", *const kLastUpdated = @"timestamp", *const kRelevant = @"score";

@interface SNFilesBrowserDocument : NSView
@end

@implementation SNFilesBrowserDocument
- (BOOL)isFlipped { return YES; }
@end

@implementation SNFilesBrowserView {
    id<SNSource> _source;
    __weak id<SNNavigator> _navigator;
    NSString *_page, *_query;
    SNLabel *_title;
    SNButton *_newButton;
    SNFormInput *_field;
    NSScrollView *_scroll;
    SNFilesBrowserDocument *_document;
    SNExplorerSegments *_filters;
    SNExplorerPill *_types, *_advanced;
    SNExplorerSelect *_sortSelect;
    NSView *_headerLine;
    NSMutableArray<NSView *> *_items;
    NSArray<NSString *> *_fromIDs, *_inIDs;
    NSArray<SNFile *> *_files;
    NSInteger _request;
    BOOL _loading, _failed;
}

- (instancetype)initWithSource:(id<SNSource>)source navigator:(id<SNNavigator>)navigator {
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, 800, 800)])) return nil;
    _source = source;
    _navigator = navigator;
    _page = SNPageFiles;
    _query = @"";
    _filter = @"all";
    _sort = kRecentlyViewed;
    _fileTypes = SNFileTypesAll();
    _fromIDs = _inIDs = @[];
    _files = @[];
    _items = [NSMutableArray new];
    _pageNumber = _pageCount = 1;
    _title = [SNLabel labelWithText:@"" font:SNFont(SNFontSizeSubtitle, SNFontWeightBlack) color:SNColorContentPry];
    _title.lineHeight = kHeader;
    __weak SNFilesBrowserView *weakSelf = self;
    _newButton = [SNButton outlineButtonWithTitle:SNLocalized(@"files.new")];
    _newButton.icon.iconName = @"plus";
    _newButton.icon.iconSize = 16;
    _newButton.spacing = 4;
    _newButton.font = SNFont(SNFontSizeCaption, SNFontWeightBold);
    _newButton.action = ^(SNButton *button) { [weakSelf showNewMenu]; };
    _field = [[SNFormInput alloc] initWithPlaceholder:@"" icon:@"search"];
    _field.keyCommand = ^BOOL(SEL command) {
        if (command != @selector(insertNewline:)) return NO;
        SNFilesBrowserView *browser = weakSelf;
        [browser search:browser->_field.text];
        return YES;
    };
    _field.changed = ^(NSString *text) {
        SNFilesBrowserView *browser = weakSelf;
        if (!text.length && browser->_query.length) [browser search:@""];
    };
    _scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    _scroll.drawsBackground = NO;
    _scroll.hasVerticalScroller = YES;
    _scroll.scrollerStyle = NSScrollerStyleOverlay;
    _scroll.autohidesScrollers = YES;
    _document = [[SNFilesBrowserDocument alloc] initWithFrame:NSZeroRect];
    _scroll.documentView = _document;
    _filters = [[SNExplorerSegments alloc] initWithFrame:NSZeroRect];
    _filters.changed = ^(NSString *value) { weakSelf.filter = value; };
    _types = [[SNExplorerPill alloc] initWithTitle:@""];
    _types.icon = @"refine";
    _types.caret = YES;
    _types.action = ^(SNExplorerPill *pill) { [weakSelf showTypesMenu]; };
    _sortSelect = [[SNExplorerSelect alloc] initWithFrame:NSZeroRect];
    _sortSelect.changed = ^(NSString *value) { weakSelf.sort = value; };
    _advanced = [[SNExplorerPill alloc] initWithTitle:@""];
    _advanced.icon = @"filters";
    _advanced.action = ^(SNExplorerPill *pill) { [weakSelf showFiltersDialog]; };
    _headerLine = [[NSView alloc] initWithFrame:NSZeroRect];
    _headerLine.wantsLayer = YES;
    _headerLine.layer.backgroundColor = SNCGColor(SNColorOtlTer);
    for (NSView *view in @[ _title, _newButton, _headerLine, _field, _scroll ]) [self addSubview:view];
    [self updateControls];
    return self;
}

- (BOOL)isFlipped { return YES; }

- (NSArray<NSView *> *)items { return _items; }

- (void)focusSearch { [_field focus]; }

#pragma mark Page

- (BOOL)allFiles { return [_page isEqualToString:SNPageFiles]; }

/// viewTypesToDefaultFileTypes: All files' kinds, or the page's one.
- (NSArray<NSString *> *)pageTypes {
    if ([_page isEqualToString:SNPageFilesCanvases]) return @[ SNFileTypeCanvases ];
    if ([_page isEqualToString:SNPageFilesLists]) return @[ SNFileTypeLists ];
    return SNFileTypesAll();
}

- (void)showPage:(NSString *)page {
    _page = [page copy];
    NSDictionary *titles = @{SNPageFilesCanvases : @"files.nav.canvases", SNPageFilesLists : @"files.nav.lists"};
    NSDictionary *placeholders = @{SNPageFilesCanvases : @"files.search.canvases", SNPageFilesLists : @"files.search.lists"};
    _title.text = SNLocalized(titles[page] ?: @"files.nav.all");
    _field.placeholder = SNLocalized(placeholders[page] ?: @"files.search.all");
    _query = @"";
    _field.text = @"";
    _filter = @"all";
    _sort = kRecentlyViewed;
    _fileTypes = self.pageTypes;
    _fromIDs = _inIDs = @[];
    [self updateControls];
    [self showPageNumber:1];
}

- (void)search:(NSString *)query {
    _query = [[query stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] copy];
    _field.text = query;
    // Submitting a query sorts by relevance; clearing it goes back to recently viewed (or Last
    // updated where recently viewed is not offered).
    if (_query.length) _sort = kRelevant;
    else if ([_sort isEqualToString:kRelevant]) _sort = [_filter isEqualToString:@"created"] ? kLastUpdated : kRecentlyViewed;
    [self updateControls];
    [self showPageNumber:1];
}

// handleFilterSelect: Created by you keeps the types the user can create and sorts by last
// update; Shared with you searches the user's channels by relevance; All goes back to the page's
// types by recently viewed.
- (void)setFilter:(NSString *)filter {
    BOOL wasCreated = [_filter isEqualToString:@"created"];
    _filter = [filter copy];
    if ([filter isEqualToString:@"created"]) {
        NSMutableArray *types = [NSMutableArray new];
        for (NSString *type in _fileTypes)
            if ([SNFileTypesCreatedByYou() containsObject:type]) [types addObject:type];
        _fileTypes = types.count ? types : SNFileTypesCreatedByYou();
        if (!(_query.length && [_sort isEqualToString:kRelevant])) _sort = kLastUpdated;
    } else if ([filter isEqualToString:@"shared"]) {
        if ([_sort isEqualToString:kRecentlyViewed] || wasCreated) _sort = kRelevant;
    } else {
        _fileTypes = self.pageTypes;
        if (!_query.length) _sort = kRecentlyViewed;
    }
    [self updateControls];
    [self showPageNumber:1];
}

- (void)setSort:(NSString *)sort {
    _sort = [sort copy];
    [self updateControls];
    [self showPageNumber:1];
}

- (void)setFileTypes:(NSArray<NSString *> *)fileTypes {
    _fileTypes = [fileTypes copy];
    [self updateControls];
    [self showPageNumber:1];
}

- (void)setFromUserIDs:(NSArray<NSString *> *)userIDs inConversations:(NSArray<NSString *> *)conversationIDs {
    _fromIDs = [userIDs copy];
    _inIDs = [conversationIDs copy];
    [self updateControls];
    [self showPageNumber:1];
}

#pragma mark Controls

/// The Types checklist's options: the default kinds and audio, video, images, snippets and
/// emails; canvases go with documents.
static NSArray<NSArray<NSString *> *> *TypeOptions(void) {
    return @[
        @[ SNFileTypeLists, @"files.type.lists", @"lists" ], @[ SNFileTypeDocuments, @"files.type.documents", @"document" ],
        @[ SNFileTypeSpreadsheets, @"files.type.spreadsheets", @"spreadsheet" ], @[ SNFileTypePresentations, @"files.type.presentations", @"presentation" ],
        @[ SNFileTypePDFs, @"files.type.pdfs", @"pdf-file" ], @[ SNFileTypeAudio, @"files.type.audio", @"sound" ],
        @[ SNFileTypeVideos, @"files.type.videos", @"video" ], @[ SNFileTypeImages, @"files.type.images", @"image" ],
        @[ SNFileTypeSnippets, @"files.type.snippets", @"text-snippet" ], @[ SNFileTypeEmails, @"files.type.emails", @"email" ]
    ];
}

/// The options checked: canvases count as documents.
- (NSSet<NSString *> *)checkedTypes {
    NSMutableSet *checked = [NSMutableSet new];
    for (NSString *type in _fileTypes) [checked addObject:[type isEqualToString:SNFileTypeCanvases] ? SNFileTypeDocuments : type];
    return checked;
}

- (BOOL)defaultTypes { return [self.checkedTypes isEqualToSet:[NSSet setWithArray:@[ SNFileTypeLists, SNFileTypeDocuments, SNFileTypeSpreadsheets, SNFileTypePresentations, SNFileTypePDFs ]]]; }

- (void)updateControls {
    NSDictionary *alls = @{SNPageFilesCanvases : @"files.filter.allCanvases", SNPageFilesLists : @"files.filter.allLists"};
    _filters.options = @[
        [SNExplorerOption optionWithTitle:SNLocalized(alls[_page] ?: @"files.filter.all") value:@"all"],
        [SNExplorerOption optionWithTitle:SNLocalized(@"files.filter.created") value:@"created"],
        [SNExplorerOption optionWithTitle:SNLocalized(@"files.filter.shared") value:@"shared"]
    ];
    _filters.value = _filter;
    NSUInteger count = self.checkedTypes.count;
    _types.title = SNLocalizedFormat(count == 1 ? @"files.types.one" : @"files.types.other", @(count));
    _types.active = !self.defaultTypes;
    // Recently viewed is not a Created by you sort; Most relevant only while searching.
    NSMutableArray *sorts = [NSMutableArray new];
    if (_query.length) [sorts addObject:[SNExplorerOption optionWithTitle:SNLocalized(@"files.sort.relevant") value:kRelevant]];
    else if (![_filter isEqualToString:@"created"])
        [sorts addObject:[SNExplorerOption optionWithTitle:SNLocalized(@"files.sort.recent") value:[_filter isEqualToString:@"shared"] ? kRelevant : kRecentlyViewed]];
    [sorts addObject:[SNExplorerOption optionWithTitle:SNLocalized(@"files.sort.updated") value:kLastUpdated]];
    _sortSelect.options = sorts;
    _sortSelect.value = _sort;
    NSUInteger filters = (_fromIDs.count ? 1 : 0) + (_inIDs.count ? 1 : 0);
    _advanced.title = filters ? SNLocalizedFormat(filters == 1 ? @"files.filters.one" : @"files.filters.other", @(filters)) : @"";
    _advanced.tooltip = filters ? nil : SNLocalized(@"files.filters");
    _advanced.active = filters > 0;
    self.needsLayout = YES;
}

- (void)showTypesMenu {
    NSSet *checked = self.checkedTypes;
    NSMutableArray<SNMenuItem *> *items = [NSMutableArray new];
    __weak SNFilesBrowserView *weakSelf = self;
    for (NSArray<NSString *> *option in TypeOptions()) {
        NSString *type = option[0];
        SNMenuItem *item = [SNMenuItem itemWithTitle:SNLocalized(option[1]) action:^{ [weakSelf toggleType:type]; }];
        item.icon = option[2];
        item.iconSize = 16;
        item.checked = [checked containsObject:type];
        [items addObject:item];
    }
    if (!self.defaultTypes) {
        [items addObject:[SNMenuItem separator]];
        [items addObject:[SNMenuItem itemWithTitle:SNLocalized(@"files.types.reset") action:^{ weakSelf.fileTypes = SNFileTypesAll(); }]];
    }
    [[[SNMenu alloc] initWithItems:items width:240] showForRect:_types.bounds inView:_types placement:SNPlacementBelow];
}

/// handleFileTypeFilterChange: unchecking documents takes canvases with them; the menu stays
/// open for the next choice, as Slack's checklist does.
- (void)toggleType:(NSString *)type {
    NSMutableArray *types = [_fileTypes mutableCopy];
    if ([self.checkedTypes containsObject:type]) {
        [types removeObject:type];
        if ([type isEqualToString:SNFileTypeDocuments]) [types removeObject:SNFileTypeCanvases];
    } else {
        [types addObject:type];
    }
    self.fileTypes = types;
    [self showTypesMenu];
}

- (void)showNewMenu {
    NSString *domain = _source.workspace.domain;
    void (^open)(void) = ^{
        if (domain.length) [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:[NSString stringWithFormat:@"https://%@.slack.com/", domain]]];
    };
    NSMutableArray *items = [NSMutableArray new];
    if (![_page isEqualToString:SNPageFilesLists]) [items addObject:[SNMenuItem itemWithTitle:SNLocalized(@"files.new.canvas") action:open]];
    if (![_page isEqualToString:SNPageFilesCanvases]) [items addObject:[SNMenuItem itemWithTitle:SNLocalized(@"files.new.list") action:open]];
    [[[SNMenu alloc] initWithItems:items width:250] showForRect:_newButton.bounds inView:_newButton placement:SNPlacementBelow];
}

/// The Filters dialog's From and In (the advanced search modal's people and channel fields).
- (void)showFiltersDialog {
    if (!self.window) return;
    SNContainerView *fields = [[SNContainerView alloc] initWithFrame:NSMakeRect(0, 0, 472, 2 * (SNFormLabelLine + SNFormLabelGap + SNFormControlHeight) + 16)];
    SNFormSelect *from = [[SNFormSelect alloc] initWithFrame:NSZeroRect], *in = [[SNFormSelect alloc] initWithFrame:NSZeroRect];
    NSMutableArray *people = [NSMutableArray arrayWithObject:[SNFormChoice choiceWithTitle:SNLocalized(@"files.filters.anyone") value:@""]];
    for (SNUser *user in [_source usersMatching:@"" limit:200]) [people addObject:[SNFormChoice choiceWithTitle:user.visibleName value:user.userID]];
    NSMutableArray *channels = [NSMutableArray arrayWithObject:[SNFormChoice choiceWithTitle:SNLocalized(@"files.filters.anywhere") value:@""]];
    for (SNConversation *channel in _source.memberChannels) [channels addObject:[SNFormChoice choiceWithTitle:[@"#" stringByAppendingString:channel.name] value:channel.conversationID]];
    from.choices = people;
    from.value = _fromIDs.firstObject ?: @"";
    in.choices = channels;
    in.value = _inIDs.firstObject ?: @"";
    CGFloat y = 0;
    for (NSArray *field in @[ @[ @"files.filters.from", from ], @[ @"files.filters.in", in ] ]) {
        NSView *label = SNFormLabel(SNLocalized(field[0]));
        label.frame = NSMakeRect(0, y, NSWidth(fields.frame), SNFormLabelLine);
        [fields addSubview:label];
        y += SNFormLabelLine + SNFormLabelGap;
        NSView *control = field[1];
        control.frame = NSMakeRect(0, y, NSWidth(fields.frame), SNFormControlHeight);
        [fields addSubview:control];
        y += SNFormControlHeight + 16;
    }
    __weak SNFilesBrowserView *weakSelf = self;
    [SNConfirmDialog showFormInWindow:self.window title:SNLocalized(@"files.filters") accessory:fields width:520 confirmTitle:SNLocalized(@"files.filters.done") confirmed:^{
        [weakSelf setFromUserIDs:from.value.length ? @[ from.value ] : @[] inConversations:in.value.length ? @[ in.value ] : @[]];
    }];
}

#pragma mark Loading

- (SNFileSearch *)search {
    SNFileSearch *search = [SNFileSearch new];
    search.query = _query;
    search.fileTypes = _fileTypes;
    search.fromIDs = _fromIDs;
    search.conversationID = _inIDs.firstObject;
    search.creatorID = [_filter isEqualToString:@"created"] ? _source.me.userID : nil;
    search.sharedWithYou = [_filter isEqualToString:@"shared"];
    search.sort = _sort;
    search.count = kPageSize;
    search.context = @"desktop_files_browser";
    return search;
}

- (void)showPageNumber:(NSInteger)page {
    NSInteger request = ++_request;
    _loading = YES;
    _failed = NO;
    [self rebuild];
    __weak SNFilesBrowserView *weakSelf = self;
    [_source searchFiles:self.search page:page completion:^(NSArray<SNFile *> *files, NSInteger pages, NSString *error) {
        SNFilesBrowserView *browser = weakSelf;
        if (!browser || request != browser->_request) return;
        browser->_loading = NO;
        browser->_failed = !files;
        browser->_files = files ?: @[];
        browser->_pageNumber = page;
        browser->_pageCount = files ? pages : 1;
        [browser rebuild];
        [browser->_scroll.contentView scrollToPoint:NSZeroPoint];
        [browser->_scroll reflectScrolledClipView:browser->_scroll.contentView];
    }];
}

- (SNFileRowDetail)detail { return [_sort isEqualToString:kRecentlyViewed] ? SNFileRowDetailViewed : SNFileRowDetailUpdated; }

- (void)rebuild {
    for (NSView *view in _items) [view removeFromSuperview];
    [_items removeAllObjects];
    [_items addObject:_filters];
    if (self.allFiles) [_items addObject:_types];
    [_items addObjectsFromArray:@[ _sortSelect, _advanced ]];
    __weak SNFilesBrowserView *weakSelf = self;
    if (_loading) {
        for (NSUInteger i = 0; i < kSkeletonRows; i++) [_items addObject:[[SNFileSkeletonRow alloc] initWithStyle:SNFileRowList index:i last:i + 1 == kSkeletonRows]];
    } else if (_failed) {
        SNExplorerEmptyState *error = [[SNExplorerEmptyState alloc] initWithTitle:SNLocalized(@"files.error") description:nil action:SNLocalized(@"files.retry")];
        error.button.action = ^(SNButton *button) { [weakSelf showPageNumber:weakSelf.pageNumber]; };
        [_items addObject:error];
    } else if (!_files.count) {
        [_items addObject:self.emptyState];
    } else {
        for (NSUInteger i = 0; i < _files.count; i++) {
            SNFileRow *row = [[SNFileRow alloc] initWithSource:_source style:SNFileRowList];
            row.file = _files[i];
            row.detail = self.detail;
            row.first = i == 0;
            row.last = i + 1 == _files.count;
            [_items addObject:row];
        }
        if (_pageCount > 1) [self addPager];
    }
    for (NSView *view in _items) [_document addSubview:view];
    self.needsLayout = YES;
}

/// The page's empty state: nothing yet, nothing for the filters, or nothing for the search.
- (SNExplorerEmptyState *)emptyState {
    BOOL searched = _query.length > 0, filtered = _fromIDs.count || _inIDs.count || ![_filter isEqualToString:@"all"], allTypes = self.defaultTypes;
    if (!self.allFiles) {
        if ([_page isEqualToString:SNPageFilesCanvases] && !searched && !filtered)
            return [[SNExplorerEmptyState alloc] initWithTitle:SNLocalized(@"files.empty.canvases") description:SNLocalized(@"files.empty.canvases.text") action:nil];
        return [[SNExplorerEmptyState alloc] initWithTitle:SNLocalized(@"files.empty.none") description:SNLocalized(@"files.empty.none.text") action:nil];
    }
    NSString *title, *text, *action = SNLocalized(@"files.empty.clear");
    if (allTypes && !filtered && !searched) {
        title = SNLocalized(@"files.empty.yet"), text = SNLocalized(@"files.empty.yet.text"), action = nil;
    } else if (allTypes && !filtered && searched) {
        title = SNLocalized(@"files.empty.none"), text = SNLocalized(@"files.empty.yet.text"), action = nil;
    } else if (filtered || searched) {
        title = SNLocalized(@"files.empty.none"), text = SNLocalized(@"files.empty.none.text");
    } else {
        title = SNLocalized(@"files.empty.found"), text = SNLocalized(@"files.empty.found.text");
    }
    SNExplorerEmptyState *empty = [[SNExplorerEmptyState alloc] initWithTitle:title description:text action:action];
    __weak SNFilesBrowserView *weakSelf = self;
    empty.button.action = ^(SNButton *button) {
        SNFilesBrowserView *browser = weakSelf;
        if (!browser) return;
        browser->_fromIDs = browser->_inIDs = @[];
        browser->_filter = @"all";
        browser.fileTypes = SNFileTypesAll();
    };
    return empty;
}

/// Numbered pages around the current one between the previous and next arrows.
- (void)addPager {
    NSInteger first = MAX(1, MIN(_pageNumber - (NSInteger)kPageButtons / 2, _pageCount - (NSInteger)kPageButtons + 1)),
              last = MIN(_pageCount, first + (NSInteger)kPageButtons - 1);
    __weak SNFilesBrowserView *weakSelf = self;
    void (^add)(NSString *, NSString *, NSInteger, BOOL) = ^(NSString *title, NSString *icon, NSInteger target, BOOL current) {
        SNButton *button = icon ? [SNButton iconButtonNamed:icon size:kPager iconSize:16] : [SNButton outlineButtonWithTitle:title];
        if (current) {
            button.fillColor = button.hoverFillColor = SNColorBaseInvHgl1;
            button.borderColor = 0;
        }
        button.enabled = target >= 1 && target <= self->_pageCount && !current;
        button.action = ^(SNButton *clicked) { [weakSelf showPageNumber:target]; };
        button.identifier = @"pager";
        [self->_items addObject:button];
    };
    add(nil, @"caret-left", _pageNumber - 1, NO);
    for (NSInteger page = first; page <= last; page++) add(@(page).stringValue, nil, page, page == _pageNumber);
    add(nil, @"caret-right", _pageNumber + 1, NO);
}

#pragma mark Layout

- (void)layout {
    [super layout];
    CGFloat width = NSWidth(self.bounds);
    CGFloat newWidth = ceil(_newButton.fittingContentSize.width) + 24;
    _newButton.frame = NSMakeRect(width - kHeaderRight - newWidth, (kHeader - 28) / 2, newWidth, 28);
    _title.frame = NSMakeRect(kTitleX, 0, MAX(0, NSMinX(_newButton.frame) - kTitleX - 8), kHeader);
    _headerLine.frame = NSMakeRect(0, kHeader - 1, width, 1);
    CGFloat search = MIN(kSearchMax, width), y = kHeader + kSearchTop;
    _field.frame = NSMakeRect(round((width - search) / 2) + kInset, y, MAX(0, search - 2 * kInset), SNFormControlHeight);
    y += SNFormControlHeight + kSearchBottom;
    _scroll.frame = NSMakeRect(0, y, width, MAX(0, NSHeight(self.bounds) - y));
    [self layoutItems];
}

- (void)layoutItems {
    CGFloat listWidth = MIN(kListMax, MAX(0, NSWidth(self.bounds) - 2 * kInset)), x = round((NSWidth(self.bounds) - listWidth) / 2), y = kControlsTop;
    CGFloat filtersWidth = MIN(listWidth, _filters.fittingWidth);
    _filters.frame = NSMakeRect(x, y, filtersWidth, SNExplorerControlHeight);
    // The right-hand controls, 4 pt apart, right to left; wrap below _filters if they would collide.
    CGFloat advWidth = _advanced.fittingWidth, sortWidth = _sortSelect.fittingWidth, typesWidth = _types.fittingWidth;
    CGFloat rightGroupWidth = typesWidth + 4 + sortWidth + 4 + advWidth;
    CGFloat rightY = filtersWidth + 8 + rightGroupWidth > listWidth ? y + SNExplorerControlHeight + 8 : y;
    if (rightGroupWidth <= listWidth) {
        CGFloat right = x + listWidth;
        _advanced.frame = NSMakeRect(right - advWidth, rightY, advWidth, SNExplorerControlHeight);
        right = NSMinX(_advanced.frame) - 4;
        _sortSelect.frame = NSMakeRect(right - sortWidth, rightY, sortWidth, SNExplorerControlHeight);
        right = NSMinX(_sortSelect.frame) - 4;
        _types.frame = NSMakeRect(right - typesWidth, rightY, typesWidth, SNExplorerControlHeight);
    } else {
        CGFloat rx = x;
        _types.frame = NSMakeRect(rx, rightY, MIN(typesWidth, listWidth), SNExplorerControlHeight);
        rx = NSMaxX(_types.frame) + 4;
        if (rx + sortWidth > x + listWidth && rx > x) {
            rightY += SNExplorerControlHeight + 8;
            rx = x;
        }
        _sortSelect.frame = NSMakeRect(rx, rightY, MIN(sortWidth, MAX(0, x + listWidth - rx)), SNExplorerControlHeight);
        rx = NSMaxX(_sortSelect.frame) + 4;
        if (rx + advWidth > x + listWidth && rx > x) {
            rightY += SNExplorerControlHeight + 8;
            rx = x;
        }
        _advanced.frame = NSMakeRect(rx, rightY, MIN(advWidth, MAX(0, x + listWidth - rx)), SNExplorerControlHeight);
    }
    y = rightY + SNExplorerControlHeight + SNExplorerControlsBottom;
    NSMutableArray<SNButton *> *pager = [NSMutableArray new];
    for (NSView *view in _items) {
        if (view == _filters || view == _types || view == _sortSelect || view == _advanced) continue;
        if ([view.identifier isEqualToString:@"pager"]) {
            [pager addObject:(SNButton *)view];
            continue;
        }
        CGFloat height = 0;
        if ([view isKindOfClass:SNFileRow.class]) height = SNFileRowHeight(SNFileRowList, ((SNFileRow *)view).last);
        else if ([view isKindOfClass:SNFileSkeletonRow.class]) height = SNFileRowHeight(SNFileRowList, view == _items.lastObject);
        else if ([view isKindOfClass:SNExplorerEmptyState.class]) {
            // Sized at its width first: its height follows the lines it wraps to.
            view.frame = NSMakeRect(x, y, listWidth, 200);
            height = ((SNExplorerEmptyState *)view).preferredHeight;
        }
        view.frame = NSMakeRect(x, y, listWidth, height);
        y += height;
    }
    if (pager.count) {
        // .margin_top_50: the pager 4 pt under the list, its buttons 4 pt apart and centred.
        y += 4;
        CGFloat total = -4;
        for (SNButton *button in pager) total += MAX(kPager, ceil(button.fittingContentSize.width) + 20) + 4;
        CGFloat px = x + round((listWidth - total) / 2);
        for (SNButton *button in pager) {
            CGFloat buttonWidth = MAX(kPager, ceil(button.fittingContentSize.width) + 20);
            button.frame = NSMakeRect(px, y, buttonWidth, kPager);
            px += buttonWidth + 4;
        }
        y += kPager + 4;
    }
    _document.frame = NSMakeRect(0, 0, NSWidth(_scroll.frame), MAX(y + kBottom, NSHeight(_scroll.frame)));
}

@end
