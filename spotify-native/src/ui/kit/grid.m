// Virtualized responsive borderless Spotifly card grid & horizontal card shelf with zero wantsLayer bloat.
#import "ui/kit/grid.h"
#import "render/icons.h"
#import "render/images.h"
#import "theme/theme.h"

#import <math.h>
#import <stdlib.h>

@implementation SPCardItem

- (instancetype)initWithKey:(NSString *)key
                      title:(NSString *)title
                   subtitle:(NSString *)subtitle
                 artworkURL:(NSString *)artworkURL
                   circular:(BOOL)circular
                 contextURI:(NSString *)contextURI
          representedObject:(id)representedObject {
    if (!(self = [super init])) return nil;
    _key = [key copy];
    _title = [title copy] ?: @"";
    _subtitle = [subtitle copy];
    _artworkURL = [artworkURL copy];
    _circular = circular;
    _contextURI = [contextURI copy];
    _representedObject = representedObject;
    return self;
}

- (id)copyWithZone:(NSZone *)zone { return self; }

@end

@implementation SPCardCellView

- (BOOL)isFlipped { return YES; }

- (void)setItem:(SPCardItem *)item {
    if (_item == item) return;
    if (_item && ![_item.artworkURL isEqualToString:item.artworkURL]) {
        [self.imageHolder removeAllImages];
    }
    _item = item;
    self.needsDisplay = YES;
}

- (void)setHovered:(BOOL)hovered {
    if (_hovered == hovered) return;
    _hovered = hovered;
    self.needsDisplay = YES;
}

- (void)setPlayHovered:(BOOL)playHovered {
    if (_playHovered == playHovered) return;
    _playHovered = playHovered;
    self.needsDisplay = YES;
}

- (void)prepareForReuse {
    _hovered = NO;
    _playHovered = NO;
    _item = nil;
}

- (NSRect)artworkRect {
    CGFloat art = MAX(20.0, self.bounds.size.width);
    return NSMakeRect(0.0, 0.0, art, art);
}

