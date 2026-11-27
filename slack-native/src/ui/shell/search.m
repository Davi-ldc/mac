// Owns the search modal: its rows, keyboard, pointer and what choosing a row opens.
#import "render/icon.h"
#import "render/strings.h"
#import "ui/kit/avatar.h"
#import "ui/kit/button.h"
#import "ui/kit/hoverview.h"
#import "ui/kit/label.h"
#import "ui/kit/popover.h"
#import "ui/present/names.h"
#import "ui/shell/search.h"

/// Measured on the capture (points inside the ring): the query row 48.5 tall over a 1 pt line, the
/// AI note 600 wide 20 in from the sides and 12 below the line, the rows' heading centred 29
/// below the note, 40 pt rows from 48 below it, and 12 pt above the footer's line and 44 pt row.
static const CGFloat kInputHeight = 48.5, kNoteGap = 12, kNoteHeight = 71, kNoteInset = 20, kHeadingHeight = 48, kRow = 40,
                     kFooterGap = 12, kFooterHeight = 44, kInset = 16, kRightInset = 20, kRadius = 8;
/// The modal is 35 pt wider than the field on each side, inside its 1 pt ring, 4 pt from the top.
static const CGFloat kOverhang = 35, kTop = 4;
/// Row contents: a 24 pt picture or glyph 16 pt in, the text at 52.
static const CGFloat kIcon = 24, kTextX = 52, kGlyphX = 21.5, kInputTextX = 56;
static const NSUInteger kRecentCount = 5, kSuggestionCount = 4;

typedef NS_ENUM(NSInteger, SNSearchRowKind) {
    SNSearchRowConversation,
    SNSearchRowUser,
    SNSearchRowQuery,
    SNSearchRowMessage,
};

@interface SNSearchRow : NSObject
@property (nonatomic) SNSearchRowKind kind;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy, nullable) NSString *detail, *icon, *identifier;
@property (nonatomic, nullable) NSURL *avatarURL;
@property (nonatomic, nullable) SNMessage *message;
@end

@implementation SNSearchRow
@end

@interface SNSearchModal () <NSTextFieldDelegate, SNCursorProvider>
@end

@implementation SNSearchModal {
    id<SNSource> _source;
    __weak id<SNNavigator> _navigator;
    NSArray<NSString *> *_recent;
    NSArray<SNSearchRow *> *_rows;
    NSString *_heading;
    NSMutableArray<SNAvatarView *> *_avatars;
    SNPopover *_popover;
    SNIconLayer *_magnifier;
    SNButton *_noteClose;
    NSTrackingArea *_tracking;
    NSUInteger _searches;
}

static __weak SNSearchModal *current;
/// The AI note stays closed for the session once its X is clicked.
static BOOL noteClosed;
/// What messages were last searched for, which /search without text brings back.
static NSString *lastQuery;

+ (SNSearchModal *)current { return current; }

