// Owns the people picker: its chips, typing field and the list of people matching.
#import "render/icon.h"
#import "render/images.h"
#import "ui/kit/avatar.h"
#import "ui/kit/label.h"
#import "ui/kit/list.h"
#import "ui/kit/people.h"
#import "ui/kit/popover.h"

/// .multiSelectInput--large: 44 pt at least, 4 pt in at the left, 28 at the right, 4 at the bottom;
/// chips 32 tall 4 pt from the top and left of the one before.
static const CGFloat kMinHeight = 44, kChip = 32, kChipGap = 4, kRightPadding = 28, kFieldMin = 120;
/// c-token--large: 18 pt bold, 8 pt after the picture, the x 4 pt from the end.
static const CGFloat kChipText = 18, kChipTextGap = 8, kRemove = 16;
/// The list: at most 200 pt, rows 24 pt in, a 20 pt picture 8 pt before the name.
static const CGFloat kListMax = 200, kRowInset = 24, kRowAvatar = 20, kRowGap = 8, kPresence = 8;
static const unsigned short kDelete = 51;

/// CGContextDrawImage draws bottom-up; these views are flipped.
static void DrawPicture(CGImageRef image, NSRect rect) {
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    CGContextSaveGState(context);
    CGContextTranslateCTM(context, NSMinX(rect), NSMaxY(rect));
    CGContextScaleCTM(context, 1, -1);
    CGContextDrawImage(context, CGRectMake(0, 0, NSWidth(rect), NSHeight(rect)), image);
    CGContextRestoreGState(context);
}

static NSString *Primary(SNUser *user) { return user.displayName.length ? user.displayName : user.realName.length ? user.realName : user.handle; }
static NSString *Secondary(SNUser *user) { return user.displayName.length && user.realName.length && ![user.realName isEqualToString:user.displayName] ? user.realName : nil; }

/// One chosen person.
@interface SNPeopleChip : NSView <SNCursorProvider>
@property (nonatomic, copy) NSString *userID;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, nullable) NSURL *pictureURL;
@property (nonatomic, copy) void (^removed)(void);
@end

@implementation SNPeopleChip

- (BOOL)isFlipped { return YES; }

+ (CGFloat)widthForName:(NSString *)name {
    return kChip + kChipTextGap + ceil(SNTextWidth(name, SNFont(kChipText, SNFontWeightBold))) + 4 + kRemove + 4;
}

- (NSRect)removeRect { return NSMakeRect(NSWidth(self.bounds) - 4 - kRemove - 2, (kChip - kRemove - 4) / 2, kRemove + 4, kRemove + 4); }

- (void)mouseDown:(NSEvent *)event {}

- (void)mouseUp:(NSEvent *)event {
    if (NSPointInRect([self convertPoint:event.locationInWindow fromView:nil], self.removeRect)) self.removed();
}

- (NSCursor *)cursorAtPoint:(NSPoint)point { return NSPointInRect(point, self.removeRect) ? NSCursor.pointingHandCursor : nil; }

- (void)drawRect:(NSRect)dirtyRect {
    NSBezierPath *chip = [NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:SNRadiusBase yRadius:SNRadiusBase];
    [SNColor(SNColorSurfHgl1) setFill];
    [chip fill];
    NSRect avatar = NSMakeRect(0, 0, kChip, kChip);
    [NSGraphicsContext saveGraphicsState];
    [chip addClip];
    CGImageRef picture = _pictureURL ? [self.imageHolder imageWithURL:_pictureURL pixels:kChip * 2] : NULL;
    if (picture) DrawPicture(picture, avatar);
    else {
        [SNColor(SNColorBaseTer) setFill];
        NSRectFill(avatar);
    }
    [NSGraphicsContext restoreGraphicsState];
    SNDrawText(_name, SNFont(kChipText, SNFontWeightBold), SNColorContentPry, kChip, NSTextAlignmentLeft, 1,
               NSMakeRect(kChip + kChipTextGap, 0, NSWidth(self.bounds) - kChip - kChipTextGap - kRemove - 8, kChip));
    SNDrawIcon(@"close", kRemove, SNColorContentPry, NSMakeRect(NSWidth(self.bounds) - 4 - kRemove, (kChip - kRemove) / 2, kRemove, kRemove));
}