- (NSRect)playButtonRect {
    NSRect art = [self artworkRect];
    CGFloat btn = 34.0;
    if (_item.circular) {
        return NSMakeRect(floor(CGRectGetMidX(art) - btn * 0.5), NSMaxY(art) - btn - 8.0, btn, btn);
    }
    return NSMakeRect(NSMaxX(art) - btn - 8.0, NSMaxY(art) - btn - 8.0, btn, btn);
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    if (!_item) return;
    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    if (!ctx) return;

    const SPTypographyScale *typo = SPThemeTypography();
    const SPLayoutMetrics *m = SPThemeMetrics();

    // Spotifly AlbumCard / ArtistCard / PlaylistCard: borderless artwork directly on window background
    // with soft 2pt drop shadow, rounded 8pt (or circle for Artist).
    NSRect artRect = [self artworkRect];
    if (_item.isLikedSongsTile) {
        SPDrawLikedSongsTile(ctx, artRect, m->radiusLG, YES);
    } else {
        CGFloat scale = self.window.backingScaleFactor ?: 2.0;
        CGImageRef artImg = NULL;
        if (_item.artworkURL.length) {
            NSURL *url = [NSURL URLWithString:_item.artworkURL];
            if (url) {
                artImg = [self.imageHolder imageWithURL:url pixels:ceil(artRect.size.width * scale)];
            }
        }
        NSString *sym = _item.placeholderSymbol.length
            ? _item.placeholderSymbol
            : (_item.circular ? @"person.circle.fill" : @"music.note");
        CGFloat symSz = _item.circular ? 52.0 : 38.0;
        SPDrawArtworkSemantic(ctx, artImg, artRect, m->radiusLG, _item.circular, sym, symSz, 2.0);
    }

    // Subtle hover sheen + Spotify green play circle overlay
    if (_hovered) {
        CGContextSaveGState(ctx);
        CGPathRef clip = _item.circular
            ? CGPathCreateWithEllipseInRect(artRect, NULL)
            : CGPathCreateWithRoundedRect(artRect, m->radiusLG, m->radiusLG, NULL);
        CGContextAddPath(ctx, clip);
        CGContextClip(ctx);
        CGContextSetFillColorWithColor(ctx, [NSColor colorWithWhite:1.0 alpha:0.06].CGColor);
        CGContextFillRect(ctx, artRect);
        CGContextRestoreGState(ctx);
        CGPathRelease(clip);

        if (_item.contextURI.length) {
            NSRect pRect = [self playButtonRect];
            NSColor *playBg = _playHovered ? SPAccentHoverColor() : SPAccentColor();
            CGContextSetFillColorWithColor(ctx, playBg.CGColor);
            CGContextFillEllipseInRect(ctx, pRect);

            NSRect iconRect = NSInsetRect(pRect, 8.0, 8.0);
            iconRect.origin.x += 1.0;
            SPDrawIconSemantic(SPIconPlay, iconRect, 13.0, NSFontWeightSemibold, NSColor.whiteColor);
        }
    }

    // Title + Subtitle matching Spotifly AlbumCard / PlaylistCard / ArtistCard
    CGFloat textY = NSMaxY(artRect) + 8.0;
    CGFloat textW = self.bounds.size.width;
    NSTextAlignment align = _item.circular ? NSTextAlignmentCenter : NSTextAlignmentLeft;
    NSDictionary *titleAttrs = SPSemanticTextAttributes(typo->headline, SPLabelColor(), NSLineBreakByTruncatingTail, align);
    [_item.title drawInRect:NSMakeRect(0.0, textY, textW, 18.0) withAttributes:titleAttrs];

    if (!_item.circular && _item.subtitle.length) {
        NSDictionary *subAttrs = SPSemanticTextAttributes(typo->callout, SPSecondaryLabelColor(), NSLineBreakByTruncatingTail, NSTextAlignmentLeft);
        [_item.subtitle drawInRect:NSMakeRect(0.0, textY + 19.0, textW, 16.0) withAttributes:subAttrs];
    }
}

@end

#pragma mark - SPCardGridView

@interface SPCardGridDocumentView : NSView
@end

@implementation SPCardGridDocumentView
- (BOOL)isFlipped { return YES; }
@end

@interface SPGridScrollView : NSScrollView
@property (nonatomic, weak) SPCardGridView *gridOwner;
@end

@implementation SPGridScrollView
- (void)scrollWheel:(NSEvent *)event {
    if (_gridOwner && !_gridOwner.scrollingEnabled) {
        [self.nextResponder scrollWheel:event];
        return;
    }
    [super scrollWheel:event];
}
@end

@implementation SPCardGridView {
    SPGridScrollView *_scroll;
    SPCardGridDocumentView *_document;
    NSArray<SPCardItem *> *_items;
    NSUInteger _columns;
    NSMutableDictionary<NSNumber *, SPCardCellView *> *_visible;
    NSMutableArray<SPCardCellView *> *_pool;
    NSUInteger _hoveredIndex;
    BOOL _playHovered;
    NSTrackingArea *_tracking;
    BOOL _pointerInside;
    CGFloat _lastWidth;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    const SPLayoutMetrics *m = SPThemeMetrics();
    _items = @[];
    _cardWidth = m->cardWidth;
    _cardHeight = m->cardWidth + 46.0;
    _cardGap = m->cardGap;
    _horizontalPadding = m->pageInset;
    _topPadding = 8.0;
    _bottomPadding = m->nowPlayingContentClearance;
    _scrollingEnabled = YES;
    _columns = 1;
    _hoveredIndex = NSNotFound;
    _visible = [NSMutableDictionary new];
    _pool = [NSMutableArray new];

    _scroll = [[SPGridScrollView alloc] initWithFrame:self.bounds];
    _scroll.gridOwner = self;
    _scroll.drawsBackground = NO;
    _scroll.hasVerticalScroller = YES;
    _scroll.scrollerStyle = NSScrollerStyleOverlay;
    _scroll.autohidesScrollers = YES;
    _scroll.contentView.postsBoundsChangedNotifications = YES;

    _document = [[SPCardGridDocumentView alloc] initWithFrame:self.bounds];
    _scroll.documentView = _document;
    [self addSubview:_scroll];

    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(scrolled:)
                                               name:NSViewBoundsDidChangeNotification
                                             object:_scroll.contentView];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (BOOL)isFlipped { return YES; }
