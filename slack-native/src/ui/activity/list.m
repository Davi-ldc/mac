// Owns the Activity rows: their measurements, drawing and the hovered row's actions.
#import "render/format.h"
#import "render/strings.h"
#import "ui/activity/list.h"
#import "ui/kit/avatar.h"
#import "ui/kit/hoverview.h"
#import "ui/kit/label.h"

/// The web client's multi-line row: 12 pt around it (20 at the sides in the sidebar), the
/// picture 6 pt lower than the text column 8 pt right of it, which starts 2 pt down with the
/// 22 pt name row; the message on 15/22.5 lines, the place 8 pt under it on 13/16.25; the time
/// 54 pt wide 8 pt after the name; the reaction pill 8 pt under the place, its bar 4 pt into the
/// padding.
static const CGFloat kAvatar = 36, kAvatarTop = 6, kGap = 8, kStackTop = 2, kNameHeight = 22, kTimeWidth = 54, kTimeTop = 2;
static const CGFloat kBodyLine = 22.5, kFooterTop = 8, kFooterLine = 16.25, kPillTop = 8, kPill = 24, kPillOverlap = 4;
static const CGFloat kDot = 8, kStatusTop = 5, kSeparator = 1, kBadgeHeight = 18, kBadgePadding = 6;
static const NSUInteger kNearEnd = 5;

@implementation SNActivityListItem
@end

NSString *SNActivityTime(NSDate *date, NSDate *now) {
    NSTimeInterval age = [now timeIntervalSinceDate:date];
    if (age < 60) return SNLocalized(@"activity.time.now");
    if (age < 3600) return SNLocalizedFormat(@"activity.time.minutes", (long)MAX(1, lround(age / 60)));
    return SNFormatListDate(date, now);
}

/// The colours and paddings of a style.
typedef struct {
    CGFloat side, vertical;
    SNColorToken primary, secondary, tertiary, separator, fill, hover;
} SNActivityLook;

static SNActivityLook LookOf(SNActivityListStyle style) {
    if (style == SNActivityListPeek)
        // base-pry and base-sec (the read fill) are both #1a1d21 in the dark theme.
        return (SNActivityLook){12, 12, SNColorContentPry, SNColorContentSec, SNColorContentTer, SNColorOtlTer, SNColorBasePry, SNColorBasePryHover};
    return (SNActivityLook){20, 12, SNThemeContentInvPry, SNThemeContentInvSec, SNThemeContentInvTer, SNThemeOtlInvPry, 0, SNThemeSurfInvTer};
}

static NSFont *NameFont(BOOL unread) { return SNFont(SNFontSizeBase, unread ? SNFontWeightBlack : SNFontWeightRegular); }
static NSFont *SmallFont(CGFloat weight) { return SNFont(SNFontSizeCaption, weight); }

/// A row's measurements at a width: kept while its item and the width stay.
@interface SNActivityMeasure : NSObject
@property (nonatomic) CGFloat width, height;
@property (nonatomic, nullable) SNRenderLayout *layout;
@property (nonatomic) NSUInteger bodyLines;
@end

@implementation SNActivityMeasure
@end

#pragma mark Row

@interface SNActivityRowView : SNHoverView
@property (nonatomic) SNActivityListItem *item;
@property (nonatomic) SNActivityMeasure *measure;
@property (nonatomic) SNActivityListStyle style;
@property (nonatomic, copy) NSString *timeText;
/// A separator above the row (the peek's border-top, all rows but the first) or under it.
@property (nonatomic) BOOL separatorAbove, separatorBelow;
@property (nonatomic, readonly) SNAvatarView *avatar;
@end

@implementation SNActivityRowView

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.transitionDuration = 0;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;
    _avatar = [[SNAvatarView alloc] initWithFrame:NSMakeRect(0, 0, kAvatar, kAvatar)];
    _avatar.wantsLayer = YES;
    [self addSubview:_avatar];
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)setStyle:(SNActivityListStyle)style {
    _style = style;
    self.hoverColor = self.pressedColor = LookOf(style).hover;
}

- (void)setItem:(SNActivityListItem *)item {
    if (item != _item) [self.imageHolder removeAllImages];
    _item = item;
    _avatar.imageURL = item.avatarURL;
    // activity_multi_line_row_content__entry_avatar: opacity .8, 1 when unread.
    _avatar.alphaValue = item.unread ? 1 : 0.8;
    self.needsDisplay = YES;
}

