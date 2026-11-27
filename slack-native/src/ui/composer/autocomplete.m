// Owns the candidates, their order and the list's panel.
#import "render/document.h"
#import "render/emoji.h"
#import "render/icon.h"
#import "render/strings.h"
#import "theme/theme.h"
#import "ui/composer/autocomplete.h"
#import "ui/kit/avatar.h"
#import "ui/kit/label.h"
#import "ui/kit/list.h"
#import "ui/kit/overlay.h"
#import "ui/present/names.h"

/// The list uses the menu's chrome and highlight (components.json menu), with 36 pt rows (an
/// avatar or emoji, the name, a secondary name) and #0a77a7 under the chosen row.
static const CGFloat kPadding = 8, kRow = 36, kInset = 16, kMaximumRows = 8, kGap = 4, kPicture = 20, kEmoji = 16;
static const SNColorToken kSecondary = SNColorContentTer;
/// The command list (p-slash_commands_autocomplete_menu): 450-575 pt wide, at most 262 pt tall,
/// 60 pt rows of a 20 pt icon, the name (15 bold) with its usage and a 13 pt line under it in the
/// foreground at 70%; up to 25 commands, scrolled.
static const CGFloat kCommandRow = 60, kCommandMinimumWidth = 450, kCommandMaximumWidth = 575, kCommandMaximumHeight = 262, kCommandIconX = 16;
static const CGFloat kCommandTextX = kCommandIconX + kPicture + 8, kCommandNameLine = 22, kCommandLine = 18;
static const NSUInteger kCommandLimit = 25;
static const SNColorToken kCommandDetail = 0xe8e8e8b3;

@interface SNAutocompleteItem : NSObject
@property (nonatomic, nullable) SNRichEntity *entity;
@property (nonatomic, copy) NSString *text, *title, *subtitle;
@property (nonatomic, nullable) SNUser *user;
@property (nonatomic) SNAvatarPresence presence;
/// A slash command's row (no entity: the command goes in as text).
@property (nonatomic, nullable) SNCommand *command;
/// The emoji drawn in place of an avatar.
@property (nonatomic, copy, nullable) NSString *emojiName;
@end

@implementation SNAutocompleteItem
@end

/// A row: the menu's highlight under the chosen one, then an avatar, emoji or icon with the name
/// and a secondary name, or a command's two lines.
@interface SNAutocompleteRow : SNHoverView
@property (nonatomic) SNAutocompleteItem *item;
@property (nonatomic) BOOL highlighted;
@end

@implementation SNAutocompleteRow {
    SNAvatarView *_avatar;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.hoverColor = self.pressedColor = 0;
    self.cursor = NSCursor.arrowCursor;
    _avatar = [[SNAvatarView alloc] initWithFrame:NSMakeRect(kInset, 8, kPicture, kPicture)];
    [self addSubview:_avatar];
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)setItem:(SNAutocompleteItem *)item {
    if (item != _item) [self.imageHolder removeAllImages];
    _item = item;
    _avatar.hidden = !item.user;
    _avatar.imageURL = [item.user avatarURLForPixels:kPicture * 2];
    _avatar.presence = item.presence;
    self.needsDisplay = YES;
}