+ (instancetype)showOverField:(NSView *)field source:(id<SNSource>)source navigator:(id<SNNavigator>)navigator recent:(NSArray<NSString *> *)recent {
    SNSearchModal *modal = [[self alloc] initWithFrame:NSMakeRect(0, 0, field.frame.size.width + 2 * kOverhang, 400)];
    modal->_source = source;
    modal->_navigator = navigator;
    modal->_recent = recent;
    [modal showRecent];
    SNPanelView *panel = [[SNPanelView alloc] initWithFill:SNLegacyPrimaryBackground radius:kRadius shadow:SNMenuShadow];
    panel.frame = modal.frame;
    modal.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [panel.contentView addSubview:modal];
    NSView *content = field.window.contentView;
    NSRect fieldRect = [content convertRect:field.bounds fromView:field];
    CGFloat top = content.isFlipped ? kTop : NSHeight(content.bounds) - kTop;
    NSRect target = NSMakeRect(NSMinX(fieldRect) - kOverhang, content.isFlipped ? top - 1 : top, 1, 1);
    modal->_popover = [SNPopover showContent:panel forRect:target inView:content placement:SNPlacementBelow gap:0];
    modal->_popover.onClose = ^{ current = nil; };
    [modal resize];
    [modal.window makeFirstResponder:modal.queryField];
    current = modal;
    return modal;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.wantsLayer = YES;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;
    _avatars = [NSMutableArray new];
    _magnifier = [SNIconLayer iconNamed:@"search" size:20 color:SNColorContentSec];
    _magnifier.frame = CGRectMake(kGlyphX - 3, (kInputHeight - 22) / 2, 22, 22);
    [self.layer addSublayer:_magnifier];
    _queryField = [NSTextField textFieldWithString:@""];
    _queryField.bordered = NO;
    _queryField.drawsBackground = NO;
    _queryField.focusRingType = NSFocusRingTypeNone;
    _queryField.font = SNFont(SNFontSizeBase, SNFontWeightRegular);
    _queryField.textColor = SNColor(SNColorContentPry);
    _queryField.placeholderAttributedString = [[NSAttributedString alloc] initWithString:SNLocalized(@"shell.search.modal.placeholder") attributes:@{
        NSFontAttributeName : SNFont(SNFontSizeBase, SNFontWeightRegular),
        NSForegroundColorAttributeName : SNColor(SNColorContentTer),
    }];
    _queryField.delegate = self;
    [self addSubview:_queryField];
    // The note's close is the alert's: a small ghost icon button (16 pt x in 28 pt, base-ter
    // under the pointer).
    _noteClose = [SNButton iconButtonNamed:@"close" size:28 iconSize:16];
    __weak SNSearchModal *weakSelf = self;
    _noteClose.action = ^(SNButton *button) { [weakSelf closeNote]; };
    [self addSubview:_noteClose];
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)close { [_popover close]; }

- (NSArray<NSString *> *)rowTitles {
    NSMutableArray *titles = [NSMutableArray new];
    for (SNSearchRow *row in _rows) [titles addObject:row.title];
    return titles;
}

#pragma mark Rows

- (SNSearchRow *)rowForConversation:(SNConversation *)conversation {
    SNSearchRow *row = [SNSearchRow new];
    row.kind = SNSearchRowConversation;
    row.identifier = conversation.conversationID;
    row.title = SNConversationTitle(conversation, _source);
    if (conversation.kind == SNConversationDirect) {
        SNUser *user = conversation.userID ? [_source userWithID:conversation.userID] : nil;
        row.detail = user.realName.length ? user.realName : nil;
        row.avatarURL = [user avatarURLForPixels:48];
    } else {
        // Slack stacks a group's pictures; its people glyph stands in for them.
        row.icon = conversation.kind == SNConversationGroupDirect ? @"user-groups" : conversation.kind == SNConversationPrivateChannel ? @"lock" : @"channel";
    }
    return row;
}

- (void)showRecent {
    NSMutableOrderedSet *ids = [NSMutableOrderedSet orderedSetWithArray:_recent];
    for (SNConversation *dm in _source.directMessages) [ids addObject:dm.conversationID];
    [ids removeObject:_navigator.location.conversationID ?: @""];
    NSMutableArray *rows = [NSMutableArray new];
    for (NSString *conversationID in ids) {
        SNConversation *conversation = [_source conversationWithID:conversationID];
        if (conversation) [rows addObject:[self rowForConversation:conversation]];
        if (rows.count == kRecentCount) break;
    }
    [self setRows:rows heading:SNLocalized(@"shell.search.modal.recent")];
}

- (void)showSuggestions:(NSString *)query {
    SNSearchRow *search = [SNSearchRow new];
    search.kind = SNSearchRowQuery;
    search.title = query;
    search.icon = @"search";
    NSMutableArray *rows = [NSMutableArray arrayWithObject:search];
    for (SNUser *user in [_source usersMatching:query limit:kSuggestionCount]) {
        SNSearchRow *row = [SNSearchRow new];
        row.kind = SNSearchRowUser;
        row.identifier = user.userID;
        row.title = user.visibleName;
        row.detail = user.realName.length ? user.realName : nil;
        row.avatarURL = [user avatarURLForPixels:48];
        [rows addObject:row];
    }
    for (SNConversation *channel in [_source channelsMatching:query limit:kSuggestionCount]) [rows addObject:[self rowForConversation:channel]];
    [self setRows:rows heading:nil];
}

- (void)runQuery:(NSString *)query {
    NSString *typed = query.length ? query : lastQuery;
    if (!typed.length) return;
    _queryField.stringValue = typed;
    [self showSuggestions:typed];
    if (query.length) [self searchMessages:query];
}