@end

/// The list of people matching what is typed.
/// A person the list offers: picture, name, presence and other name, or why they cannot be chosen.
@interface SNPeopleRow : SNHoverView
@property (nonatomic) SNUser *user;
@property (nonatomic, copy, nullable) NSString *reason;
@property (nonatomic) SNAvatarPresence presence;
@property (nonatomic) BOOL highlighted;
@end

@implementation SNPeopleRow

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.hoverColor = self.pressedColor = 0;
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)setUser:(SNUser *)user {
    if (user != _user) [self.imageHolder removeAllImages];
    _user = user;
    self.needsDisplay = YES;
}

- (void)setReason:(NSString *)reason {
    _reason = [reason copy];
    self.cursor = reason ? NSCursor.arrowCursor : nil;
    self.needsDisplay = YES;
}

- (void)setHighlighted:(BOOL)highlighted {
    _highlighted = highlighted;
    self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    NSFont *bold = SNFont(SNFontSizeBase, SNFontWeightBold), *regular = SNFont(SNFontSizeBase, SNFontWeightRegular);
    SNUser *user = self.user;
    NSRect row = self.bounds;
    BOOL disabled = self.reason != nil, active = self.highlighted && !disabled;
    if (active) {
        [SNColor(SNColorBaseInvHgl1) setFill];
        NSRectFill(row);
    }
    SNColorToken text = disabled ? SNColorContentSec : SNColorContentPry;
    CGFloat x = kRowInset, middle = NSMidY(row);
    NSRect avatar = NSMakeRect(x, middle - kRowAvatar / 2, kRowAvatar, kRowAvatar);
    NSURL *url = [user avatarURLForPixels:kRowAvatar * 2];
    CGImageRef picture = url ? [self.imageHolder imageWithURL:url pixels:kRowAvatar * 2] : NULL;
    NSBezierPath *clip = [NSBezierPath bezierPathWithRoundedRect:avatar xRadius:SNRadiusBase yRadius:SNRadiusBase];
    [NSGraphicsContext saveGraphicsState];
    [clip addClip];
    if (picture) DrawPicture(picture, avatar);
    else {
        [SNColor(SNColorBaseTer) setFill];
        NSRectFill(avatar);
    }
    [NSGraphicsContext restoreGraphicsState];
    x = NSMaxX(avatar) + kRowGap;
    NSString *reason = self.reason;
    CGFloat reasonWidth = reason ? ceil(SNTextWidth(reason, regular)) : 0;
    CGFloat right = NSWidth(row) - kRowInset - (reason ? reasonWidth + 12 : 0);
    NSString *primary = Primary(user);
    CGFloat width = MIN(right - x, ceil(SNTextWidth(primary, bold)));
    SNDrawText(primary, bold, text, NSHeight(row), NSTextAlignmentLeft, 1, NSMakeRect(x, NSMinY(row), width, NSHeight(row)));
    x += width + 4;
    if (self.presence != SNAvatarPresenceNone && x + kPresence < right) {
        NSRect dot = NSMakeRect(x + 0.5, middle - kPresence / 2 + 0.5, kPresence - 1, kPresence - 1);
        NSBezierPath *circle = [NSBezierPath bezierPathWithOvalInRect:dot];
        if (self.presence == SNAvatarPresenceActive) {
            [SNColor(SNColorContentHgl2) setFill];
            [circle fill];
        } else {
            [SNColor(active ? SNColorContentPry : SNColorContentSec) setStroke];
            [circle stroke];
        }
        x += kPresence + 4;
    }
    NSString *secondary = Secondary(user);
    if (secondary && x < right)
        SNDrawText(secondary, regular, active ? SNColorContentPry : SNColorContentSec, NSHeight(row), NSTextAlignmentLeft, 1,
                   NSMakeRect(x, NSMinY(row), right - x, NSHeight(row)));
    if (reason)
        SNDrawText(reason, regular, SNColorContentSec, NSHeight(row), NSTextAlignmentRight, 1, NSMakeRect(right + 12, NSMinY(row), reasonWidth, NSHeight(row)));
}

@end

