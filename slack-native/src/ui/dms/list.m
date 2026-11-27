// Owns the DM list's rows and their measurements.
#import "render/format.h"
#import "ui/dms/list.h"
#import "ui/kit/hoverview.h"
#import "ui/kit/label.h"

/// Measured on the captures: the picture 16 pt from the row's left and top, text 60 pt from the
/// left and 16 pt from the right, the name's 22 pt lines (two at most, beside the date) 12 pt from
/// the top and the preview's under them. A row is 29 pt taller than its text and never shorter
/// than the picture with 16 pt around it.
static const CGFloat kAvatar = 36, kAvatarInset = 16, kTextX = 60, kRightInset = 16, kTop = 12, kLine = 22, kBottom = 17;
static const CGFloat kMinimumHeight = kAvatarInset + kAvatar + kAvatarInset, kHairline = 1;
static const NSUInteger kNameLines = 2, kPreviewLines = 2;
/// The date: 13 pt on a 20 pt line sharing the name's top; 8 pt between the name and the date.
static const CGFloat kDateLine = 20, kNameGap = 8;
/// .p-activity_ia4_page__item__non-collapsible__header: the 13 pt bold content-sec label on an 18 pt
/// line, 24 pt in, padding 8 above (with_top_spacing) and below.
static const CGFloat kHeaderLine = 18, kHeaderInset = 24, kHeaderPadding = 8;

@implementation SNDMListItem
@end

/// A row's measurements at a width: kept while its item, the width and the date's wording stay.
@interface SNDMMeasure : NSObject
@property (nonatomic) CGFloat width, height;
@property (nonatomic, copy) NSString *date;
@property (nonatomic) NSUInteger nameLines;
@property (nonatomic, nullable) SNRenderLayout *layout;
@end

@implementation SNDMMeasure
@end

#pragma mark Row

static NSFont *NameFont(BOOL unread) { return SNFont(SNFontSizeBase, unread ? SNFontWeightBlack : SNFontWeightBold); }
static NSFont *DateFont(BOOL unread) { return SNFont(SNFontSizeCaption, unread ? SNFontWeightBold : SNFontWeightRegular); }

/// The date's width with the gap before it, 0 without a date.
static CGFloat DateWidth(NSString *date, BOOL unread) {
    return date.length ? ceil(SNTextWidth(date, DateFont(unread))) + kNameGap : 0;
}

@interface SNDMRowView : SNHoverView
@property (nonatomic) SNDMListItem *item;
@property (nonatomic) SNRenderLayout *previewLayout;
@property (nonatomic, copy) NSString *dateText;
@property (nonatomic) NSUInteger nameLines;
@property (nonatomic) BOOL current;
@property (nonatomic, readonly) SNAvatarView *avatar;
@end

@implementation SNDMRowView {
    CALayer *_currentLayer;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.hoverColor = self.pressedColor = SNThemeSurfInvTer;
    self.transitionDuration = SNLiveSidebarRowHover;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;
    self.canDrawSubviewsIntoLayer = YES;
    _currentLayer = [CALayer layer];
    _currentLayer.backgroundColor = SNCGColor(SNThemeSurfInvTer);
    _currentLayer.hidden = YES;
    [self.layer insertSublayer:_currentLayer below:self.overlayLayer];
    _avatar = [[SNAvatarView alloc] initWithFrame:NSMakeRect(kAvatarInset, kAvatarInset, kAvatar, kAvatar)];
    // components.json avatar_and_presence: away glyphs take the list's text colour.
    _avatar.awayColor = SNThemeContentInvPry;
    [self addSubview:_avatar];
    return self;
}

- (void)setItem:(SNDMListItem *)item {
    if (item != _item) [self.imageHolder removeAllImages];
    _item = item;
    _avatar.hidden = item.header;
    self.cursor = item.header ? NSCursor.arrowCursor : nil;
    self.hoverColor = self.pressedColor = item.header || self.current ? 0 : SNThemeSurfInvTer;
    _avatar.imageURL = item.avatarURL;
    _avatar.presence = item.presence;
    _avatar.doNotDisturb = item.doNotDisturb;
    self.needsDisplay = YES;
}

- (void)setCurrent:(BOOL)current {
    _current = current;
    _currentLayer.hidden = !current;
    self.hoverColor = self.pressedColor = current || self.item.header ? 0 : SNThemeSurfInvTer;
}

- (void)layout {
    [super layout];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _currentLayer.frame = self.layer.bounds;
    [CATransaction commit];
}