- (void)setHighlighted:(BOOL)highlighted {
    _highlighted = highlighted;
    self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    CGContextSetShouldSmoothFonts(NSGraphicsContext.currentContext.CGContext, false);
    NSFont *bold = SNFont(SNFontSizeBase, SNFontWeightBold), *regular = SNFont(SNFontSizeBase, SNFontWeightRegular);
    SNAutocompleteItem *item = self.item;
    CGFloat width = NSWidth(self.bounds);
    BOOL highlighted = self.highlighted;
    if (highlighted) {
        [SNColor(SNColorBaseInvHgl1) setFill];
        NSRectFill(self.bounds);
    }
    if (item.command) return [self drawCommand:item.command highlighted:highlighted];
    CGFloat x = kInset + kPicture + 10;
    if (item.emojiName) {
        NSRect box = NSMakeRect(kInset, 8, kPicture, kPicture);
        SNDrawEmoji(item.emojiName, kEmoji, box, self.imageHolder);
    } else if (!item.user) {
        // Slack draws @here and @channel with its legacy icon font; the outline set's @ stands in.
        SNDrawIcon(item.entity.kind == SNRichEntityChannel ? @"channel" : @"mentions", 18, highlighted ? SNColorContentPry : SNColorContentSec,
                   NSMakeRect(kInset + 2, 10, 16, 16));
    }
    CGFloat titleWidth = MIN([item.title sizeWithAttributes:@{NSFontAttributeName : bold}].width + 1, width - x - kInset);
    SNDrawText(item.title, bold, SNColorContentPry, kRow, NSTextAlignmentLeft, 1, NSMakeRect(x, 0, titleWidth, kRow));
    if (item.subtitle.length) {
        CGFloat subtitleX = x + titleWidth + 8;
        SNDrawText(item.subtitle, regular, highlighted ? SNColorContentPry : kSecondary, kRow, NSTextAlignmentLeft, 1,
                   NSMakeRect(subtitleX, 0, MAX(0, width - subtitleX - kInset), kRow));
    }
}

/// The icon, "/name usage" and "Type · app · description", white on the highlight.
- (void)drawCommand:(SNCommand *)command highlighted:(BOOL)highlighted {
    BOOL slack = [command.type isEqualToString:@"core"];
    CGFloat top = (NSHeight(self.bounds) - kCommandNameLine - kCommandLine) / 2, right = NSWidth(self.bounds) - kInset;
    SNDrawIcon(slack ? @"slack-logo" : @"apps", kPicture, highlighted ? SNColorContentPry : SNColorContentSec, NSMakeRect(kCommandIconX, top + 4, kPicture, kPicture));
    NSFont *name = SNFont(SNFontSizeBase, SNFontWeightBold), *usage = SNFont(SNFontSizeBase, SNFontWeightRegular);
    CGFloat nameWidth = MIN(ceil([command.name sizeWithAttributes:@{NSFontAttributeName : name}].width), right - kCommandTextX);
    SNDrawText(command.name, name, SNColorContentPry, kCommandNameLine, NSTextAlignmentLeft, 1, NSMakeRect(kCommandTextX, top, nameWidth, kCommandNameLine));
    if (command.usage.length)
        SNDrawText(command.usage, usage, highlighted ? SNColorContentPry : kCommandDetail, kCommandNameLine, NSTextAlignmentLeft, 1,
                   NSMakeRect(kCommandTextX + nameWidth + 4, top, MAX(0, right - kCommandTextX - nameWidth - 4), kCommandNameLine));
    // The type in bold, then the integration's name and the description.
    NSString *type = SNLocalized(command.appID ? @"composer.command.app" : slack ? @"composer.command.slack" : @"composer.command.command");
    NSString *source = [command.type isEqualToString:@"custom"] ? SNLocalized(@"composer.command.custom") : command.serviceName;
    NSMutableArray *rest = [NSMutableArray new];
    if (source.length && ![source isEqualToString:type]) [rest addObject:source];
    if (command.summary.length) [rest addObject:command.summary];
    NSFont *small = SNFont(SNFontSizeCaption, SNFontWeightRegular), *smallBold = SNFont(SNFontSizeCaption, SNFontWeightBold);
    SNColorToken detail = highlighted ? SNColorContentPry : kCommandDetail;
    CGFloat typeWidth = ceil([type sizeWithAttributes:@{NSFontAttributeName : smallBold}].width);
    CGFloat lineTop = top + kCommandNameLine;
    SNDrawText(type, smallBold, detail, kCommandLine, NSTextAlignmentLeft, 1, NSMakeRect(kCommandTextX, lineTop, MIN(typeWidth, right - kCommandTextX), kCommandLine));
    if (rest.count)
        SNDrawText([@" · " stringByAppendingString:[rest componentsJoinedByString:@" · "]], small, detail, kCommandLine, NSTextAlignmentLeft, 1,
                   NSMakeRect(kCommandTextX + typeWidth, lineTop, MAX(0, right - kCommandTextX - typeWidth), kCommandLine));
}