- (NSScrollView *)scrollView { return _scroll; }
- (NSArray<SPCardItem *> *)items { return _items; }
- (NSUInteger)columnCount { return _columns; }
- (NSUInteger)visibleCellCount { return _visible.count; }

- (void)setItems:(NSArray<SPCardItem *> *)items {
    _items = [items copy] ?: @[];
    _hoveredIndex = NSNotFound;
    _playHovered = NO;
    for (NSNumber *k in _visible.allKeys) [self recycleIndex:k];
    [self relayoutGrid];
}

- (void)setScrollingEnabled:(BOOL)scrollingEnabled {
    _scrollingEnabled = scrollingEnabled;
    _scroll.hasVerticalScroller = scrollingEnabled;
    _scroll.verticalScrollElasticity = scrollingEnabled ? NSScrollElasticityAutomatic : NSScrollElasticityNone;
}

- (CGFloat)contentHeightForWidth:(CGFloat)width {
    CGFloat avail = MAX(0, width - _horizontalPadding * 2.0);
    NSUInteger cols = (NSUInteger)MAX(1.0, floor((avail + _cardGap) / (_cardWidth + _cardGap)));
    CGFloat cellW = _cardWidth;
    if (cols > 0 && avail > 0) {
        CGFloat w = floor((avail - _cardGap * (CGFloat)(cols - 1)) / (CGFloat)cols);
        cellW = MIN(_cardWidth + 32.0, MAX(120.0, w));
    }
    CGFloat cellH = cellW + 46.0;
    NSUInteger rows = (_items.count + cols - 1) / cols;
    CGFloat totalH = _topPadding + _bottomPadding;
    if (rows > 0) {
        totalH += (CGFloat)rows * cellH + (CGFloat)(rows - 1) * 18.0;
    }
    return totalH;
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (!self.window) {
        for (SPCardCellView *c in _visible.allValues) SPReleaseViewImages(c);
        for (SPCardCellView *c in _pool) SPReleaseViewImages(c);
    } else {
        [self relayoutGrid];
    }
}

- (void)layout {
    [super layout];
    _scroll.frame = self.bounds;
    if (fabs(self.bounds.size.width - _lastWidth) > 0.5 || _visible.count == 0) {
        _lastWidth = self.bounds.size.width;
        [self relayoutGrid];
    } else {
        [self placeVisibleCells];
    }
}

- (void)scrolled:(NSNotification *)note {
    (void)note;
    [self placeVisibleCells];
}

- (void)scrollToY:(CGFloat)y {
    CGFloat maxY = MAX(0.0, _document.frame.size.height - _scroll.contentView.bounds.size.height);
    [_scroll.contentView scrollToPoint:NSMakePoint(0.0, MIN(MAX(0.0, y), maxY))];
    [_scroll reflectScrolledClipView:_scroll.contentView];
    [self placeVisibleCells];
}

- (void)computeGridMetricsForWidth:(CGFloat)width colsOut:(NSUInteger *)colsOut cellWOut:(CGFloat *)cellWOut cellHOut:(CGFloat *)cellHOut {
    CGFloat avail = MAX(0, width - _horizontalPadding * 2.0);
    NSUInteger cols = (NSUInteger)MAX(1.0, floor((avail + _cardGap) / (_cardWidth + _cardGap)));
    CGFloat cellW = _cardWidth;
    if (cols > 0 && avail > 0) {
        CGFloat w = floor((avail - _cardGap * (CGFloat)(cols - 1)) / (CGFloat)cols);
        cellW = MIN(_cardWidth + 32.0, MAX(120.0, w));
    }
    *colsOut = cols;
    *cellWOut = cellW;
    *cellHOut = cellW + 46.0;
}