- (void)layout {
    [super layout];
    SNActivityLook look = LookOf(self.style);
    self.overlayInsets = NSEdgeInsetsMake(self.separatorAbove ? kSeparator : 0, 0, self.separatorBelow ? kSeparator : 0, 0);
    _avatar.frame = NSMakeRect(look.side, (self.separatorAbove ? kSeparator : 0) + look.vertical + kAvatarTop, kAvatar, kAvatar);
}

- (void)drawRect:(NSRect)dirtyRect {
    SNActivityLook look = LookOf(self.style);
    SNActivityListItem *item = self.item;
    NSRect bounds = self.bounds;
    CGFloat top = self.separatorAbove ? kSeparator : 0, width = NSWidth(bounds);
    if (look.fill) {
        [SNColor(look.fill) setFill];
        NSRectFill(NSMakeRect(0, top, width, NSHeight(bounds) - top - (self.separatorBelow ? kSeparator : 0)));
    }
    [SNColor(look.separator) setFill];
    if (self.separatorAbove) NSRectFillUsingOperation(NSMakeRect(0, 0, width, kSeparator), NSCompositingOperationSourceOver);
    if (self.separatorBelow) NSRectFillUsingOperation(NSMakeRect(0, NSHeight(bounds) - kSeparator, width, kSeparator), NSCompositingOperationSourceOver);

    CGFloat x = look.side + kAvatar + kGap, right = width - look.side, y = top + look.vertical + kStackTop;
    // The status column: the unread dot, or a thread's unread replies.
    if (item.unreadReplies > 0) {
        NSString *count = @(item.unreadReplies).stringValue;
        CGFloat badge = ceil(SNTextWidth(count, SmallFont(SNFontWeightBold))) + 2 * kBadgePadding;
        NSRect frame = NSMakeRect(right - badge, top + look.vertical + kStatusTop, badge, kBadgeHeight);
        [SNColor(SNThemeBaseImp) setFill];
        [[NSBezierPath bezierPathWithRoundedRect:frame xRadius:kBadgeHeight / 2 yRadius:kBadgeHeight / 2] fill];
        SNDrawText(count, SmallFont(SNFontWeightBold), SNThemeContentImp, kBadgeHeight, NSTextAlignmentCenter, 1, frame);
        right -= badge + kGap;
    } else if (item.unread) {
        [SNColor(SNThemeBaseImp) setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(right - kDot, top + look.vertical + kStatusTop, kDot, kDot)] fill];
        right -= kDot + kGap;
    }
    CGFloat column = MAX(1, right - x);

    NSFont *nameFont = NameFont(item.unread);
    CGFloat nameWidth = MIN(ceil(SNTextWidth(item.sender, nameFont)), MAX(1, column - kGap - kTimeWidth));
    SNDrawText(item.sender, nameFont, item.unread ? look.primary : look.secondary, kNameHeight, NSTextAlignmentLeft, 1, NSMakeRect(x, y, nameWidth, kNameHeight));
    if (self.timeText.length) {
        // Centred in the name row with its 2 pt padding, as the flex row aligns it.
        CGFloat timeY = y + (kNameHeight - kFooterLine - kTimeTop) / 2 + kTimeTop;
        SNDrawText(self.timeText, SmallFont(SNFontWeightRegular), look.tertiary, kFooterLine, NSTextAlignmentLeft, 1,
                   NSMakeRect(x + nameWidth + kGap, timeY, kTimeWidth, kFooterLine));
    }
    y += kNameHeight;

    CGFloat bodyHeight = kBodyLine * self.measure.bodyLines;
    if (self.measure.layout) {
        [NSGraphicsContext saveGraphicsState];
        NSRectClip(NSMakeRect(x, y, column, bodyHeight));
        [self.measure.layout drawAtPoint:CGPointMake(x, y) hovered:nil images:self.imageHolder];
        [NSGraphicsContext restoreGraphicsState];
    } else {
        // The web client's shimmer placeholder while the message loads.
        [SNColor(SNColorSurfPry) setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x, y + 5, floor(column * 0.7), kBodyLine - 10) xRadius:4 yRadius:4] fill];
    }
    y += bodyHeight;

    if (item.footer.length) {
        y += kFooterTop;
        SNDrawText(item.footer, SmallFont(SNFontWeightRegular), look.tertiary, kFooterLine, NSTextAlignmentLeft, 1, NSMakeRect(x, y, column, kFooterLine));
        y += kFooterLine;
    }

    if (item.reactionName.length) {
        y += kPillTop;
        NSString *count = @(MAX(1, item.reactionCount)).stringValue;
        CGFloat countWidth = ceil(SNTextWidth(count, SNFont(12, SNFontWeightRegular)));
        // Reaction pills (ui/channel/reaction.h): 16 pt emoji and the count, 6 pt in, 4 pt apart.
        NSRect pill = NSMakeRect(x, y, 6 + 16 + 4 + countWidth + 8, kPill);
        [SNColor(self.style == SNActivityListPeek ? SNColorSurfPry : SNThemeSurfInvTer) setFill];
        [[NSBezierPath bezierPathWithRoundedRect:pill xRadius:kPill / 2 yRadius:kPill / 2] fill];
        if (!SNDrawEmoji(item.reactionName, 16, NSMakeRect(NSMinX(pill) + 6, y + 4, 16, 16), self.imageHolder))
            SNDrawText([NSString stringWithFormat:@":%@:", item.reactionName], SNFont(12, SNFontWeightRegular), look.secondary, kPill, NSTextAlignmentLeft, 1,
                       NSMakeRect(NSMinX(pill) + 6, y, 16, kPill));
        SNDrawText(count, SNFont(12, SNFontWeightRegular), look.primary, kPill, NSTextAlignmentLeft, 1, NSMakeRect(NSMinX(pill) + 26, y, countWidth, kPill));
    }
}