@end

/// The rows (ui/kit/list.h) between the panel's 8 pt paddings; the pointer moves the highlight.
@interface SNAutocompleteList : SNListView
@property (nonatomic, copy) NSArray<SNAutocompleteItem *> *items;
@property (nonatomic) NSUInteger highlightedIndex;
@property (nonatomic) CGFloat rowHeight;
@property (nonatomic, copy) void (^pick)(NSUInteger index);
@end

@implementation SNAutocompleteList

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.topInset = self.bottomInset = kPadding;
    self.scrollView.hasVerticalScroller = NO;
    return self;
}

- (void)setItems:(NSArray<SNAutocompleteItem *> *)items {
    _items = [items copy];
    // Each query's rows are new: keyed by place, they reuse the rows shown.
    NSMutableArray<NSString *> *keys = [NSMutableArray arrayWithCapacity:items.count];
    for (NSUInteger i = 0; i < items.count; i++) [keys addObject:@(i).stringValue];
    [self showKeys:keys];
}

- (void)setHighlightedIndex:(NSUInteger)highlightedIndex {
    _highlightedIndex = highlightedIndex;
    [self.visibleIndexes enumerateIndexesUsingBlock:^(NSUInteger index, BOOL *stop) {
        ((SNAutocompleteRow *)[self rowAtIndex:index]).highlighted = index == highlightedIndex;
    }];
}

- (CGFloat)heightOfIndex:(NSUInteger)index width:(CGFloat)width { return self.rowHeight; }

- (SNHoverView *)makeRow {
    SNAutocompleteRow *row = [[SNAutocompleteRow alloc] initWithFrame:NSZeroRect];
    __weak SNAutocompleteList *weakSelf = self;
    row.action = ^(SNAutocompleteRow *picked) {
        SNAutocompleteList *list = weakSelf;
        NSUInteger index = [list.items indexOfObjectIdenticalTo:picked.item];
        if (list.pick && index != NSNotFound) list.pick(index);
    };
    return row;
}

- (void)showIndex:(NSUInteger)index inRow:(SNAutocompleteRow *)row {
    row.item = _items[index];
    row.highlighted = index == self.highlightedIndex;
}

- (void)didHoverIndex:(NSUInteger)index {
    if (index != NSNotFound) self.highlightedIndex = index;
}

@end

/// Lowercased without accents, the way names are compared.
static NSString *Folded(NSString *text) {
    return [text stringByFoldingWithOptions:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch locale:nil] ?: @"";
}

@implementation SNComposerAutocomplete {
    id<SNSource> _source;
    SNPanelView *_panel;
    SNAutocompleteList *_list;
    NSRange _range;
}

- (instancetype)initWithSource:(id<SNSource>)source {
    if (!(self = [super init])) return nil;
    _source = source;
    return self;
}

- (BOOL)isOpen { return _panel.superview != nil; }

- (NSArray<NSString *> *)titles { return [_list.items valueForKey:@"title"] ?: @[]; }
- (NSUInteger)highlightedIndex { return _list.highlightedIndex; }

/// People the source knows: those with a DM, group DM members and the conversation's authors.
- (NSArray<SNUser *> *)knownUsers {
    NSMutableOrderedSet<NSString *> *ids = [NSMutableOrderedSet new];
    if (self.conversationID)
        for (SNMessage *message in [[_source messagesInConversation:self.conversationID] reverseObjectEnumerator])
            if (message.userID) [ids addObject:message.userID];
    for (SNConversation *conversation in _source.directMessages)
        for (SNUser *person in SNConversationPeople(conversation, _source)) [ids addObject:person.userID];
    // The user is unknown until the source has signed in.
    if (_source.me.userID) [ids addObject:_source.me.userID];
    NSMutableArray *users = [NSMutableArray new];
    for (NSString *userID in ids) {
        SNUser *user = [_source userWithID:userID];
        if (user && !user.deleted) [users addObject:user];
    }
    return users;
}