- (void)relayoutGrid {
    CGFloat width = MAX(100.0, _scroll.contentView.bounds.size.width ?: self.bounds.size.width);
    NSUInteger cols = 1;
    CGFloat cellW = _cardWidth;
    CGFloat cellH = _cardHeight;
    [self computeGridMetricsForWidth:width colsOut:&cols cellWOut:&cellW cellHOut:&cellH];
    _columns = cols;

    CGFloat rowGap = 18.0;
    NSUInteger rows = (_items.count + cols - 1) / cols;
    CGFloat totalH = _topPadding + _bottomPadding;
    if (rows > 0) {
        totalH += (CGFloat)rows * cellH + (CGFloat)(rows - 1) * rowGap;
    }
    _document.frame = NSMakeRect(0.0, 0.0, width, MAX(totalH, self.bounds.size.height));

    for (NSNumber *key in _visible) {
        NSUInteger idx = key.unsignedIntegerValue;
        NSUInteger r = idx / cols;
        NSUInteger c = idx % cols;
        CGFloat x = _horizontalPadding + (CGFloat)c * (cellW + _cardGap);
        CGFloat y = _topPadding + (CGFloat)r * (cellH + rowGap);
        _visible[key].frame = NSMakeRect(x, y, cellW, cellH);
    }
    [self placeVisibleCells];
}

- (void)recycleIndex:(NSNumber *)key {
    SPCardCellView *cell = _visible[key];
    if (!cell) return;
    [_visible removeObjectForKey:key];
    SPReleaseViewImages(cell);
    [cell prepareForReuse];
    cell.hidden = YES;
    if (_pool.count < 48) {
        [_pool addObject:cell];
    } else {
        [cell removeFromSuperview];
    }
}

- (SPCardCellView *)dequeueCell {
    SPCardCellView *cell = _pool.lastObject;
    if (cell) {
        [_pool removeLastObject];
        cell.hidden = NO;
        return cell;
    }
    cell = [[SPCardCellView alloc] initWithFrame:NSZeroRect];
    [_document addSubview:cell];
    return cell;
}

- (void)placeVisibleCells {
    if (_items.count == 0) {
        for (NSNumber *k in _visible.allKeys) [self recycleIndex:k];
        return;
    }
    CGFloat width = MAX(100.0, _scroll.contentView.bounds.size.width ?: self.bounds.size.width);
    NSUInteger cols = 1;
    CGFloat cellW = _cardWidth;
    CGFloat cellH = _cardHeight;
    [self computeGridMetricsForWidth:width colsOut:&cols cellWOut:&cellW cellHOut:&cellH];
    _columns = cols;

    CGFloat rowGap = 18.0;
    NSRect vis = _scroll.contentView.documentVisibleRect;
    if (vis.size.height <= 0.0) vis = NSMakeRect(0, 0, width, MAX(400.0, self.bounds.size.height));
    CGFloat minY = MAX(0.0, vis.origin.y - cellH);
    CGFloat maxY = vis.origin.y + vis.size.height + cellH;

    CGFloat stepY = cellH + rowGap;
    NSUInteger firstRow = (minY > _topPadding) ? (NSUInteger)floor((minY - _topPadding) / stepY) : 0;
    NSUInteger lastRow = (maxY > _topPadding) ? (NSUInteger)floor((maxY - _topPadding) / stepY) : 0;
    NSUInteger firstIdx = MIN(_items.count, firstRow * cols);
    NSUInteger lastIdx = MIN(_items.count, (lastRow + 1) * cols);

    for (NSNumber *k in _visible.allKeys) {
        NSUInteger idx = k.unsignedIntegerValue;
        if (idx < firstIdx || idx >= lastIdx) {
            [self recycleIndex:k];
        }
    }

    for (NSUInteger idx = firstIdx; idx < lastIdx; idx++) {
        NSNumber *k = @(idx);
        SPCardCellView *cell = _visible[k];
        if (!cell) {
            cell = [self dequeueCell];
            _visible[k] = cell;
        }
        NSUInteger r = idx / cols;
        NSUInteger c = idx % cols;
        CGFloat x = _horizontalPadding + (CGFloat)c * (cellW + _cardGap);
        CGFloat y = _topPadding + (CGFloat)r * stepY;
        cell.frame = NSMakeRect(x, y, cellW, cellH);
        cell.item = _items[idx];
        cell.hovered = (idx == _hoveredIndex);
        cell.playHovered = (idx == _hoveredIndex && _playHovered);
    }
}