@end

#pragma mark List

@implementation SNActivityListView {
    /// By item, at the width they were made for: items that stay across updates keep theirs.
    NSMapTable<SNActivityListItem *, SNActivityMeasure *> *_measured;
    /// The item count when nearEnd was last called, so a list waiting for its next page asks once.
    NSUInteger _askedAtCount;
    SNActivityActionBar *_actionBar;
}

@synthesize now = _now;

- (instancetype)initWithStyle:(SNActivityListStyle)style {
    if (!(self = [super initWithFrame:NSZeroRect])) return nil;
    _style = style;
    _measured = [NSMapTable strongToStrongObjectsMapTable];
    _askedAtCount = NSNotFound;
    _items = @[];
    _actionBar = [[SNActivityActionBar alloc] initWithFrame:NSZeroRect];
    _actionBar.hidden = YES;
    __weak SNActivityListView *weakSelf = self;
    _actionBar.chosen = ^(SNActivityAction action, NSRect rect) { [weakSelf choseAction:action rect:rect]; };
    [self.documentView addSubview:_actionBar];
    return self;
}

- (instancetype)initWithFrame:(NSRect)frame { return [self initWithStyle:SNActivityListPeek]; }

- (NSDate *)now { return _now ?: [NSDate date]; }

- (void)setNow:(NSDate *)now {
    _now = now;
    [self refreshKeys:[NSSet setWithArray:self.keys]];
}

- (void)setItems:(NSArray<SNActivityListItem *> *)items {
    _items = [items copy];
    NSMapTable<SNActivityListItem *, SNActivityMeasure *> *kept = [NSMapTable strongToStrongObjectsMapTable];
    for (SNActivityListItem *item in _items) {
        SNActivityMeasure *measure = [_measured objectForKey:item];
        if (measure) [kept setObject:measure forKey:item];
    }
    _measured = kept;
    [self showKeys:[_items valueForKey:@"identifier"]];
}

#pragma mark Measuring

- (BOOL)separatorAboveRow:(NSUInteger)index { return self.style == SNActivityListPeek && index > 0; }
- (BOOL)separatorBelowRow:(NSUInteger)index { return self.style == SNActivityListSidebar; }

/// The text column's width: the row less its paddings, the picture and the status column.
- (CGFloat)columnWidthOf:(SNActivityListItem *)item width:(CGFloat)width {
    SNActivityLook look = LookOf(self.style);
    CGFloat status = 0;
    if (item.unreadReplies > 0)
        status = ceil(SNTextWidth(@(item.unreadReplies).stringValue, SmallFont(SNFontWeightBold))) + 2 * kBadgePadding + kGap;
    else if (item.unread)
        status = kDot + kGap;
    return MAX(1, width - 2 * look.side - kAvatar - kGap - status);
}

- (CGFloat)heightOfIndex:(NSUInteger)index width:(CGFloat)width {
    return [self measureOf:_items[index] width:width].height + ([self separatorAboveRow:index] || [self separatorBelowRow:index] ? kSeparator : 0);
}