- (void)searchMessages:(NSString *)query {
    lastQuery = [query copy];
    NSUInteger search = ++_searches;
    __weak SNSearchModal *weakSelf = self;
    [_source searchMessages:query page:1 completion:^(SNSearchResult *result, NSError *error) {
        SNSearchModal *modal = weakSelf;
        if (!modal || modal->_searches != search) return;
        NSMutableArray *rows = [NSMutableArray new];
        for (SNMessage *message in result.messages) {
            SNSearchRow *row = [SNSearchRow new];
            row.kind = SNSearchRowMessage;
            row.message = message;
            row.identifier = message.conversationID;
            SNUser *user = message.userID ? [modal->_source userWithID:message.userID] : nil;
            SNConversation *conversation = message.conversationID ? [modal->_source conversationWithID:message.conversationID] : nil;
            row.title = user.visibleName ?: message.username ?: @"";
            row.avatarURL = [user avatarURLForPixels:48];
            NSString *text = [message.text stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
            row.detail = conversation && !conversation.isDirect ? [NSString stringWithFormat:@"#%@ · %@", conversation.name, text] : text;
            [rows addObject:row];
        }
        NSString *heading = rows.count ? SNLocalized(@"shell.search.modal.messages") : SNLocalized(@"shell.search.modal.nothing");
        [modal setRows:rows heading:heading];
    }];
}

- (void)setRows:(NSArray<SNSearchRow *> *)rows heading:(NSString *)heading {
    _rows = rows;
    _heading = heading;
    _selectedIndex = rows.count ? 0 : NSNotFound;
    [self resize];
}

- (void)setSelectedIndex:(NSUInteger)selectedIndex {
    _selectedIndex = selectedIndex;
    self.needsDisplay = YES;
}

#pragma mark Layout

- (CGFloat)rowsTop {
    return kInputHeight + 1 + (noteClosed ? 0 : kNoteGap + kNoteHeight) + (_heading ? kHeadingHeight : kNoteGap);
}

- (NSRect)noteRect { return NSMakeRect(kNoteInset, kInputHeight + 1 + kNoteGap, self.bounds.size.width - 2 * kNoteInset, kNoteHeight); }

/// The close sits in the alert's 1 pt border and 12 16 padding, at the top of its line.
- (NSRect)noteCloseRect {
    NSRect note = [self noteRect];
    return NSMakeRect(NSMaxX(note) - 17 - 28, NSMinY(note) + 13, 28, 28);
}

- (void)closeNote {
    noteClosed = YES;
    [self resize];
}

- (void)resize {
    CGFloat height = [self rowsTop] + kRow * _rows.count + kFooterGap + 1 + kFooterHeight;
    NSView *panel = self.superview.superview;
    if (panel) {
        NSRect frame = panel.frame;
        frame.size.height = height;
        panel.frame = frame;
    }
    self.frame = NSMakeRect(0, 0, self.frame.size.width, height);
    _noteClose.hidden = noteClosed;
    _noteClose.frame = [self noteCloseRect];
    CGFloat fieldHeight = ceil(_queryField.intrinsicContentSize.height);
    _queryField.frame = NSMakeRect(kInputTextX - 2, (kInputHeight - fieldHeight) / 2, self.bounds.size.width - kInputTextX - 80, fieldHeight);
    while (_avatars.count < _rows.count) {
        SNAvatarView *avatar = [[SNAvatarView alloc] initWithFrame:NSMakeRect(0, 0, kIcon, kIcon)];
        [self addSubview:avatar];
        [_avatars addObject:avatar];
    }
    CGFloat top = [self rowsTop];
    for (NSUInteger i = 0; i < _avatars.count; i++) {
        SNAvatarView *avatar = _avatars[i];
        SNSearchRow *row = i < _rows.count ? _rows[i] : nil;
        avatar.hidden = !row.avatarURL;
        avatar.imageURL = row.avatarURL;
        avatar.frame = NSMakeRect(kInset, top + kRow * i + (kRow - kIcon) / 2, kIcon, kIcon);
    }
    self.needsDisplay = YES;
}

#pragma mark Drawing

- (void)drawRect:(NSRect)dirtyRect {
    NSSize size = self.bounds.size;
    NSFont *small = SNFont(SNFontSizeCaption, SNFontWeightRegular);
    [SNColor(SNColorOtlTer) setFill];
    NSRectFillUsingOperation(NSMakeRect(0, kInputHeight, size.width, 1), NSCompositingOperationSourceOver);
    SNDrawIcon(@"refine", 20, SNColorContentSec, NSMakeRect(size.width - 88, 12, 24, 24));
    SNDrawIcon(@"clock", 16, SNColorContentSec, NSMakeRect(size.width - 56, 12, 24, 24));

    if (!noteClosed) {
        NSRect note = [self noteRect];
        [SNColor(SNThemeBaseInvPry) setFill];
        [[NSBezierPath bezierPathWithRoundedRect:note xRadius:kRadius yRadius:kRadius] fill];
        SNDrawIcon(@"ai-search", 20, SNThemeBaseImp, NSMakeRect(NSMinX(note) + 16, NSMinY(note) + 12, 24, 24));
        SNDrawText(SNLocalized(@"shell.search.modal.ai.title"), SNFont(SNFontSizeBase, SNFontWeightBold), SNThemeBaseImp, 22, NSTextAlignmentLeft, 1,
                   NSMakeRect(NSMinX(note) + 49, NSMinY(note) + 12.5, NSWidth(note) - 110, 22));
        SNDrawText(SNLocalized(@"shell.search.modal.ai.subtitle"), SNFont(SNFontSizeBase, SNFontWeightRegular), SNColorContentSec, 22, NSTextAlignmentLeft,
                   1, NSMakeRect(NSMinX(note) + 49, NSMinY(note) + 35, NSWidth(note) - 110, 22));
    }
    CGFloat top = [self rowsTop];
    if (_heading)
        SNDrawText(_heading, small, SNColorContentTer, 20, NSTextAlignmentLeft, 1, NSMakeRect(kInset, top - kHeadingHeight + 19, size.width - 2 * kInset, 20));

    NSFont *name = SNFont(SNFontSizeBase, SNFontWeightRegular);
    for (NSUInteger i = 0; i < _rows.count; i++) {
        SNSearchRow *row = _rows[i];
        NSRect rect = NSMakeRect(0, top + kRow * i, size.width, kRow);
        CGFloat right = size.width - kRightInset;
        if (i == self.selectedIndex) {
            [SNColor(SNColorCtrPry) setFill];
            NSRectFill(rect);
            CGFloat width = ceil(SNTextWidth(SNLocalized(@"shell.search.modal.enter"), small));
            SNDrawText(SNLocalized(@"shell.search.modal.enter"), small, SNColorContentPry, kRow, NSTextAlignmentRight, 1, NSMakeRect(right - width, NSMinY(rect), width, kRow));
            right -= width + 12;
        }
        if (row.icon) SNDrawIcon(row.icon, 16, SNColorContentSec, NSMakeRect(kInset, NSMinY(rect) + (kRow - kIcon) / 2, kIcon, kIcon));
        CGFloat titleWidth = MIN(ceil(SNTextWidth(row.title, name)), right - kTextX);
        SNDrawText(row.title, name, SNLegacyPrimaryForeground, kRow, NSTextAlignmentLeft, 1, NSMakeRect(kTextX, NSMinY(rect), titleWidth, kRow));
        if (row.detail) {
            NSString *detail = [@" · " stringByAppendingString:row.detail];
            CGFloat x = kTextX + titleWidth;
            SNDrawText(detail, small, SNColorContentTer, kRow, NSTextAlignmentLeft, 1, NSMakeRect(x, NSMinY(rect) + 1, MAX(0, right - x), kRow));
        }
    }

    CGFloat footer = size.height - kFooterHeight;
    [SNColor(SNColorOtlTer) setFill];
    NSRectFillUsingOperation(NSMakeRect(0, footer - 1, size.width, 1), NSCompositingOperationSourceOver);
    CGFloat x = kInset;
    // The arrows have no size of their own: they take the chip's 13 px.
    for (NSString *icon in @[ @"caret-up-filled", @"caret-down-filled" ]) {
        NSRect chip = NSMakeRect(x, footer + 11, 22, 22);
        [SNColor(SNColorCtrPry) setFill];
        [[NSBezierPath bezierPathWithRoundedRect:chip xRadius:4 yRadius:4] fill];
        SNDrawIcon(icon, 13, SNColorContentPry, chip);
        x += 25;
    }
    SNDrawText(SNLocalized(@"shell.search.modal.select"), small, SNColorContentSec, kFooterHeight, NSTextAlignmentLeft, 1,
               NSMakeRect(x + 3, footer, 200, kFooterHeight));
    SNDrawText(SNLocalized(@"shell.search.modal.feedback"), small, SNColorContentHgl1, kFooterHeight, NSTextAlignmentRight, 1,
               NSMakeRect(size.width - kRightInset - 200, footer, 200, kFooterHeight));
}

#pragma mark Input

- (void)controlTextDidChange:(NSNotification *)notification {
    _searches++;
    NSString *query = [_queryField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (query.length) [self showSuggestions:query];
    else [self showRecent];
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)command {
    if (command == @selector(moveUp:) || command == @selector(moveDown:)) {
        if (!_rows.count) return YES;
        NSInteger step = command == @selector(moveUp:) ? -1 : 1, count = (NSInteger)_rows.count;
        NSInteger index = self.selectedIndex == NSNotFound ? 0 : ((NSInteger)self.selectedIndex + step + count) % count;
        self.selectedIndex = (NSUInteger)index;
        return YES;
    }
    if (command == @selector(insertNewline:)) {
        [self openSelection];
        return YES;
    }
    return NO;
}

- (void)openSelection {
    if (self.selectedIndex >= _rows.count) return;
    SNSearchRow *row = _rows[self.selectedIndex];
    id<SNNavigator> navigator = _navigator;
    id<SNSource> source = _source;
    // Slack empties the sidebar's filter for whatever the modal opens.
    if (row.kind != SNSearchRowQuery) [navigator resetSidebarFilter];
    switch (row.kind) {
    case SNSearchRowQuery:
        [self searchMessages:row.title];
        return;
    case SNSearchRowConversation:
        [self close];
        [navigator openConversation:row.identifier];
        return;
    case SNSearchRowUser: {
        [self close];
        [source openDirectMessageWithUsers:@[ row.identifier ] completion:^(NSString *conversationID) {
            if (conversationID) [navigator openConversation:conversationID];
        }];
        return;
    }
    case SNSearchRowMessage: {
        [self close];
        SNMessage *message = row.message;
        SNTab tab = navigator.location ? navigator.location.tab : SNTabHome;
        if (message.isReply) {
            SNLocation *target = [[SNLocation locationWithTab:tab conversation:row.identifier thread:message.threadTS] locationWithMessage:message.ts];
            [navigator go:target];
        } else {
            [source loadMessagesAround:message.ts inConversation:row.identifier];
            SNLocation *target = [[SNLocation locationWithTab:tab conversation:row.identifier thread:nil page:nil panel:navigator.location.panel] locationWithMessage:message.ts];
            [navigator go:target];
        }
        return;
    }
    }
}

#pragma mark Pointer

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_tracking) [self removeTrackingArea:_tracking];
    _tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect
                                             options:NSTrackingMouseMoved | NSTrackingActiveAlways | NSTrackingInVisibleRect
                                               owner:self
                                            userInfo:nil];
    [self addTrackingArea:_tracking];
}

- (NSUInteger)rowAtPoint:(NSPoint)point {
    CGFloat offset = point.y - [self rowsTop];
    if (offset < 0) return NSNotFound;
    NSUInteger index = (NSUInteger)(offset / kRow);
    return index < _rows.count ? index : NSNotFound;
}

- (void)mouseMoved:(NSEvent *)event {
    NSUInteger index = [self rowAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
    if (index != NSNotFound && index != self.selectedIndex) self.selectedIndex = index;
}

- (NSCursor *)cursorAtPoint:(NSPoint)point {
    return [self rowAtPoint:point] != NSNotFound ? NSCursor.pointingHandCursor : nil;
}

- (void)mouseDown:(NSEvent *)event {}

- (void)mouseUp:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    NSUInteger index = [self rowAtPoint:point];
    if (index == NSNotFound) return;
    self.selectedIndex = index;
    [self openSelection];
}

@end