#pragma mark - Hover & Click

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_tracking) [self removeTrackingArea:_tracking];
    _tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect
                                             options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited |
                                                     NSTrackingActiveAlways | NSTrackingInVisibleRect
                                               owner:self
                                            userInfo:nil];
    [self addTrackingArea:_tracking];
}

- (NSUInteger)indexAtDocumentPoint:(NSPoint)pt cellOut:(SPCardCellView **)cellOut {
    for (NSNumber *k in _visible) {
        SPCardCellView *c = _visible[k];
        if (NSPointInRect(pt, c.frame)) {
            if (cellOut) *cellOut = c;
            return k.unsignedIntegerValue;
        }
    }
    return NSNotFound;
}

- (void)updateHoverForWindowPoint:(NSPoint)winPt {
    NSPoint docPt = [_document convertPoint:winPt fromView:nil];
    SPCardCellView *hitCell = nil;
    NSUInteger idx = [self indexAtDocumentPoint:docPt cellOut:&hitCell];
    BOOL overPlay = NO;
    if (hitCell) {
        NSPoint cellPt = NSMakePoint(docPt.x - hitCell.frame.origin.x, docPt.y - hitCell.frame.origin.y);
        overPlay = NSPointInRect(cellPt, hitCell.playButtonRect);
    }
    if (idx == _hoveredIndex && overPlay == _playHovered) return;
    if (_hoveredIndex != NSNotFound) {
        SPCardCellView *prev = _visible[@(_hoveredIndex)];
        prev.hovered = NO;
        prev.playHovered = NO;
    }
    _hoveredIndex = idx;
    _playHovered = overPlay;
    if (hitCell) {
        hitCell.hovered = YES;
        hitCell.playHovered = overPlay;
    }
}

- (void)mouseEntered:(NSEvent *)event { _pointerInside = YES; [self updateHoverForWindowPoint:event.locationInWindow]; }
- (void)mouseMoved:(NSEvent *)event { [self updateHoverForWindowPoint:event.locationInWindow]; }
- (void)mouseExited:(NSEvent *)event {
    (void)event;
    _pointerInside = NO;
    if (_hoveredIndex != NSNotFound) {
        SPCardCellView *prev = _visible[@(_hoveredIndex)];
        prev.hovered = NO;
        prev.playHovered = NO;
    }
    _hoveredIndex = NSNotFound;
    _playHovered = NO;
}

- (void)mouseDown:(NSEvent *)event {
    if ([self.window.firstResponder isKindOfClass:NSText.class]) {
        [self.window makeFirstResponder:nil];
    }
    NSPoint docPt = [_document convertPoint:event.locationInWindow fromView:nil];
    SPCardCellView *hitCell = nil;
    NSUInteger idx = [self indexAtDocumentPoint:docPt cellOut:&hitCell];
    if (idx == NSNotFound || idx >= _items.count || !hitCell) return;

    SPCardItem *item = _items[idx];
    NSPoint cellPt = NSMakePoint(docPt.x - hitCell.frame.origin.x, docPt.y - hitCell.frame.origin.y);
    BOOL hitPlay = NSPointInRect(cellPt, hitCell.playButtonRect);
    if ((hitPlay || event.clickCount >= 2) && item.contextURI.length && _onPlayItem) {
        _onPlayItem(item);
    } else if (_onSelectItem) {
        _onSelectItem(item);
    }
}