/// The item's measurements at `width`, made again when the width changed.
- (SNActivityMeasure *)measureOf:(SNActivityListItem *)item width:(CGFloat)width {
    SNActivityMeasure *measure = [_measured objectForKey:item];
    if (measure && measure.width == width) return measure;
    SNActivityLook look = LookOf(self.style);
    measure = [SNActivityMeasure new];
    measure.width = width;
    measure.layout = item.body.isEmpty ? nil : [item.body layoutForWidth:[self columnWidthOf:item width:width]];
    measure.bodyLines = measure.layout ? MAX(1u, MIN(item.bodyLines ?: 2, measure.layout.lineCount)) : 1;
    CGFloat stack = kStackTop + kNameHeight + kBodyLine * measure.bodyLines + (item.footer.length ? kFooterTop + kFooterLine : 0) +
                    (item.reactionName.length ? kPillTop + kPill - kPillOverlap : 0);
    measure.height = 2 * look.vertical + MAX(stack, kAvatarTop + kAvatar);
    [_measured setObject:measure forKey:item];
    return measure;
}

#pragma mark Rows

- (SNHoverView *)makeRow {
    SNActivityRowView *row = [[SNActivityRowView alloc] initWithFrame:NSZeroRect];
    __weak SNActivityListView *weakSelf = self;
    row.action = ^(SNActivityRowView *chosen) {
        SNActivityListView *list = weakSelf;
        if (list.chosen) list.chosen(chosen.item);
    };
    return row;
}

- (void)showIndex:(NSUInteger)index inRow:(SNActivityRowView *)row {
    SNActivityListItem *item = _items[index];
    row.style = self.style;
    row.separatorAbove = [self separatorAboveRow:index];
    row.separatorBelow = [self separatorBelowRow:index];
    row.measure = [self measureOf:item width:self.bounds.size.width];
    row.timeText = item.date ? SNActivityTime(item.date, self.now) : @"";
    row.item = item;
    row.needsLayout = YES;
}

- (void)didPlaceRows {
    [self placeActions];
    NSUInteger last = self.visibleIndexes.lastIndex;
    if (self.nearEnd && _items.count && last != NSNotFound && last + 1 + kNearEnd >= _items.count && _askedAtCount != _items.count) {
        _askedAtCount = _items.count;
        self.nearEnd();
    }
}

#pragma mark Actions

- (void)didHoverIndex:(NSUInteger)index { [self placeActions]; }

/// activity_multi_line_row_content__actions_toggle: against the row's content box (inside its
/// padding), 4 pt past its right edge with its bottom 2 pt into the content, so it floats over the
/// row above; the first row's sits 4 pt into it, and the peek's 4 pt above its content at its edge.
- (void)placeActions {
    NSUInteger hovered = self.hoveredIndex;
    SNActivityListItem *item = hovered < _items.count ? _items[hovered] : nil;
    _actionBar.hidden = !item;
    if (!item) return;
    NSMutableArray *actions = [NSMutableArray new];
    if (item.unread) [actions addObject:@(SNActivityActionMarkRead)];
    else if (!item.reactionName.length) [actions addObject:@(SNActivityActionMarkUnread)];
    [actions addObjectsFromArray:@[ @(SNActivityActionClear), @(SNActivityActionMore) ]];
    [_actionBar showActions:actions];
    SNActivityLook look = LookOf(self.style);
    CGFloat contentTop = NSMinY([self rectOfIndex:hovered]) + ([self separatorAboveRow:hovered] ? kSeparator : 0) + look.vertical;
    CGFloat width = _actionBar.width, right = self.bounds.size.width - look.side, top;
    if (self.style == SNActivityListPeek) top = contentTop - 4;
    else if (hovered == 0) {
        top = contentTop + 4;
        right += 4;
    } else {
        top = contentTop + 2 - SNActivityActionsHeight;
        right += 4;
    }
    _actionBar.frame = NSMakeRect(right - width, top, width, SNActivityActionsHeight);
}

- (void)choseAction:(SNActivityAction)action rect:(NSRect)rect {
    NSUInteger hovered = self.hoveredIndex;
    if (hovered >= _items.count || !self.actionChosen) return;
    self.actionChosen(_items[hovered], action, [self convertRect:rect fromView:_actionBar]);
}

- (void)mouseMoved:(NSEvent *)event {
    // The actions float over the row above: over them, their row stays hovered.
    if (!_actionBar.hidden && NSPointInRect([self.documentView convertPoint:event.locationInWindow fromView:nil], _actionBar.frame)) return;
    [super mouseMoved:event];
}

@end