- (NSArray<SNAutocompleteItem *> *)itemsForQuery:(NSString *)query {
    unichar trigger = [query characterAtIndex:0];
    if (trigger == '/' || trigger == 0xff0f) {
        NSMutableArray *items = [NSMutableArray new];
        for (SNCommand *command in [_source commandsMatching:[query substringFromIndex:1] inConversation:self.conversationID threadTS:self.threadTS limit:kCommandLimit]) {
            SNAutocompleteItem *item = [SNAutocompleteItem new];
            item.text = item.title = command.name;
            item.subtitle = command.summary;
            item.command = command;
            [items addObject:item];
        }
        return items;
    }
    NSString *typed = Folded([query substringFromIndex:1]);
    NSMutableArray<NSArray *> *ranked = [NSMutableArray new];
    void (^add)(SNAutocompleteItem *, NSUInteger) = ^(SNAutocompleteItem *item, NSUInteger rank) {
        if (rank != NSNotFound) [ranked addObject:@[ @(rank), @(ranked.count), item ]];
    };
    if (trigger == '@') {
        NSArray<SNUser *> *users = typed.length ? [_source usersMatching:[query substringFromIndex:1] limit:(NSUInteger)kMaximumRows] : self.knownUsers;
        for (SNUser *user in users) {
            SNAutocompleteItem *item = [SNAutocompleteItem new];
            item.entity = [SNRichEntity entityWithKind:SNRichEntityUser value:user.userID];
            item.text = [@"@" stringByAppendingString:user.visibleName];
            item.title = user.visibleName;
            item.subtitle = [user.realName isEqualToString:user.visibleName] ? @"" : user.realName;
            item.user = user;
            item.presence = SNAvatarPresenceOfUser(user, _source);
            add(item, 0);
        }
        SNConversation *conversation = self.conversationID ? [_source conversationWithID:self.conversationID] : nil;
        if (conversation && !conversation.isDirect)
            for (NSString *range in @[ @"here", @"channel", @"everyone" ]) {
                SNAutocompleteItem *item = [SNAutocompleteItem new];
                item.entity = [SNRichEntity entityWithKind:SNRichEntityBroadcast value:range];
                item.text = item.title = [@"@" stringByAppendingString:range];
                item.subtitle = SNLocalized([@"composer.broadcast." stringByAppendingString:range]);
                add(item, typed.length ? ([range hasPrefix:typed] ? 3 : NSNotFound) : 3);
            }
    } else if (trigger == '#') {
        for (SNConversation *conversation in [_source channelsMatching:[query substringFromIndex:1] limit:(NSUInteger)kMaximumRows]) {
            if (conversation.isArchived) continue;
            SNAutocompleteItem *item = [SNAutocompleteItem new];
            item.entity = [SNRichEntity entityWithKind:SNRichEntityChannel value:conversation.conversationID];
            item.text = [@"#" stringByAppendingString:conversation.name];
            item.title = conversation.name;
            item.subtitle = @"";
            add(item, 0);
        }
    } else {
        for (SNEmoji *emoji in SNEmojiMatching(typed, (NSUInteger)kMaximumRows)) {
            SNAutocompleteItem *item = [SNAutocompleteItem new];
            item.entity = [SNRichEntity emojiWithName:emoji.name unicode:SNCodePointsOfText(emoji.unicode)];
            item.text = emoji.unicode;
            item.emojiName = emoji.name;
            item.title = [NSString stringWithFormat:@":%@:", emoji.name];
            item.subtitle = @"";
            add(item, [emoji.name hasPrefix:typed] ? 0 : 1);
        }
        for (NSString *name in SNCustomEmojiNames()) {
            NSUInteger rank = [name hasPrefix:typed] ? 0 : [name containsString:typed] ? 1 : NSNotFound;
            if (rank == NSNotFound) continue;
            SNAutocompleteItem *item = [SNAutocompleteItem new];
            item.entity = [SNRichEntity emojiWithName:name unicode:nil];
            item.text = SNRichCustomEmojiText;
            item.emojiName = name;
            item.title = [NSString stringWithFormat:@":%@:", name];
            item.subtitle = @"";
            add(item, rank);
        }
    }
    [ranked sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) {
        NSComparisonResult byRank = [a[0] compare:b[0]];
        return byRank != NSOrderedSame ? byRank : [a[1] compare:b[1]];
    }];
    NSMutableArray *items = [NSMutableArray new];
    for (NSArray *entry in ranked) {
        if (items.count == kMaximumRows) break;
        SNAutocompleteItem *item = entry[2];
        // Custom aliases of standard emoji are found as the standard ones.
        if (item.entity.kind == SNRichEntityEmoji && !item.entity.unicode && !SNCustomEmojiURL(item.emojiName)) continue;
        [items addObject:item];
    }
    return items;
}