@end

#pragma mark - SPCardShelfView

@interface SPShelfScrollView : NSScrollView
@end

@implementation SPShelfScrollView
- (void)scrollWheel:(NSEvent *)event {
    if (fabs(event.scrollingDeltaY) > fabs(event.scrollingDeltaX)) {
        [self.nextResponder scrollWheel:event];
        return;
    }
    [super scrollWheel:event];
}
@end

@interface SPShelfDocumentView : NSView
@end

@implementation SPShelfDocumentView
- (BOOL)isFlipped { return YES; }
@end

@interface SPShelfHeaderView : NSView
@property (nonatomic, copy) NSString *sectionTitle;
@property (nonatomic, copy, nullable) NSString *trailingActionTitle;
@property (nonatomic) BOOL trailingHovered;
@property (nonatomic, readonly) NSRect trailingActionRect;
@end

@implementation SPShelfHeaderView {
    NSRect _trailingActionRect;
}

- (BOOL)isFlipped { return YES; }
- (NSRect)trailingActionRect { return _trailingActionRect; }

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    const SPTypographyScale *typo = SPThemeTypography();
    const SPLayoutMetrics *m = SPThemeMetrics();
    CGFloat padX = m->pageInset;
    CGFloat w = self.bounds.size.width;

    _trailingActionRect = NSZeroRect;
    CGFloat titleRight = padX;
    if (_trailingActionTitle.length) {
        NSMutableDictionary *linkAttrs = [SPSemanticTextAttributes(typo->body, NSColor.linkColor, NSLineBreakByClipping, NSTextAlignmentRight) mutableCopy];
        if (_trailingHovered) linkAttrs[NSUnderlineStyleAttributeName] = @(NSUnderlineStyleSingle);
        NSSize sz = [_trailingActionTitle sizeWithAttributes:linkAttrs];
        CGFloat lw = ceil(sz.width + 6.0);
        _trailingActionRect = NSMakeRect(w - padX - lw, 20.0, lw, 20.0);
        [_trailingActionTitle drawInRect:_trailingActionRect withAttributes:linkAttrs];
        titleRight = padX + lw + 12.0;
    }

    if (_sectionTitle.length) {
        NSDictionary *attrs = SPSemanticTextAttributes(typo->title2, SPLabelColor(), NSLineBreakByTruncatingTail, NSTextAlignmentLeft);
        [_sectionTitle drawInRect:NSMakeRect(padX, 16.0, MAX(0, w - padX - titleRight), 24.0) withAttributes:attrs];
    }
}

@end

@implementation SPCardShelfView {
    SPShelfHeaderView *_header;
    SPShelfScrollView *_scroll;
    SPShelfDocumentView *_doc;
    NSMutableArray<SPCardCellView *> *_cells;
    NSTrackingArea *_tracking;
    NSUInteger _hoveredIdx;
    BOOL _playHovered;
}

+ (CGFloat)preferredHeight {
    return [self preferredHeightForArtSize:SPThemeMetrics()->cardArtSize circular:NO];
}

+ (CGFloat)preferredHeightForArtSize:(CGFloat)artSize circular:(BOOL)circular {
    // 16pt top + 24pt title + 8pt gap = 48pt header + artSize + caption (46pt or 30pt for circular) + 6pt bottom
    CGFloat captionH = circular ? 30.0 : 46.0;
    return 48.0 + artSize + captionH + 6.0;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _sectionTitle = @"";
    _cardArtSize = SPThemeMetrics()->cardArtSize;
    _items = @[];
    _cells = [NSMutableArray new];
    _hoveredIdx = NSNotFound;

    _header = [[SPShelfHeaderView alloc] initWithFrame:NSZeroRect];
    [self addSubview:_header];

    _scroll = [[SPShelfScrollView alloc] initWithFrame:NSZeroRect];
    _scroll.drawsBackground = NO;
    _scroll.hasVerticalScroller = NO;
    _scroll.hasHorizontalScroller = NO;
    _scroll.verticalScrollElasticity = NSScrollElasticityNone;
    _scroll.horizontalScrollElasticity = NSScrollElasticityAllowed;

    _doc = [[SPShelfDocumentView alloc] initWithFrame:NSZeroRect];
    _scroll.documentView = _doc;
    [self addSubview:_scroll];
    return self;
}