/// The people matching what is typed (ui/kit/list.h); the pointer moves the highlight.
@interface SNPeopleSuggestions : SNListView
@property (nonatomic, readonly) NSArray<SNUser *> *users;
@property (nonatomic, weak) id<SNSource> source;
/// Why each person cannot be chosen, NSNull when they can.
@property (nonatomic, readonly) NSArray *reasons;
@property (nonatomic) CGFloat rowHeight;
@property (nonatomic) NSUInteger highlighted;
@property (nonatomic, copy) void (^chose)(NSUInteger index);
@end

@implementation SNPeopleSuggestions

- (void)setUsers:(NSArray<SNUser *> *)users reasons:(NSArray *)reasons {
    _users = users;
    _reasons = reasons;
    [self showKeys:[users valueForKey:@"userID"]];
}

- (void)setHighlighted:(NSUInteger)highlighted {
    _highlighted = highlighted;
    [self.visibleIndexes enumerateIndexesUsingBlock:^(NSUInteger index, BOOL *stop) {
        ((SNPeopleRow *)[self rowAtIndex:index]).highlighted = index == highlighted;
    }];
}

- (CGFloat)heightOfIndex:(NSUInteger)index width:(CGFloat)width { return self.rowHeight; }

- (SNHoverView *)makeRow {
    SNPeopleRow *row = [[SNPeopleRow alloc] initWithFrame:NSZeroRect];
    __weak SNPeopleSuggestions *weakSelf = self;
    row.action = ^(SNPeopleRow *chosen) {
        SNPeopleSuggestions *list = weakSelf;
        NSUInteger index = [list.users indexOfObjectIdenticalTo:chosen.user];
        if (index != NSNotFound) list.chose(index);
    };
    return row;
}

- (void)showIndex:(NSUInteger)index inRow:(SNPeopleRow *)row {
    row.user = _users[index];
    row.reason = _reasons[index] == NSNull.null ? nil : _reasons[index];
    row.presence = SNAvatarPresenceOfUser(_users[index], self.source);
    row.highlighted = index == self.highlighted;
}

- (void)didHoverIndex:(NSUInteger)index {
    if (index != NSNotFound) self.highlighted = index;
}

@end

@interface SNPeoplePicker () <NSTextFieldDelegate, SNChangeObserver>
@end

@implementation SNPeoplePicker {
    id<SNSource> _source;
    NSString *_placeholder;
    CGFloat _rowHeight;
    NSMutableArray<NSString *> *_chosen;
    NSMutableArray<SNPeopleChip *> *_chips;
    NSTextField *_field;
    SNPeopleSuggestions *_list;
    __weak SNPopover *_popover;
}

- (instancetype)initWithSource:(id<SNSource>)source placeholder:(NSString *)placeholder rowHeight:(CGFloat)rowHeight {
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, 400, kMinHeight)])) return nil;
    _source = source;
    _placeholder = [placeholder copy];
    _rowHeight = rowHeight;
    _limit = 20;
    _chosen = [NSMutableArray new];
    _chips = [NSMutableArray new];
    _field = [NSTextField textFieldWithString:@""];
    _field.bordered = NO;
    _field.drawsBackground = NO;
    _field.focusRingType = NSFocusRingTypeNone;
    _field.font = SNFont(kChipText, SNFontWeightRegular);
    _field.textColor = SNColor(SNColorContentPry);
    _field.delegate = self;
    [self addSubview:_field];
    [self updatePlaceholder];
    [source addChangeObserver:self];
    return self;
}

- (void)dealloc {
    if (_popover.content) [_popover close];
}

- (BOOL)isFlipped { return YES; }

- (void)focus { [self.window makeFirstResponder:_field]; }

- (void)updatePlaceholder {
    _field.placeholderAttributedString = [[NSAttributedString alloc] initWithString:_chosen.count ? @"" : _placeholder
                                                                         attributes:@{NSFontAttributeName : _field.font, NSForegroundColorAttributeName : SNColor(SNColorContentTer)}];
}

#pragma mark Chips

- (NSArray<NSString *> *)userIDs { return [_chosen copy]; }