- (void)showQuery:(NSString *)query range:(NSRange)range aboveRect:(NSRect)rect inView:(NSView *)view {
    NSArray *items = query.length ? [self itemsForQuery:query] : @[];
    if (!items.count || !view.window) return [self close];
    _range = range;
    BOOL commands = [items.firstObject command] != nil;
    CGFloat row = commands ? kCommandRow : kRow;
    CGFloat height = MIN(items.count * row + 2 * kPadding, commands ? kCommandMaximumHeight : CGFLOAT_MAX);
    if (!_panel) {
        _panel = [[SNPanelView alloc] initWithFill:SNColorCtrPry radius:SNRadiusMenuLive shadow:SNMenuShadow];
        _list = [[SNAutocompleteList alloc] initWithFrame:NSZeroRect];
        __weak SNComposerAutocomplete *weakSelf = self;
        _list.pick = ^(NSUInteger index) { [weakSelf pick:index]; };
        [_panel.contentView addSubview:_list];
    }
    SNOverlayHost *host = [SNOverlayHost hostForWindow:view.window];
    NSRect target = [host convertRect:rect fromView:view];
    NSSize size = NSMakeSize(commands ? MIN(MAX(NSWidth(target), kCommandMinimumWidth), kCommandMaximumWidth) : NSWidth(target), height);
    _panel.frame = SNPlaceOverlay(size, target, SNPlacementAbove, kGap, NO, host.bounds);
    // Sized first: revealing a row measures against what the list shows.
    _list.frame = (NSRect){NSZeroPoint, size};
    BOOL same = [[_list.items valueForKey:@"title"] isEqualToArray:[items valueForKey:@"title"]];
    _list.rowHeight = row;
    _list.items = items;
    if (!same) {
        _list.highlightedIndex = 0;
        [_list revealIndex:0];
    }
    if (_panel.superview != host) [host addSubview:_panel];
}

- (void)close {
    [_panel removeFromSuperview];
}

- (void)pick:(NSUInteger)index {
    if (index >= _list.items.count) return;
    SNAutocompleteItem *item = _list.items[index];
    NSRange range = _range;
    [self close];
    if (self.choose) self.choose(item.entity, item.text, range);
}

- (BOOL)performCommand:(SEL)command {
    if (!self.isOpen) return NO;
    NSUInteger count = _list.items.count;
    if (command == @selector(moveUp:) || command == @selector(moveDown:)) {
        _list.highlightedIndex = (_list.highlightedIndex + (command == @selector(moveUp:) ? count - 1 : 1)) % count;
        [_list revealIndex:_list.highlightedIndex];
    } else if (command == @selector(insertNewline:) || command == @selector(insertTab:)) [self pick:_list.highlightedIndex];
    else if (command == @selector(cancelOperation:)) [self close];
    else return NO;
    return YES;
}

@end