- (BOOL)isFlipped { return YES; }
- (NSScrollView *)scrollView { return _scroll; }

- (void)setSectionTitle:(NSString *)sectionTitle {
    _sectionTitle = [sectionTitle copy] ?: @"";
    _header.sectionTitle = _sectionTitle;
    _header.needsDisplay = YES;
}

- (void)setTrailingActionTitle:(NSString *)trailingActionTitle {
    _trailingActionTitle = [trailingActionTitle copy];
    _header.trailingActionTitle = _trailingActionTitle;
    _header.needsDisplay = YES;
}

- (void)setCardArtSize:(CGFloat)cardArtSize {
    if (fabs(_cardArtSize - cardArtSize) < 0.5) return;
    _cardArtSize = cardArtSize;
    [self rebuildCells];
}

- (void)setItems:(NSArray<SPCardItem *> *)items {
    _items = [items copy] ?: @[];
    _hoveredIdx = NSNotFound;
    _playHovered = NO;
    [_scroll.contentView scrollToPoint:NSZeroPoint];
    [self rebuildCells];
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (!self.window) {
        SPReleaseViewImages(self);
    }
}

- (void)rebuildCells {
    const SPLayoutMetrics *m = SPThemeMetrics();
    CGFloat padX = m->pageInset;
    CGFloat gap = m->cardGap;
    CGFloat cardW = _cardArtSize > 20.0 ? _cardArtSize : m->cardArtSize;
    BOOL allCircular = (_items.count > 0 && _items.firstObject.circular);
    CGFloat cardH = cardW + (allCircular ? 30.0 : 46.0);
    CGFloat y = 48.0;
    NSUInteger count = _items.count;

    _header.frame = NSMakeRect(0.0, 0.0, self.bounds.size.width, 46.0);
    _scroll.frame = NSMakeRect(0.0, y, self.bounds.size.width, MAX(0.0, self.bounds.size.height - y));
    CGFloat docW = count > 0 ? (padX * 2.0 + (CGFloat)count * cardW + (CGFloat)(count - 1) * gap) : self.bounds.size.width;
    _doc.frame = NSMakeRect(0.0, 0.0, MAX(docW, self.bounds.size.width), cardH);

    // Reuse small per-card SPCardCellViews (avoids macOS 27 CA Whippet GPU promotion on wide single views).
    while (_cells.count > count) {
        SPCardCellView *extra = _cells.lastObject;
        SPReleaseViewImages(extra);
        [extra removeFromSuperview];
        [_cells removeLastObject];
    }
    while (_cells.count < count) {
        SPCardCellView *cell = [[SPCardCellView alloc] initWithFrame:NSZeroRect];
        [_doc addSubview:cell];
        [_cells addObject:cell];
    }
    for (NSUInteger i = 0; i < count; i++) {
        SPCardCellView *cell = _cells[i];
        cell.frame = NSMakeRect(padX + (CGFloat)i * (cardW + gap), 0.0, cardW, cardH);
        cell.item = _items[i];
        cell.hovered = (i == _hoveredIdx);
        cell.playHovered = (i == _hoveredIdx && _playHovered);
    }
}

- (void)layout {
    [super layout];
    [self rebuildCells];
}