- (void)setUserIDs:(NSArray<NSString *> *)userIDs {
    for (SNPeopleChip *chip in _chips) [chip removeFromSuperview];
    [_chips removeAllObjects];
    [_chosen removeAllObjects];
    for (NSString *userID in userIDs) [self addChip:userID];
    [self chipsChanged];
}

- (void)addChip:(NSString *)userID {
    if ([_chosen containsObject:userID]) return;
    SNUser *user = [_source userWithID:userID];
    SNPeopleChip *chip = [[SNPeopleChip alloc] initWithFrame:NSZeroRect];
    chip.userID = userID;
    chip.name = user ? Primary(user) : userID;
    chip.pictureURL = [user avatarURLForPixels:kChip * 2];
    __weak SNPeoplePicker *weakSelf = self;
    chip.removed = ^{ [weakSelf removeUser:userID]; };
    [_chosen addObject:userID];
    [_chips addObject:chip];
    [self addSubview:chip];
}

- (void)removeUser:(NSString *)userID {
    NSUInteger index = [_chosen indexOfObject:userID];
    if (index == NSNotFound) return;
    [_chips[index] removeFromSuperview];
    [_chips removeObjectAtIndex:index];
    [_chosen removeObjectAtIndex:index];
    [self chipsChanged];
}

- (void)chipsChanged {
    [self updatePlaceholder];
    CGFloat before = NSHeight(self.frame);
    [self layoutChips];
    if (self.changed) self.changed();
    if (NSHeight(self.frame) != before && self.heightChanged) self.heightChanged();
}

/// Chips flow in rows; the field follows the last one, or starts a row when it has no room.
- (CGFloat)layoutChipsAt:(CGFloat)width apply:(BOOL)apply {
    CGFloat x = kChipGap, y = kChipGap, right = width - kRightPadding;
    for (SNPeopleChip *chip in _chips) {
        CGFloat chipWidth = MIN([SNPeopleChip widthForName:chip.name], right - kChipGap);
        if (x > kChipGap && x + chipWidth > right) x = kChipGap, y += kChip + kChipGap;
        if (apply) chip.frame = NSMakeRect(x, y, chipWidth, kChip);
        x += chipWidth + kChipGap;
    }
    if (_chips.count && x + kFieldMin > right) x = kChipGap, y += kChip + kChipGap;
    CGFloat fieldHeight = ceil(_field.intrinsicContentSize.height);
    CGFloat left = _chips.count ? x + 4 : 12;
    if (apply) _field.frame = NSMakeRect(left, y + (kChip - fieldHeight) / 2, MAX(40, right - left), fieldHeight);
    return MAX(kMinHeight, y + kChip + kChipGap);
}

- (CGFloat)preferredHeight { return [self layoutChipsAt:NSWidth(self.bounds) apply:NO]; }

- (void)layoutChips {
    CGFloat height = [self layoutChipsAt:NSWidth(self.bounds) apply:YES];
    if (height != NSHeight(self.frame)) [self setFrameSize:NSMakeSize(NSWidth(self.frame), height)];
}

- (void)setFrameSize:(NSSize)size {
    [super setFrameSize:size];
    [self layoutChipsAt:size.width apply:YES];
}

- (void)mouseDown:(NSEvent *)event { [self focus]; }

- (void)drawRect:(NSRect)dirtyRect {
    NSBezierPath *box = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 0.5, 0.5) xRadius:SNRadiusLarge - 0.5 yRadius:SNRadiusLarge - 0.5];
    [SNColor(SNColorBasePry) setFill];
    [box fill];
    [SNColor(SNColorOtlPry) setStroke];
    [box stroke];
}

#pragma mark Typing and the list

- (void)typeQuery:(NSString *)query {
    _field.stringValue = query;
    [self queryChanged];
}

- (void)controlTextDidChange:(NSNotification *)notification { [self queryChanged]; }

- (void)sourceChanged:(SNChange *)change {
    if (_popover.content && [change.users count]) [self queryChanged];
    else if (_popover.content && [change.presence intersectsSet:[NSSet setWithArray:_list.keys]])
        [_list refreshKeys:change.presence];
}