- (void)drawRect:(NSRect)dirtyRect {
    NSRect bounds = self.bounds;
    if (self.item.header) {
        if (self.item.rule) {
            [SNColor(SNThemeOtlInvPry) setFill];
            NSRectFillUsingOperation(NSMakeRect(0, 0, NSWidth(bounds), kHairline), NSCompositingOperationSourceOver);
        }
        SNDrawText(self.item.title, SNFont(SNFontSizeCaption, SNFontWeightBold), SNThemeContentInvSec, kHeaderLine, NSTextAlignmentLeft, 1,
                   NSMakeRect(kHeaderInset, kHeaderPadding, MAX(0, NSWidth(bounds) - kHeaderInset - kRightInset), kHeaderLine));
        return;
    }
    CGFloat right = NSWidth(bounds) - kRightInset;
    [SNColor(SNThemeOtlInvPry) setFill];
    NSRectFillUsingOperation(NSMakeRect(0, NSHeight(bounds) - kHairline, NSWidth(bounds), kHairline), NSCompositingOperationSourceOver);

    CGFloat dateWidth = DateWidth(self.dateText, self.item.unread);
    if (dateWidth)
        SNDrawText(self.dateText, DateFont(self.item.unread), self.item.unread ? SNThemeContentInvPry : SNThemeContentInvSec, kDateLine,
                   NSTextAlignmentRight, 1, NSMakeRect(right - dateWidth + kNameGap, kTop, dateWidth - kNameGap, kDateLine));
    SNDrawText(self.item.title, NameFont(self.item.unread), SNThemeContentInvPry, kLine, NSTextAlignmentLeft, self.nameLines,
               NSMakeRect(kTextX, kTop, MAX(0, right - dateWidth - kTextX), kLine * self.nameLines));

    if (!self.previewLayout) return;
    CGFloat top = kTop + kLine * self.nameLines;
    [NSGraphicsContext saveGraphicsState];
    NSRectClip(NSMakeRect(kTextX, top, NSWidth(bounds) - kRightInset - kTextX, kLine * kPreviewLines));
    [self.previewLayout drawAtPoint:CGPointMake(kTextX, top) hovered:nil images:self.imageHolder];
    [NSGraphicsContext restoreGraphicsState];
}

@end

#pragma mark List

@implementation SNDMListView {
    /// By item, at the width they were made for: items that stay across updates keep theirs.
    NSMapTable<SNDMListItem *, SNDMMeasure *> *_measured;
}

@synthesize now = _now;

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _measured = [NSMapTable strongToStrongObjectsMapTable];
    _items = @[];
    return self;
}

- (NSDate *)now { return _now ?: [NSDate date]; }

- (void)setNow:(NSDate *)now {
    _now = now;
    [self remeasure];
}

- (void)setItems:(NSArray<SNDMListItem *> *)items {
    _items = [items copy];
    NSMapTable<SNDMListItem *, SNDMMeasure *> *kept = [NSMapTable strongToStrongObjectsMapTable];
    for (SNDMListItem *item in _items) {
        SNDMMeasure *measure = [_measured objectForKey:item];
        if (measure) [kept setObject:measure forKey:item];
    }
    _measured = kept;
    [self showKeys:[_items valueForKey:@"identifier"]];
}

- (void)setSelectedIdentifier:(NSString *)selectedIdentifier {
    _selectedIdentifier = [selectedIdentifier copy];
    [self.visibleIndexes enumerateIndexesUsingBlock:^(NSUInteger index, BOOL *stop) {
        ((SNDMRowView *)[self rowAtIndex:index]).current = [self->_items[index].identifier isEqualToString:selectedIdentifier];
    }];
}

#pragma mark Measuring

- (CGFloat)heightOfIndex:(NSUInteger)index width:(CGFloat)width { return [self measureOf:_items[index] width:width].height + kHairline; }

/// The item's measurements at `width`, made again when the width or the date's wording changed.
- (SNDMMeasure *)measureOf:(SNDMListItem *)item width:(CGFloat)width {
    NSString *date = item.date ? SNFormatListDate(item.date, self.now) : @"";
    SNDMMeasure *measure = [_measured objectForKey:item];
    if (measure && measure.width == width && [measure.date isEqualToString:date]) return measure;
    CGFloat textWidth = MAX(1, width - kTextX - kRightInset);
    CGFloat nameWidth = MAX(1, textWidth - DateWidth(date, item.unread));
    measure = [SNDMMeasure new];
    measure.width = width;
    measure.date = date;
    [_measured setObject:measure forKey:item];
    if (item.header) {
        measure.height = kHeaderPadding + kHeaderLine + kHeaderPadding;
        return measure;
    }
    measure.nameLines = MAX(1u, SNLineCount(item.title, NameFont(item.unread), nameWidth, kNameLines));
    measure.layout = item.preview.isEmpty ? nil : [item.preview layoutForWidth:textWidth];
    NSUInteger lines = measure.nameLines + MIN(kPreviewLines, measure.layout.lineCount);
    measure.height = MAX(kMinimumHeight, kTop + kLine * lines + kBottom);
    return measure;
}

#pragma mark Rows

- (SNHoverView *)makeRow {
    SNDMRowView *row = [[SNDMRowView alloc] initWithFrame:NSZeroRect];
    __weak SNDMListView *weakSelf = self;
    row.action = ^(SNDMRowView *chosen) {
        SNDMListView *list = weakSelf;
        if (list.chosen && !chosen.item.header) list.chosen(chosen.item);
    };
    return row;
}

- (void)showIndex:(NSUInteger)index inRow:(SNDMRowView *)row {
    SNDMListItem *item = _items[index];
    SNDMMeasure *measure = [self measureOf:item width:self.bounds.size.width];
    row.previewLayout = measure.layout;
    row.dateText = measure.date;
    row.nameLines = measure.nameLines;
    row.item = item;
    row.current = [item.identifier isEqualToString:self.selectedIdentifier];
}

@end