- (NSUInteger)itemIndexAtDocPoint:(NSPoint)docPt playHitOut:(BOOL *)playHitOut {
    const SPLayoutMetrics *m = SPThemeMetrics();
    CGFloat padX = m->pageInset;
    CGFloat gap = m->cardGap;
    CGFloat cardW = _cardArtSize > 20.0 ? _cardArtSize : m->cardArtSize;
    CGFloat stride = cardW + gap;
    if (docPt.x < padX || _items.count == 0) return NSNotFound;
    NSInteger idx = (NSInteger)floor((docPt.x - padX) / stride);
    if (idx < 0 || idx >= (NSInteger)_cells.count) return NSNotFound;
    SPCardCellView *cell = _cells[(NSUInteger)idx];
    if (!NSPointInRect(docPt, cell.frame)) return NSNotFound;
    if (playHitOut) {
        NSPoint localCell = NSMakePoint(docPt.x - cell.frame.origin.x, docPt.y - cell.frame.origin.y);
        *playHitOut = NSPointInRect(localCell, [cell playButtonRect]);
    }
    return (NSUInteger)idx;
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_tracking) [self removeTrackingArea:_tracking];
    _tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect
                                             options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited |
                                                     NSTrackingActiveAlways | NSTrackingInVisibleRect
                                               owner:self
                                            userInfo:nil];
    [self addTrackingArea:_tracking];
}

- (void)setHoveredIndex:(NSUInteger)idx playHovered:(BOOL)playHovered {
    if (idx == _hoveredIdx && playHovered == _playHovered) return;
    NSUInteger oldIdx = _hoveredIdx;
    _hoveredIdx = idx;
    _playHovered = playHovered;
    if (oldIdx < _cells.count) {
        _cells[oldIdx].hovered = NO;
        _cells[oldIdx].playHovered = NO;
    }
    if (idx < _cells.count) {
        _cells[idx].hovered = YES;
        _cells[idx].playHovered = playHovered;
    }
}

- (void)updateHoverAtWindowPoint:(NSPoint)winPt {
    NSPoint localSelf = [self convertPoint:winPt fromView:nil];
    BOOL overTrailing = !NSIsEmptyRect(_header.trailingActionRect) && NSPointInRect(localSelf, _header.trailingActionRect);
    if (overTrailing != _header.trailingHovered) {
        _header.trailingHovered = overTrailing;
        _header.needsDisplay = YES;
    }

    if (!NSPointInRect(localSelf, _scroll.frame)) {
        [self setHoveredIndex:NSNotFound playHovered:NO];
        return;
    }
    NSPoint docPt = [_doc convertPoint:winPt fromView:nil];
    BOOL overPlay = NO;
    NSUInteger found = [self itemIndexAtDocPoint:docPt playHitOut:&overPlay];
    [self setHoveredIndex:found playHovered:overPlay];
}

- (void)mouseEntered:(NSEvent *)event { [self updateHoverAtWindowPoint:event.locationInWindow]; }
- (void)mouseMoved:(NSEvent *)event { [self updateHoverAtWindowPoint:event.locationInWindow]; }
- (void)mouseExited:(NSEvent *)event {
    (void)event;
    if (_header.trailingHovered) { _header.trailingHovered = NO; _header.needsDisplay = YES; }
    [self setHoveredIndex:NSNotFound playHovered:NO];
}

- (void)mouseDown:(NSEvent *)event {
    if ([self.window.firstResponder isKindOfClass:NSText.class]) {
        [self.window makeFirstResponder:nil];
    }
    NSPoint localSelf = [self convertPoint:event.locationInWindow fromView:nil];
    if (!NSIsEmptyRect(_header.trailingActionRect) && NSPointInRect(localSelf, _header.trailingActionRect) && _onTrailingAction) {
        _onTrailingAction();
        return;
    }
    if (!NSPointInRect(localSelf, _scroll.frame)) return;
    NSPoint docPt = [_doc convertPoint:event.locationInWindow fromView:nil];
    BOOL hitPlay = NO;
    NSUInteger idx = [self itemIndexAtDocPoint:docPt playHitOut:&hitPlay];
    if (idx == NSNotFound || idx >= _items.count) return;
    SPCardItem *item = _items[idx];
    if ((hitPlay || event.clickCount >= 2) && item.contextURI.length && _onPlayItem) {
        _onPlayItem(item);
    } else if (_onSelectItem) {
        _onSelectItem(item);
    }
}

@end