/// The people whose names start with what is typed whom the list offers.
- (NSArray<SNUser *> *)matches {
    NSString *query = [_field.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if ([query hasPrefix:@"@"]) query = [query substringFromIndex:1];
    if (!query.length) return @[];
    NSMutableArray<SNUser *> *users = [NSMutableArray new];
    NSString *me = _source.me.userID;
    for (SNUser *user in [_source usersMatching:query limit:_limit + 5]) {
        if (users.count == _limit) break;
        if ([_chosen containsObject:user.userID]) continue;
        if (self.offers ? !self.offers(user) : user.isBot || user.isAppUser || user.deleted || [user.userID isEqualToString:me] || [user.userID isEqualToString:@"USLACKBOT"]) continue;
        [users addObject:user];
    }
    return users;
}

- (void)queryChanged {
    NSArray<SNUser *> *users = self.matches;
    if (!users.count) {
        [_popover close];
        return;
    }
    NSMutableArray *reasons = [NSMutableArray new];
    NSUInteger first = NSNotFound;
    for (SNUser *user in users) {
        NSString *reason = self.unavailableReason ? self.unavailableReason(user) : nil;
        [reasons addObject:reason ?: NSNull.null];
        if (!reason && first == NSNotFound) first = reasons.count - 1;
    }
    CGFloat height = MIN(kListMax, users.count * _rowHeight);
    if (!_popover.content) {
        _list = [[SNPeopleSuggestions alloc] initWithFrame:NSZeroRect];
        _list.source = _source;
        __weak SNPeoplePicker *weakSelf = self;
        _list.chose = ^(NSUInteger index) { [weakSelf chooseSuggestionAtIndex:index]; };
        SNPanelView *panel = [[SNPanelView alloc] initWithFill:SNColorCtrPry radius:SNRadiusMenuLive shadow:SNMenuShadow];
        panel.frame = NSMakeRect(0, 0, NSWidth(self.bounds), height);
        _list.frame = panel.contentView.bounds;
        _list.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [panel.contentView addSubview:_list];
        NSResponder *typing = self.window.firstResponder;
        _popover = [SNPopover showContent:panel forRect:self.bounds inView:self placement:SNPlacementBelow gap:4];
        // The keyboard stays in the field, which drives the list.
        if (typing) [self.window makeFirstResponder:typing];
    }
    _list.rowHeight = _rowHeight;
    [_list setUsers:users reasons:reasons];
    _list.highlighted = first == NSNotFound ? 0 : first;
    NSView *panel = _popover.content;
    NSRect frame = panel.frame;
    frame.size.height = height;
    panel.frame = frame;
}

- (NSArray<NSString *> *)suggestionTitles {
    NSMutableArray *titles = [NSMutableArray new];
    for (SNUser *user in _popover.content ? _list.users : @[]) [titles addObject:Primary(user)];
    return titles;
}

- (void)chooseSuggestionAtIndex:(NSUInteger)index {
    if (!_popover.content || index >= _list.users.count || _list.reasons[index] != NSNull.null) return;
    if (_maximum && _chosen.count >= _maximum) return;
    [self addChip:_list.users[index].userID];
    _field.stringValue = @"";
    [_popover close];
    [self chipsChanged];
    [self focus];
}

- (void)moveHighlight:(NSInteger)step {
    NSInteger count = (NSInteger)_list.users.count, index = (NSInteger)_list.highlighted;
    for (NSInteger i = index + step; i >= 0 && i < count; i += step)
        if (_list.reasons[(NSUInteger)i] == NSNull.null) {
            _list.highlighted = (NSUInteger)i;
            [_list revealIndex:(NSUInteger)i];
            return;
        }
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)command {
    BOOL open = _popover.content != nil;
    if (open && (command == @selector(moveDown:) || command == @selector(moveUp:))) [self moveHighlight:command == @selector(moveDown:) ? 1 : -1];
    else if (open && (command == @selector(insertNewline:) || command == @selector(insertTab:))) [self chooseSuggestionAtIndex:_list.highlighted];
    else if (command == @selector(deleteBackward:) && !_field.stringValue.length && _chosen.count) [self removeUser:_chosen.lastObject];
    else return NO;
    return YES;
}

- (void)keyDown:(NSEvent *)event {
    if (event.keyCode == kDelete && _chosen.count) [self removeUser:_chosen.lastObject];
    else [super keyDown:event];
}

@end
