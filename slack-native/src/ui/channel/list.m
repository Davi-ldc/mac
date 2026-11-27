// Owns the list's items, their cached layouts, tiling, keeping the reader's place, paging, read
// marks, hover, the action bar and the overlays (sticky date pill, unread line, jump button).
#import "render/format.h"
#import "render/icon.h"
#import "render/message.h"
#import "render/strings.h"
#import "ui/channel/list.h"
#import "ui/emoji/picker.h"
#import "ui/kit/dialog.h"
#import "ui/kit/label.h"
#import "ui/kit/popover.h"
#import "ui/present/message.h"

/// A date divider row (measured): 41 pt with the 1 pt #35373b line 20 pt down and the 28 pt pill
/// (ring included 30) centred on it.
static const CGFloat kDayHeight = 41, kDayLine = 20, kPillTop = 6, kPillHeight = 28;
/// The pill: 13 pt bold #d1d2d3, 16 pt in, a caret 4 pt after the text, 8 pt after the caret.
static const CGFloat kPillPadLeft = 16, kPillCaretGap = 4, kPillCaret = 13, kPillPadRight = 8;
/// The thread pane's line under the parent: "17 respostas" and a rule.
static const CGFloat kRepliesHeight = 34;
/// The jump-to-latest button (components.json unread_banner_and_jump): 36 pt, 24 pt from the
/// bottom and 16 from the right; in over 120 ms (opacity, scale 0.9 -> 1), out over 80.
static const CGFloat kJumpSize = 36, kJumpBottom = 24, kJumpRight = 16;
static const SNColorToken kUnreadRed = 0xe01e5aff;
/// Rows drawn beyond the visible part on each side, so a slow scroll finds them ready.
static const CGFloat kOverscan = 120;
static const CGFloat kMoreMenuOverlap = 7.5, kMoreMenuRise = 16.5;
/// Layouts are kept for the conversation (or thread) shown and the last few shown before it, so
/// switching back lays nothing out; within one, only for the messages it still shows.
static const NSUInteger kCachedConversations = 4;
/// Rows at the top of the view remembered to keep the reader's place, in case the first goes.
static const NSUInteger kPlaceCandidates = 8;
/// More changed messages than this at once (a page, a refetch) show the conversation anew.
static const NSUInteger kChangesInPlace = 16;
/// The spinner above the history while a page loads (effects.txt [B19]): #818385, fading in
/// over 0.2 s linear once the load has taken 0.4 s; a 20 pt ring turning once a second.
static const CGFloat kLoadingHeight = 48, kSpinnerSize = 20;
static const NSTimeInterval kSpinnerDelay = 0.4, kSpinnerFade = 0.2, kSpinnerTurn = 1;
static const SNColorToken kSpinnerColor = SNLegacyForegroundHighSolid;

typedef NS_ENUM(NSInteger, SNItemKind) { SNItemMessage, SNItemDay, SNItemReplies, SNItemLoading };

/// A row of the list. Messages are keyed by SNMessage.identifier, which a pending send keeps
/// when Slack gives it its ts.
@interface SNListItem : NSObject {
  @public
    SNItemKind kind;
    SNMessage *message;
    BOOL continuation;
    SNMessageRowStyle style;
    NSString *key, *label;
    NSUInteger index;
    CGFloat top, height;
}
@end

@implementation SNListItem
@end

/// Where the reader is, to keep across a change: at the bottom, or the rows at the top of the view
/// and how far below its top each starts (the first that still exists stays put).
@interface SNListPlace : NSObject {
  @public
    BOOL bottom;
    NSMutableArray<NSString *> *keys;
    NSMutableArray<NSNumber *> *offsets;
}
@end

@implementation SNListPlace
@end

#pragma mark Date pill

static NSFont *PillFont(void) { return SNFont(SNFontSizeCaption, SNFontWeightBold); }

static CGFloat PillWidth(NSString *label) {
    return kPillPadLeft + ceil(SNTextWidth(label, PillFont())) + kPillCaretGap + kPillCaret + kPillPadRight;
}

/// The pill with its outer ring and shadow (components.json date_divider), body at `rect`.
static void DrawPill(NSString *label, NSRect rect) {
    NSBezierPath *ring = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(rect, -1, -1) xRadius:rect.size.height / 2 + 1 yRadius:rect.size.height / 2 + 1];
    [SNColor(SNColorOver(0xe8e8e821, SNColorBasePry)) setFill];
    [ring fill];
    [SNColor(SNColorBasePry) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:rect xRadius:rect.size.height / 2 yRadius:rect.size.height / 2] fill];
    CGFloat textWidth = rect.size.width - kPillPadLeft - kPillCaretGap - kPillCaret - kPillPadRight;
    SNDrawText(label, PillFont(), SNLegacyPrimaryForeground, rect.size.height, NSTextAlignmentLeft, 1, NSMakeRect(NSMinX(rect) + kPillPadLeft, NSMinY(rect), textWidth, rect.size.height));
    // The caret has no size of its own: it takes the pill's font size.
    SNDrawIcon(@"caret-down", kPillCaret, SNLegacyPrimaryForeground, NSMakeRect(NSMaxX(rect) - kPillPadRight - kPillCaret, NSMidY(rect) - kPillCaret / 2, kPillCaret, kPillCaret));
}

@interface SNDayDividerView : NSView
@property (nonatomic, copy) NSString *label;
/// The pinned copy at the top of the list draws only the pill.
@property (nonatomic) BOOL pillOnly;
@end

@implementation SNDayDividerView {
    CGFloat _pillWidth;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    return self;
}

- (BOOL)isFlipped { return YES; }
- (NSView *)hitTest:(NSPoint)point { return nil; }

- (void)setLabel:(NSString *)label {
    if ([label isEqualToString:_label]) return;
    _label = [label copy];
    _pillWidth = label ? PillWidth(label) : 0;
    self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    if (!self.label) return;
    CGFloat width = _pillWidth;
    if (!self.pillOnly) {
        [SNColor(SNLegacyForegroundLowSolid) setFill];
        NSRectFill(NSMakeRect(0, kDayLine, self.bounds.size.width, 1));
    }
    // Centred in the pane's content box, which starts 1 pt in (message_pane padding-left 1px).
    DrawPill(self.label, NSMakeRect(round(self.bounds.size.width + 1 - width) / 2, kPillTop, width, kPillHeight));
}

@end

/// The red "Novo" line above the first unread message: the label sits on the line at the right.
@interface SNNewDividerView : NSView
@end

@implementation SNNewDividerView {
    NSString *_label;
    CGFloat _labelWidth;
}

- (BOOL)isFlipped { return YES; }
- (NSView *)hitTest:(NSPoint)point { return nil; }

- (void)drawRect:(NSRect)dirtyRect {
    NSString *label = SNLocalized(@"channel.new");
    NSFont *font = SNFont(SNFontSizeCaption, SNFontWeightBold);
    if (![label isEqualToString:_label]) {
        _label = label;
        _labelWidth = ceil(SNTextWidth(label, font)) + 8;
    }
    CGFloat labelWidth = _labelWidth;
    CGFloat right = self.bounds.size.width - 15;
    [SNColor(kUnreadRed) setFill];
    NSRectFill(NSMakeRect(0, 10, right - labelWidth, 1));
    SNDrawText(label, font, kUnreadRed, 19, NSTextAlignmentCenter, 1, NSMakeRect(right - labelWidth, 0.5, labelWidth, 19));
}

@end

/// The thread pane's "17 respostas" and the rule after it.
@interface SNRepliesDividerView : NSView
@property (nonatomic, copy) NSString *label;
@end

@implementation SNRepliesDividerView {
    CGFloat _labelWidth;
}

- (BOOL)isFlipped { return YES; }
- (NSView *)hitTest:(NSPoint)point { return nil; }

- (void)setLabel:(NSString *)label {
    if ([label isEqualToString:_label]) return;
    _label = [label copy];
    _labelWidth = ceil(SNTextWidth(label, SNFont(SNFontSizeCaption, SNFontWeightRegular)));
    self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    NSFont *font = SNFont(SNFontSizeCaption, SNFontWeightRegular);
    CGFloat width = _labelWidth;
    SNDrawText(self.label, font, SNLegacyForegroundMaxSolid, kRepliesHeight, NSTextAlignmentLeft, 1, NSMakeRect(SNMessageGutter, 0, width, kRepliesHeight));
    [SNColor(SNLegacyForegroundLowSolid) setFill];
    NSRectFill(NSMakeRect(SNMessageGutter + width + 12, kRepliesHeight / 2, MAX(0, self.bounds.size.width - SNMessageGutter * 2 - width - 12), 1));
}

@end

@interface SNLoadingView : NSView
@end

@implementation SNLoadingView

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.wantsLayer = YES;
    SNLayer *ring = [SNLayer layer];
    ring.bounds = CGRectMake(0, 0, kSpinnerSize, kSpinnerSize);
    // Three quarters of a circle, drawn once; the layer turns.
    CGFloat scale = 2;
    NSImage *image = [NSImage imageWithSize:NSMakeSize(kSpinnerSize, kSpinnerSize) flipped:NO drawingHandler:^BOOL(NSRect rect) {
        NSBezierPath *arc = [NSBezierPath bezierPath];
        [arc appendBezierPathWithArcWithCenter:NSMakePoint(kSpinnerSize / 2, kSpinnerSize / 2) radius:kSpinnerSize / 2 - 1.5 startAngle:90 endAngle:360];
        arc.lineWidth = 2;
        arc.lineCapStyle = NSLineCapStyleRound;
        [SNColor(kSpinnerColor) setStroke];
        [arc stroke];
        return YES;
    }];
    ring.contents = [image layerContentsForContentsScale:scale];
    ring.contentsScale = scale;
    ring.opacity = 0;
    CABasicAnimation *turn = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
    turn.fromValue = @0;
    turn.toValue = @(-2 * M_PI);
    turn.duration = kSpinnerTurn;
    turn.repeatCount = HUGE_VALF;
    [ring addAnimation:turn forKey:@"turn"];
    [self.layer addSublayer:ring];
    __weak SNLayer *weakRing = ring;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSpinnerDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SNAnimate(kSpinnerFade, [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear], ^{ weakRing.opacity = 1; });
    });
    return self;
}

- (BOOL)isFlipped { return YES; }
- (NSView *)hitTest:(NSPoint)point { return nil; }

- (void)layout {
    [super layout];
    CALayer *ring = self.layer.sublayers.firstObject;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    ring.position = CGPointMake(NSMidX(self.bounds), NSMidY(self.bounds));
    [CATransaction commit];
}

@end

@interface SNJumpButton : SNHoverView
@end

@implementation SNJumpButton

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.overlayRadius = kJumpSize / 2;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;
    self.tooltip = SNLocalized(@"channel.jump");
    // components.json: shadow md under a base-pry circle.
    self.layer.shadowColor = CGColorGetConstantColor(kCGColorBlack);
    self.layer.shadowOpacity = 0.1;
    self.layer.shadowRadius = 3;
    self.layer.shadowOffset = CGSizeMake(0, -3);
    self.layer.shadowPath = CFAutorelease(CGPathCreateWithEllipseInRect(CGRectMake(0, 0, kJumpSize, kJumpSize), NULL));
    return self;
}

- (void)drawRect:(NSRect)dirtyRect {
    [SNColor(SNColorBasePry) setFill];
    [[NSBezierPath bezierPathWithOvalInRect:self.bounds] fill];
    [SNColor(SNColorOtlTer) setStroke];
    [[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(self.bounds, 0.5, 0.5)] stroke];
    SNDrawIcon(@"arrow-down", 16, SNColorContentPry, self.bounds);
}

@end

/// The message in the delete confirmation: a 1 pt rounded border around its row (scrollable when tall).
@interface SNMessagePreview : NSView
@property (nonatomic, nullable) NSScrollView *scrollView;
@end

@implementation SNMessagePreview

- (BOOL)isFlipped { return YES; }

- (void)layout {
    [super layout];
    if (self.scrollView) self.scrollView.frame = NSInsetRect(self.bounds, 1, 1);
}

- (void)drawRect:(NSRect)dirtyRect {
    NSBezierPath *border = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 0.5, 0.5) xRadius:SNRadiusLarge yRadius:SNRadiusLarge];
    [SNColor(SNColorOtlTer) setStroke];
    [border stroke];
}

@end

@interface SNMessageListDocumentView : NSView
@end

@implementation SNMessageListDocumentView
- (BOOL)isFlipped { return YES; }
@end

#pragma mark List

@interface SNMessageListView () <SNMessageRowDelegate>
@end

static BOOL SameID(NSString *a, NSString *b) { return a == b || [a isEqualToString:b]; }

/// Conversations and threads the reader marked unread (from either column): no list marks them
/// read again until one shows them anew.
static NSMutableSet<NSString *> *heldReads;

@implementation SNMessageListView {
    SNMessageListMode _mode;
    SNRenderer *_renderer;
    NSScrollView *_scroll;
    SNMessageListDocumentView *_document;
    /// What is shown, oldest first: the source's run, then kept in step with its changes.
    NSMutableArray<SNMessage *> *_messages;
    NSMutableArray<SNListItem *> *_items;
    NSMutableDictionary<NSString *, SNListItem *> *_itemsByKey;
    /// Layouts by conversation (or thread key) and message identifier, the shown one first in
    /// _layoutOrder; _layouts is the shown one's.
    NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, SNMessageLayout *> *> *_layoutSets;
    NSMutableArray<NSString *> *_layoutOrder;
    NSMutableDictionary<NSString *, SNMessageLayout *> *_layouts;
    NSMutableDictionary<NSString *, NSView *> *_visible;
    NSMutableArray<SNMessageRowView *> *_rowPool;
    NSMutableArray<SNDayDividerView *> *_dayPool;
    NSString *_lastRead, *_hoveredKey, *_editingKey, *_markedTS;
    NSString *_pendingJumpTS, *_pendingJumpConversationID, *_pendingJumpThreadTS, *_jumpHighlightTS;
    NSUInteger _jumpHighlightGeneration;
    SNDayDividerView *_pinned;
    SNNewDividerView *_newDivider;
    SNJumpButton *_jump;
    NSTrackingArea *_tracking;
    CGFloat _laidWidth, _content, _lastScrollY;
    /// Set by -relayout: the views in view may show outdated layouts until the next -tile; after
    /// a change in place, only the rows of these keys do.
    BOOL _viewsStale;
    NSMutableSet<NSString *> *_staleKeys;
    BOOL _holdHover, _olderArmed, _newerArmed, _jumpShown, _keepingPlace, _jumpToLatestPending;
}

@synthesize editor = _editor;

- (instancetype)initWithSource:(id<SNSource>)source mode:(SNMessageListMode)mode {
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, 800, 600)])) return nil;
    _source = source;
    _mode = mode;
    _renderer = [[SNRenderer alloc] initWithSource:source];
    _items = [NSMutableArray new];
    _itemsByKey = [NSMutableDictionary new];
    _layoutSets = [NSMutableDictionary new];
    _layoutOrder = [NSMutableArray new];
    _layouts = [NSMutableDictionary new];
    _visible = [NSMutableDictionary new];
    _rowPool = [NSMutableArray new];
    _dayPool = [NSMutableArray new];
    _messages = [NSMutableArray new];
    _staleKeys = [NSMutableSet new];

    _scroll = [[NSScrollView alloc] initWithFrame:self.bounds];
    _scroll.drawsBackground = NO;
    _scroll.hasVerticalScroller = YES;
    _scroll.scrollerStyle = NSScrollerStyleOverlay;
    _scroll.scrollerKnobStyle = NSScrollerKnobStyleLight;
    _scroll.autohidesScrollers = YES;
    _scroll.contentView.postsBoundsChangedNotifications = YES;
    _document = [[SNMessageListDocumentView alloc] initWithFrame:self.bounds];
    _scroll.documentView = _document;
    [self addSubview:_scroll];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(scrolled:) name:NSViewBoundsDidChangeNotification object:_scroll.contentView];

    _newDivider = [[SNNewDividerView alloc] initWithFrame:NSZeroRect];
    _newDivider.hidden = YES;
    [_document addSubview:_newDivider];

    _actionBar = [[SNMessageActionBar alloc] initWithFrame:NSZeroRect];
    _actionBar.hidden = YES;
    __weak SNMessageListView *weakSelf = self;
    _actionBar.action = ^(SNMessageAction action, NSString *reaction, NSRect rect) { [weakSelf perform:action reaction:reaction rect:rect]; };
    [_document addSubview:_actionBar];

    _pinned = [[SNDayDividerView alloc] initWithFrame:NSZeroRect];
    _pinned.pillOnly = YES;
    _pinned.hidden = YES;
    [self addSubview:_pinned];

    _jump = [[SNJumpButton alloc] initWithFrame:NSMakeRect(0, 0, kJumpSize, kJumpSize)];
    _jump.alphaValue = 0;
    _jump.hidden = YES;
    _jump.action = ^(SNJumpButton *button) { [weakSelf jumpToLatest]; };
    [self addSubview:_jump];
    return self;
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

- (BOOL)isFlipped { return YES; }
- (NSScrollView *)scrollView { return _scroll; }
- (CGFloat)contentHeight { return _content; }
- (NSDate *)now { return _renderer.now; }

- (void)setNow:(NSDate *)now {
    _renderer.now = now;
    [self clearCache];
}

- (void)clearCache {
    for (NSMutableDictionary *layouts in _layoutSets.allValues) [layouts removeAllObjects];
    [_layouts removeAllObjects];
    [self relayoutKeepingPlace];
}

- (NSArray<NSString *> *)cachedLayoutKeys { return [_layoutOrder copy]; }

- (NSUInteger)cachedLayoutCount {
    NSUInteger count = 0;
    for (NSDictionary *layouts in _layoutSets.allValues) count += layouts.count;
    return count;
}

#pragma mark Items

- (void)showMessages:(NSArray<SNMessage *> *)messages inConversation:(NSString *)conversationID threadTS:(NSString *)threadTS lastRead:(NSString *)lastRead {
    BOOL switched = !SameID(conversationID, _conversationID) || !SameID(threadTS, _threadTS);
    SNListPlace *place = switched ? nil : [self currentPlace];
    if (switched) {
        _conversationID = [conversationID copy];
        _threadTS = [threadTS copy];
        [self hoverKey:nil];
        NSString *key = self.readKey;
        [self useLayoutsOf:key];
        if (key) [heldReads removeObject:key];
        _olderArmed = YES;
        _newerArmed = NO;
        _jumpToLatestPending = NO;
        _markedTS = nil;
        if (_pendingJumpTS && (!SameID(conversationID, _pendingJumpConversationID) || !SameID(threadTS, _pendingJumpThreadTS)))
            _pendingJumpTS = nil;
        _jumpHighlightTS = nil;
        _jumpHighlightGeneration++;
    }
    // A conversation shows no plain replies; a thread shows them all.
    _messages = _mode == SNMessageListChannel
                  ? [messages filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(SNMessage *message, NSDictionary *bindings) { return !message.isReply; }]].mutableCopy
                  : [messages mutableCopy];
    _lastRead = [lastRead copy];
    [self rebuildItems];
    // The message being edited went away (deleted, or another conversation).
    if (_editingKey && !_itemsByKey[_editingKey]) [self dropEditor];
    for (NSString *identifier in _layouts.allKeys)
        if (!_itemsByKey[identifier]) [_layouts removeObjectForKey:identifier];
    [self relayout];
    // The Preferences' "Start me where I left off" opens a conversation at its "Novo" line.
    SNListItem *unread = !place && SNPreferenceBool(self.source.preferences, @"start_scroll_at_oldest", NO) ? [self firstUnreadItem] : nil;
    if (_pendingJumpTS && [self landOnPendingJump]) {
        // Landed on the searched message.
    } else if (_jumpToLatestPending && (_mode != SNMessageListChannel || !_conversationID || ![self.source hasNewerMessagesInConversation:_conversationID])) {
        _jumpToLatestPending = NO;
        [self keepPlaceAt:CGFLOAT_MAX];
    } else if (place) {
        [self restorePlace:place];
    } else if (unread) {
        [self keepPlaceAt:[self newLineOf:unread] - 10];
    } else {
        [self keepPlaceAt:_mode == SNMessageListChannel ? CGFLOAT_MAX : 0];
    }
    [self markReadIfSeen];
}

- (void)useLayoutsOf:(NSString *)key {
    if (!key) {
        _layouts = [NSMutableDictionary new];
        return;
    }
    [_layoutOrder removeObject:key];
    [_layoutOrder insertObject:key atIndex:0];
    _layouts = _layoutSets[key] ?: (_layoutSets[key] = [NSMutableDictionary new]);
    while (_layoutOrder.count > kCachedConversations) {
        [_layoutSets removeObjectForKey:_layoutOrder.lastObject];
        [_layoutOrder removeLastObject];
    }
}

- (BOOL)applyChange:(SNChange *)change {
    for (NSString *key in change.messageKeys) {
        NSRange slash = [key rangeOfString:@"/"];
        if (slash.location == NSNotFound) continue;
        NSString *conversationID = [key substringToIndex:slash.location], *identifier = [key substringFromIndex:NSMaxRange(slash)];
        // Thread layouts are kept under "<conversation>/<thread ts>".
        for (NSString *set in _layoutOrder)
            if ([set hasPrefix:conversationID] && (set.length == conversationID.length || [set characterAtIndex:conversationID.length] == '/'))
                [_layoutSets[set] removeObjectForKey:identifier];
    }
    if (change.emoji)
        for (NSView *view in _visible.allValues)
            if ([view isKindOfClass:SNMessageRowView.class])
                for (NSView *pill in ((SNMessageRowView *)view).pills) pill.needsDisplay = YES;
    // A huddle's message says whether it is live and who is in it, from the huddle itself.
    BOOL huddles = NO;
    NSSet<NSString *> *changedHuddles = change.huddles;
    for (NSString *set in changedHuddles.count ? _layoutOrder : @[]) {
        if (![changedHuddles containsObject:[set componentsSeparatedByString:@"/"].firstObject]) continue;
        NSMutableDictionary<NSString *, SNMessageLayout *> *layouts = _layoutSets[set];
        for (NSString *identifier in layouts.allKeys)
            if (layouts[identifier].isHuddle) {
                [layouts removeObjectForKey:identifier];
                huddles = YES;
            }
    }
    [self retryReadMarkAfterChange:change];
    if (![_renderer isStaleAfterChange:change]) return huddles && _items.count > 0;
    for (NSMutableDictionary *layouts in _layoutSets.allValues) [layouts removeAllObjects];
    [_layouts removeAllObjects];
    return _items.count > 0;
}

/// While a page loads that will show above what is here (or is all there will be).
- (BOOL)showsLoading {
    return _mode == SNMessageListChannel && _conversationID && [self.source isLoadingMessagesInConversation:_conversationID] &&
           (!_messages.count || [self.source hasOlderMessagesInConversation:_conversationID]);
}

- (void)rebuildItems {
    [_items removeAllObjects];
    [_itemsByKey removeAllObjects];
    SNMessage *previous = nil;
    NSDate *now = self.now;
    void (^add)(SNListItem *) = ^(SNListItem *item) {
        item->index = self->_items.count;
        [self->_items addObject:item];
        self->_itemsByKey[item->key] = item;
    };
    if (self.showsLoading) {
        SNListItem *loading = [SNListItem new];
        loading->kind = SNItemLoading;
        loading->key = @"loading";
        loading->height = kLoadingHeight;
        add(loading);
    }
    for (SNMessage *message in _messages) {
        if (_mode == SNMessageListChannel && (!previous || !SNSameDay(previous.date, message.date))) {
            SNListItem *day = [SNListItem new];
            day->kind = SNItemDay;
            day->label = SNFormatDay(message.date, now);
            day->key = [@"day/" stringByAppendingString:message.identifier];
            day->height = kDayHeight;
            add(day);
            previous = nil;
        }
        SNListItem *item = [SNListItem new];
        item->kind = SNItemMessage;
        item->message = message;
        item->key = message.identifier;
        item->continuation = SNMessageGroupsWith(message, previous) && !(_mode == SNMessageListThread && _items.count == 0);
        item->style = _mode == SNMessageListChannel ? SNMessageRowInConversation : _items.count == 0 ? SNMessageRowThreadParent : SNMessageRowThreadReply;
        add(item);
        previous = message;
        if (_mode == SNMessageListThread && _items.count == 1 && message.replyCount > 0) {
            SNListItem *replies = [SNListItem new];
            replies->kind = SNItemReplies;
            replies->label = SNFormatReplyCount(message.replyCount);
            replies->key = @"replies";
            replies->height = kRepliesHeight;
            add(replies);
            previous = nil;
        }
    }
}

- (SNMessageLayout *)layoutFor:(SNListItem *)item {
    SNMessageLayout *layout = _layouts[item->key];
    if (layout && layout.width == _laidWidth && layout.continuation == item->continuation && layout.style == item->style) return layout;
    layout = [SNMessageLayout layoutForMessage:item->message continuation:item->continuation style:item->style width:_laidWidth renderer:_renderer];
    _layouts[item->key] = layout;
    return layout;
}

/// Heights from the cache (laying out only messages it lacks), then every item's top. The views
/// in view stay; -tile moves them and gives them their new layouts.
- (void)relayout {
    CGFloat width = self.bounds.size.width, viewport = _scroll.contentView.bounds.size.height;
    _laidWidth = width;
    CGFloat total = 0;
    for (SNListItem *item in _items) {
        if (item->kind == SNItemMessage)
            item->height = [item->key isEqualToString:_editingKey] ? [_editor heightForWidth:width] : [self layoutFor:item].height;
        total += item->height;
    }
    _content = total + self.bottomInset;
    // Bottom anchoring: a short history sits right above the composer; a thread starts at the top.
    CGFloat y = _mode == SNMessageListChannel ? MAX(0, viewport - _content) : 0;
    for (SNListItem *item in _items) {
        item->top = y;
        y += item->height;
    }
    NSSize size = NSMakeSize(width, MAX(viewport, _content));
    if (!NSEqualSizes(_document.frame.size, size)) [self keepingPlace:^{ [self->_document setFrameSize:size]; }];
    // The editor is never hidden or moved out of the document while editing (that would take the
    // keyboard from it), only placed, in view or not.
    SNListItem *editing = _editingKey ? _itemsByKey[_editingKey] : nil;
    if (editing) _editor.frame = NSMakeRect(0, editing->top, width, editing->height);
    _viewsStale = YES;
    [self placeNewDivider];
}

#pragma mark Changes in place

- (BOOL)showChangedMessages:(SNChange *)change {
    if (_mode != SNMessageListChannel || !_conversationID || _laidWidth != self.bounds.size.width || _pendingJumpTS || _jumpToLatestPending) return NO;
    NSString *prefix = [_conversationID stringByAppendingString:@"/"];
    NSMutableArray<NSString *> *identifiers = [NSMutableArray new];
    for (NSString *key in change.messageKeys)
        if ([key hasPrefix:prefix]) [identifiers addObject:[key substringFromIndex:prefix.length]];
    BOOL spinner = _items.count && _items.firstObject->kind == SNItemLoading;
    if (identifiers.count > kChangesInPlace || spinner != self.showsLoading || (_editingKey && [identifiers containsObject:_editingKey])) return NO;
    SNListPlace *place = [self currentPlace];
    NSUInteger from = NSNotFound;
    for (NSString *identifier in identifiers) from = MIN(from, [self changeMessage:identifier]);
    if (from == NSNotFound) return YES;
    [self relayoutFrom:from];
    [self restorePlace:place];
    [self markReadIfSeen];
    return YES;
}

/// Puts the source's message with `identifier` in place of the one shown, or inserts or removes
/// it; returns the first item it touched (NSNotFound: none).
- (NSUInteger)changeMessage:(NSString *)identifier {
    SNListItem *item = _itemsByKey[identifier];
    SNMessage *now = [self.source messageWithIdentifier:identifier inConversation:_conversationID];
    if (now.isReply) now = nil;
    if (!item && !now) return NSNotFound;
    if (item && now && [now.ts isEqualToString:item->message.ts]) {
        NSUInteger index = [self indexOfMessage:item->message];
        _messages[index] = now;
        item->message = now;
        [_staleKeys addObject:identifier];
        [self settleMessageAt:index];
        [self settleMessageAt:index + 1];
        return [self firstItemOfMessageAt:index];
    }
    NSUInteger from = NSNotFound;
    if (item) {
        NSUInteger index = [self indexOfMessage:item->message];
        [_messages removeObjectAtIndex:index];
        from = item->index > 0 && _items[item->index - 1]->kind == SNItemDay ? item->index - 1 : item->index;
        for (NSUInteger i = from; i <= item->index; i++) [_itemsByKey removeObjectForKey:_items[i]->key];
        [_items removeObjectsInRange:NSMakeRange(from, item->index - from + 1)];
        [self reindexFrom:from];
        [self settleMessageAt:index];
    }
    if (now) {
        NSUInteger index = [_messages indexOfObject:now inSortedRange:NSMakeRange(0, _messages.count)
                                            options:NSBinarySearchingInsertionIndex | NSBinarySearchingLastEqual
                                    usingComparator:^NSComparisonResult(SNMessage *a, SNMessage *b) { return SNCompareTS(a.ts, b.ts); }];
        NSUInteger at = index < _messages.count ? [self firstItemOfMessageAt:index] : _items.count;
        [_messages insertObject:now atIndex:index];
        SNListItem *added = [SNListItem new];
        added->kind = SNItemMessage;
        added->message = now;
        added->key = now.identifier;
        added->style = SNMessageRowInConversation;
        [_items insertObject:added atIndex:at];
        _itemsByKey[added->key] = added;
        [_staleKeys addObject:added->key];
        [self reindexFrom:at];
        [self settleMessageAt:index];
        [self settleMessageAt:index + 1];
        from = MIN(from, [self firstItemOfMessageAt:index]);
    }
    return from;
}

/// The position of `message` (shown) in _messages, which is sorted by ts.
- (NSUInteger)indexOfMessage:(SNMessage *)message {
    NSUInteger index = [_messages indexOfObject:message inSortedRange:NSMakeRange(0, _messages.count) options:NSBinarySearchingFirstEqual
                                usingComparator:^NSComparisonResult(SNMessage *a, SNMessage *b) { return SNCompareTS(a.ts, b.ts); }];
    return index != NSNotFound && _messages[index] == message ? index : [_messages indexOfObjectIdenticalTo:message];
}

/// The day divider opening the message's day, or the message's own item.
- (NSUInteger)firstItemOfMessageAt:(NSUInteger)index {
    NSUInteger item = _itemsByKey[_messages[index].identifier]->index;
    return item > 0 && _items[item - 1]->kind == SNItemDay ? item - 1 : item;
}

- (void)reindexFrom:(NSUInteger)from {
    for (NSUInteger i = from; i < _items.count; i++) _items[i]->index = i;
}

/// The message's day divider and grouping with the one before it, as -rebuildItems makes them.
- (void)settleMessageAt:(NSUInteger)index {
    if (index >= _messages.count) return;
    SNMessage *message = _messages[index], *previous = index ? _messages[index - 1] : nil;
    SNListItem *item = _itemsByKey[message.identifier];
    BOOL opensDay = !previous || !SNSameDay(previous.date, message.date);
    BOOL hasDay = item->index > 0 && _items[item->index - 1]->kind == SNItemDay;
    if (opensDay && !hasDay) {
        SNListItem *day = [SNListItem new];
        day->kind = SNItemDay;
        day->label = SNFormatDay(message.date, self.now);
        day->key = [@"day/" stringByAppendingString:message.identifier];
        day->height = kDayHeight;
        [_items insertObject:day atIndex:item->index];
        _itemsByKey[day->key] = day;
        [self reindexFrom:item->index];
    } else if (!opensDay && hasDay) {
        NSUInteger at = item->index - 1;
        [_itemsByKey removeObjectForKey:_items[at]->key];
        [_items removeObjectAtIndex:at];
        [self reindexFrom:at];
    }
    BOOL continuation = !opensDay && SNMessageGroupsWith(message, previous);
    if (continuation == item->continuation) return;
    item->continuation = continuation;
    [_staleKeys addObject:item->key];
}

/// Heights of the rows changed in place and every top from `from` on; the rest stays laid out.
- (void)relayoutFrom:(NSUInteger)from {
    CGFloat width = _laidWidth, viewport = _scroll.contentView.bounds.size.height;
    CGFloat y = from ? _items[from - 1]->top + _items[from - 1]->height : 0;
    for (NSUInteger i = from; i < _items.count; i++) {
        SNListItem *item = _items[i];
        if (item->kind == SNItemMessage && [_staleKeys containsObject:item->key]) item->height = [self layoutFor:item].height;
        item->top = y;
        y += item->height;
    }
    _content = y + self.bottomInset;
    // Short of a screen (or previously bottom-anchored) the history sits on the composer: every top moves.
    if (_content < viewport || (_items.count && _items.firstObject->top > 0)) return [self relayout];
    NSSize size = NSMakeSize(width, MAX(viewport, _content));
    if (!NSEqualSizes(_document.frame.size, size)) [self keepingPlace:^{ [self->_document setFrameSize:size]; }];
    [self placeNewDivider];
}

#pragma mark Keeping the place

- (SNListPlace *)currentPlace {
    SNListPlace *place = [SNListPlace new];
    place->bottom = self.atBottom;
    place->keys = [NSMutableArray new];
    place->offsets = [NSMutableArray new];
    NSRect visible = _scroll.contentView.bounds;
    // The spinner comes and goes above the history; the reader's place is a message or a day.
    for (NSUInteger i = [self indexAtY:NSMinY(visible)]; i < _items.count && _items[i]->top < NSMaxY(visible) && place->keys.count < kPlaceCandidates; i++) {
        SNListItem *item = _items[i];
        if (item->kind != SNItemMessage && item->kind != SNItemDay) continue;
        [place->keys addObject:item->key];
        [place->offsets addObject:@(item->top - NSMinY(visible))];
    }
    return place;
}

- (void)restorePlace:(SNListPlace *)place {
    if (place->bottom) {
        [self keepPlaceAt:CGFLOAT_MAX];
        return;
    }
    for (NSUInteger i = 0; i < place->keys.count; i++) {
        SNListItem *item = _itemsByKey[place->keys[i]];
        if (item) {
            [self keepPlaceAt:item->top - place->offsets[i].doubleValue];
            return;
        }
    }
    [self keepPlaceAt:NSMinY(_scroll.contentView.bounds)];
}

/// Scrolls for the list's own reasons (keeping the place, opening at an end), which a reader's
/// scroll is told apart from: only the reader's let the next page load.
- (void)keepPlaceAt:(CGFloat)offset {
    [self keepingPlace:^{ [self scrollToOffset:offset]; }];
}

/// Scrolling AppKit does when the document or the view is resized is not the reader's either.
- (void)keepingPlace:(void (^)(void))change {
    BOOL keeping = _keepingPlace;
    _keepingPlace = YES;
    change();
    _keepingPlace = keeping;
}

- (void)relayoutKeepingPlace {
    SNListPlace *place = [self currentPlace];
    [self relayout];
    [self restorePlace:place];
}

- (void)setBottomInset:(CGFloat)bottomInset {
    _bottomInset = bottomInset;
    [self relayoutKeepingPlace];
}

- (NSString *)jumpHighlightedTS { return _jumpHighlightTS; }

- (BOOL)isMessageHighlighted:(NSString *)ts {
    return (self.highlightedTS && [ts isEqualToString:self.highlightedTS]) || (_jumpHighlightTS && [ts isEqualToString:_jumpHighlightTS]);
}

- (void)updateRowHighlights {
    for (NSView *view in _visible.allValues)
        if ([view isKindOfClass:SNMessageRowView.class]) ((SNMessageRowView *)view).highlighted = [self isMessageHighlighted:((SNMessageRowView *)view).message.ts];
}

- (void)setHighlightedTS:(NSString *)highlightedTS {
    _highlightedTS = [highlightedTS copy];
    [self updateRowHighlights];
}

- (void)flashHighlightTS:(NSString *)ts {
    _jumpHighlightTS = [ts copy];
    [self updateRowHighlights];
    NSUInteger gen = ++_jumpHighlightGeneration;
    __weak SNMessageListView *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SNMessageListView *list = weakSelf;
        if (!list || list->_jumpHighlightGeneration != gen) return;
        list->_jumpHighlightTS = nil;
        [list updateRowHighlights];
    });
}

- (BOOL)landOnPendingJump {
    SNListItem *item = _pendingJumpTS ? [self itemForTS:_pendingJumpTS] : nil;
    if (!item) return NO;
    NSString *ts = _pendingJumpTS;
    _pendingJumpTS = nil;
    _newerArmed = NO;
    CGFloat viewport = _scroll.contentView.bounds.size.height;
    CGFloat offset = item->height < viewport ? item->top - round((viewport - item->height) / 3) : item->top;
    [self keepPlaceAt:offset];
    [self flashHighlightTS:ts];
    return YES;
}

- (void)jumpToMessageTS:(NSString *)ts {
    if (!ts.length) return;
    _pendingJumpTS = [ts copy];
    _pendingJumpConversationID = [_conversationID copy];
    _pendingJumpThreadTS = [_threadTS copy];
    _jumpToLatestPending = NO;
    _newerArmed = NO;
    [self landOnPendingJump];
}

- (void)jumpToLatest {
    if (_mode == SNMessageListChannel && _conversationID && [self.source hasNewerMessagesInConversation:_conversationID]) {
        _jumpToLatestPending = YES;
        [self.source loadNewerMessagesInConversation:_conversationID];
        return;
    }
    [self scrollToBottom];
}

- (void)updateLastRead:(NSString *)lastRead {
    if (SameID(_lastRead, lastRead)) return;
    _lastRead = [lastRead copy];
    [self placeNewDivider];
}

+ (BOOL)isReadHeldForKey:(NSString *)key { return key && [heldReads containsObject:key]; }

#pragma mark Geometry

- (void)layout {
    [super layout];
    NSSize size = self.bounds.size;
    _jump.frame = NSMakeRect(size.width - kJumpRight - kJumpSize, size.height - self.bottomInset - kJumpBottom - kJumpSize, kJumpSize, kJumpSize);
    if (NSEqualSizes(size, _scroll.frame.size) && size.width == _laidWidth) {
        [self tile];
        return;
    }
    // Read before the scroll view takes the new size: a taller composer must not hide the newest
    // messages, nor move the one the reader is on.
    SNListPlace *place = [self currentPlace];
    [self keepingPlace:^{ self->_scroll.frame = self.bounds; }];
    [self relayout];
    [self restorePlace:place];
}

- (BOOL)atBottom {
    NSRect visible = _scroll.contentView.bounds;
    return NSMaxY(visible) >= _document.frame.size.height - 2;
}

- (void)scrollToOffset:(CGFloat)offset {
    CGFloat maximum = MAX(0, _document.frame.size.height - _scroll.contentView.bounds.size.height);
    [_scroll.contentView scrollToPoint:NSMakePoint(0, MAX(0, MIN(maximum, offset)))];
    [_scroll reflectScrolledClipView:_scroll.contentView];
    [self tile];
}

- (void)scrollToBottom { [self scrollToOffset:CGFLOAT_MAX]; }

- (void)scrolled:(NSNotification *)notification {
    CGFloat y = NSMinY(_scroll.contentView.bounds);
    // A reader's scroll while no page loads lets the next page in that direction be asked for once.
    if (!_keepingPlace && _conversationID && _mode == SNMessageListChannel && ![self.source isLoadingMessagesInConversation:_conversationID]) {
        if (y <= _lastScrollY) _olderArmed = YES;
        if (y > _lastScrollY) _newerArmed = YES;
    }
    _lastScrollY = y;
    [self tile];
    [self hoverFromMouse];
    [self markReadIfSeen];
}

/// The first item whose bottom is below `y`.
- (NSUInteger)indexAtY:(CGFloat)y {
    NSUInteger low = 0, high = _items.count;
    while (low < high) {
        NSUInteger mid = (low + high) / 2;
        if (_items[mid]->top + _items[mid]->height <= y) low = mid + 1;
        else high = mid;
    }
    return low;
}

/// Shows the views of the items in view (and a margin), keeping the ones already there, and
/// recycles the others. Nothing is laid out here unless a message changed.
- (void)tile {
    if (_laidWidth != self.bounds.size.width) return;
    NSRect visible = _scroll.contentView.bounds;
    NSUInteger first = [self indexAtY:NSMinY(visible) - kOverscan], end = first;
    while (end < _items.count && _items[end]->top < NSMaxY(visible) + kOverscan) end++;
    for (NSString *key in _visible.allKeys) {
        SNListItem *item = _itemsByKey[key];
        if (!item || item->index < first || item->index >= end || ![self view:_visible[key] showsItem:item]) [self recycle:key];
    }
    for (NSUInteger i = first; i < end; i++) {
        SNListItem *item = _items[i];
        NSView *view = _visible[item->key];
        if (!view) view = _visible[item->key] = [self viewFor:item];
        else if (_viewsStale || [_staleKeys containsObject:item->key]) [self update:view for:item];
        NSRect frame = NSMakeRect(0, item->top, _laidWidth, item->height);
        if (!NSEqualRects(view.frame, frame)) view.frame = frame;
    }
    _viewsStale = NO;
    [_staleKeys removeAllObjects];
    [self updatePinnedPill];
    [self updateJump];
    [self placeActionBar];
    [self requestPages:visible];
}

/// Within a screen of either end of what is loaded the next page is asked for, once per visit:
/// the page keeps the reader's place, so nothing more loads until they scroll again.
- (void)requestPages:(NSRect)visible {
    if (_mode != SNMessageListChannel || !_conversationID || [self.source isLoadingMessagesInConversation:_conversationID]) return;
    if (_olderArmed && NSMinY(visible) < visible.size.height && [self.source hasOlderMessagesInConversation:_conversationID]) {
        _olderArmed = NO;
        // A page from the cache arrives (and is shown, tiling again) before this returns.
        [self.source loadOlderMessagesInConversation:_conversationID];
        return;
    }
    if (_newerArmed && _document.frame.size.height - NSMaxY(visible) < visible.size.height && [self.source hasNewerMessagesInConversation:_conversationID]) {
        _newerArmed = NO;
        [self.source loadNewerMessagesInConversation:_conversationID];
    }
}

- (NSUInteger)visibleRowCount { return _visible.count; }

/// Keys are per kind; only a message being edited or not changes its view.
- (BOOL)view:(NSView *)view showsItem:(SNListItem *)item {
    return item->kind != SNItemMessage || (view == _editor) == [item->key isEqualToString:_editingKey];
}

- (void)update:(NSView *)view for:(SNListItem *)item {
    if (item->kind == SNItemDay) {
        ((SNDayDividerView *)view).label = item->label;
    } else if (item->kind == SNItemMessage && view != _editor) {
        SNMessageRowView *row = (SNMessageRowView *)view;
        [row showMessage:item->message layout:[self layoutFor:item]];
        row.highlighted = [self isMessageHighlighted:item->message.ts];
    }
}

static void MarkNeedsDisplay(NSView *view) {
    view.needsDisplay = YES;
    for (NSView *subview in view.subviews) MarkNeedsDisplay(subview);
}

static void ClearLayerContents(NSView *view) {
    if (view.layer.contents) {
        view.layer.contents = nil;
        view.needsDisplay = YES;
    }
    for (NSView *subview in view.subviews) ClearLayerContents(subview);
}

- (NSView *)viewFor:(SNListItem *)item {
    if (item->kind == SNItemDay) {
        SNDayDividerView *view = _dayPool.lastObject ?: [[SNDayDividerView alloc] initWithFrame:NSZeroRect];
        if (_dayPool.count) [_dayPool removeLastObject];
        view.label = item->label;
        view.hidden = NO;
        MarkNeedsDisplay(view);
        if (!view.superview) [_document addSubview:view positioned:NSWindowBelow relativeTo:_newDivider];
        return view;
    }
    if (item->kind == SNItemLoading) {
        SNLoadingView *view = [[SNLoadingView alloc] initWithFrame:NSZeroRect];
        [_document addSubview:view positioned:NSWindowBelow relativeTo:_newDivider];
        return view;
    }
    if (item->kind == SNItemReplies) {
        SNRepliesDividerView *view = [[SNRepliesDividerView alloc] initWithFrame:NSZeroRect];
        view.label = item->label;
        [_document addSubview:view positioned:NSWindowBelow relativeTo:_newDivider];
        return view;
    }
    if ([item->key isEqualToString:_editingKey]) return _editor;
    SNMessageRowView *row = _rowPool.lastObject ?: [[SNMessageRowView alloc] initWithSource:self.source];
    if (_rowPool.count) [_rowPool removeLastObject];
    row.delegate = self;
    row.now = self.now;
    [row showMessage:item->message layout:[self layoutFor:item]];
    row.highlighted = [self isMessageHighlighted:item->message.ts];
    row.hovered = [item->key isEqualToString:_hoveredKey];
    row.hidden = NO;
    MarkNeedsDisplay(row);
    if (!row.superview) [_document addSubview:row positioned:NSWindowBelow relativeTo:_newDivider];
    return row;
}

- (void)recycle:(NSString *)key {
    NSView *view = _visible[key];
    [_visible removeObjectForKey:key];
    if (view == _editor) return;
    if ([key isEqualToString:_hoveredKey]) {
        if (!_holdHover) [self hoverKey:nil];
        else _actionBar.hidden = YES;
    }
    view.hidden = YES;
    // Out of view a row keeps neither its drawing, data nor pictures; it draws again when shown.
    if ([view isKindOfClass:SNMessageRowView.class]) {
        SNMessageRowView *row = (SNMessageRowView *)view;
        [row prepareForReuse];
        ClearLayerContents(row);
        [_rowPool addObject:row];
    } else if ([view isKindOfClass:SNDayDividerView.class]) {
        ClearLayerContents(view);
        [_dayPool addObject:(SNDayDividerView *)view];
    } else {
        ClearLayerContents(view);
        [view removeFromSuperview];
    }
}

/// The item of the message with this ts, for the ts-based conveniences.
- (SNListItem *)itemForTS:(NSString *)ts {
    for (SNListItem *item in _items)
        if (item->kind == SNItemMessage && [item->message.ts isEqualToString:ts]) return item;
    return nil;
}

#pragma mark Reading

/// What is shown, as the source keys it: the conversation, or "<conversation>/<thread ts>".
- (NSString *)readKey { return _conversationID ? (_threadTS ? SNThreadKey(_conversationID, _threadTS) : _conversationID) : nil; }

/// The one place that marks read: see -showMessages:... in the header. Cheap enough to ask on
/// every scroll and change.
- (void)markReadIfSeen {
    if (!_conversationID || (heldReads.count && [heldReads containsObject:self.readKey]) || !self.window.isKeyWindow || !(self.window.occlusionState & NSWindowOcclusionStateVisible)) return;
    // mark_msgs_read_immediately ("…and mark the channel read") reads it as soon as it shows;
    // without it only what was scrolled to the bottom of is read.
    BOOL immediately = SNPreferenceBool(self.source.preferences, @"mark_msgs_read_immediately", NO);
    if (self.isHiddenOrHasHiddenAncestor || (!self.atBottom && !immediately) || ![self.source conversationWithID:_conversationID]) return;
    // A thread's replies, not its parent (the channel's), which is all there is while they load.
    NSUInteger first = _threadTS ? 1 : 0;
    NSString *ts = nil;
    for (NSUInteger i = _messages.count; i > first && !ts; i--) {
        SNMessage *message = _messages[i - 1];
        if (message.sendState == SNMessageSent && (_threadTS || !message.isReply)) ts = message.ts;
    }
    if (!ts || (_markedTS && SNCompareTS(ts, _markedTS) != NSOrderedDescending)) return;
    _markedTS = ts;
    if (_threadTS) [self.source markThread:_threadTS inConversation:_conversationID readThrough:ts];
    else [self.source markConversation:_conversationID readThrough:ts];
}

- (void)viewWillMoveToWindow:(NSWindow *)window {
    [super viewWillMoveToWindow:window];
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    for (NSNotificationName name in @[ NSWindowDidBecomeKeyNotification, NSWindowDidChangeOcclusionStateNotification ]) {
        if (self.window) [center removeObserver:self name:name object:self.window];
        if (window) [center addObserver:self selector:@selector(windowSeenChanged:) name:name object:window];
    }
}

- (void)windowSeenChanged:(NSNotification *)notification { [self markReadIfSeen]; }

- (void)viewDidUnhide {
    [super viewDidUnhide];
    [self markReadIfSeen];
}

/// The source refuses a mark until Slack has given the conversation's (or the thread's) read
/// state in this session; the mark is tried again when that state arrives. A mark it took is
/// not repeated: the conversation's lastRead shows it.
- (void)retryReadMarkAfterChange:(SNChange *)change {
    NSString *key = self.readKey;
    if (!_markedTS || !key) return;
    BOOL retry = NO;
    if (_threadTS) {
        retry = [change.threads containsObject:key];
    } else if ([change.conversations containsObject:key]) {
        NSString *lastRead = [self.source conversationWithID:key].lastRead;
        retry = !lastRead || SNCompareTS(lastRead, _markedTS) == NSOrderedAscending;
    }
    if (!retry) return;
    _markedTS = nil;
    [self markReadIfSeen];
}

/// "Mark unread": a thread's reply marks the thread, the parent or a channel message the
/// conversation; held, or the reader would mark it read again at once.
- (void)markUnreadFrom:(SNMessage *)message {
    NSString *conversationID = message.conversationID ?: _conversationID;
    BOOL reply = _threadTS && ![message.ts isEqualToString:_threadTS];
    if (!heldReads) heldReads = [NSMutableSet new];
    [heldReads addObject:reply ? SNThreadKey(conversationID, _threadTS) : conversationID];
    if (reply) [self.source markThread:_threadTS inConversation:conversationID unreadFrom:message];
    else {
        [self.source markConversation:conversationID unreadFrom:message];
        if (_mode == SNMessageListChannel && SameID(conversationID, _conversationID))
            [self updateLastRead:[self.source conversationWithID:conversationID].lastRead];
    }
}

#pragma mark Overlays

/// The first message after the read mark that someone else sent: where "Novo" goes.
- (SNListItem *)firstUnreadItem {
    if (!_lastRead || _mode != SNMessageListChannel) return nil;
    NSString *me = self.source.me.userID;
    NSUInteger index = 0, high = _messages.count;
    while (index < high) {
        NSUInteger middle = (index + high) / 2;
        if (SNCompareTS(_messages[middle].ts, _lastRead) == NSOrderedDescending) high = middle;
        else index = middle + 1;
    }
    for (; index < _messages.count; index++)
        if (![_messages[index].userID isEqualToString:me]) return _itemsByKey[_messages[index].identifier];
    return nil;
}

/// The "Novo" line's y: when the first unread message opens a day, over the date divider's line.
- (CGFloat)newLineOf:(SNListItem *)first {
    NSUInteger index = first->index;
    return index > 0 && _items[index - 1]->kind == SNItemDay ? _items[index - 1]->top + kDayLine : first->top;
}

- (void)placeNewDivider {
    SNListItem *first = [self firstUnreadItem];
    _newDivider.hidden = !first;
    if (!first) return;
    _newDivider.frame = NSMakeRect(0, [self newLineOf:first] - 10, _laidWidth, 20);
}

/// The day of the first message in view pins its pill to the top once its divider has scrolled
/// past, and the next divider pushes it up.
- (void)updatePinnedPill {
    NSRect visible = _scroll.contentView.bounds;
    NSUInteger index = [self indexAtY:NSMinY(visible)];
    SNListItem *day = nil, *next = nil;
    for (NSInteger i = MIN((NSInteger)index, (NSInteger)_items.count - 1); i >= 0; i--)
        if (_items[(NSUInteger)i]->kind == SNItemDay) {
            day = _items[(NSUInteger)i];
            break;
        }
    for (NSUInteger i = index; i < _items.count; i++)
        if (_items[i]->kind == SNItemDay && _items[i] != day) {
            next = _items[i];
            break;
        }
    BOOL pinned = day && day->top < NSMinY(visible);
    _pinned.hidden = !pinned;
    if (!pinned) return;
    _pinned.label = day->label;
    CGFloat y = 0;
    if (next) y = MIN(0, next->top - NSMinY(visible) - (kPillTop + kPillHeight + 1));
    NSRect frame = NSMakeRect(0, y, self.bounds.size.width, kPillTop + kPillHeight + 2);
    if (!NSEqualRects(frame, _pinned.frame)) _pinned.frame = frame;
}

- (void)updateJump {
    NSRect visible = _scroll.contentView.bounds;
    BOOL hasNewer = _mode == SNMessageListChannel && _conversationID && [self.source hasNewerMessagesInConversation:_conversationID];
    BOOL show = hasNewer || _document.frame.size.height - NSMaxY(visible) > visible.size.height;
    if (show == _jumpShown) return;
    _jumpShown = show;
    if (show) _jump.hidden = NO;
    CGFloat from = show ? 0.9 : 1, to = show ? 1 : 0.9;
    CABasicAnimation *scale = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    scale.fromValue = @(from);
    scale.toValue = @(to);
    scale.duration = show ? 0.12 : SNDuration80;
    scale.timingFunction = SNEaseDefault();
    [_jump.layer addAnimation:scale forKey:@"scale"];
    __weak SNJumpButton *jump = _jump;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = show ? 0.12 : SNDuration80;
        context.timingFunction = SNEaseDefault();
        jump.animator.alphaValue = show;
    } completionHandler:^{
        if (!self->_jumpShown) jump.hidden = YES;
    }];
}

#pragma mark Hover

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_tracking) [self removeTrackingArea:_tracking];
    _tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect
                                             options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
                                               owner:self
                                            userInfo:nil];
    [self addTrackingArea:_tracking];
}

- (void)mouseMoved:(NSEvent *)event { [self pointerAt:[_document convertPoint:event.locationInWindow fromView:nil]]; }
- (void)mouseEntered:(NSEvent *)event { [self mouseMoved:event]; }

- (void)mouseExited:(NSEvent *)event {
    if (!_holdHover) [self hoverKey:nil];
}

- (void)hoverFromMouse {
    // An offscreen window (snapshots, the bench) has no pointer over it.
    if (!self.window.isVisible || _holdHover) return;
    NSPoint window = self.window.mouseLocationOutsideOfEventStream;
    if (!NSPointInRect([self convertPoint:window fromView:nil], self.bounds)) return;
    [self pointerAt:[_document convertPoint:window fromView:nil]];
}

- (void)pointerAt:(NSPoint)point {
    if (_holdHover) return;
    // Over the action bar the row below it stays hovered, even where the bar overhangs the row above.
    if (!_actionBar.hidden && NSPointInRect(point, _actionBar.frame)) return;
    NSUInteger index = [self indexAtY:point.y];
    SNListItem *item = index < _items.count && point.y >= _items[index]->top ? _items[index] : nil;
    NSString *key = item && item->kind == SNItemMessage ? item->key : nil;
    [self hoverKey:key];
    SNMessageRowView *row = (SNMessageRowView *)_visible[key ?: @""];
    if ([row isKindOfClass:SNMessageRowView.class]) [row pointerMovedTo:[row convertPoint:point fromView:_document]];
}

- (void)hoverMessageTS:(NSString *)ts {
    SNListItem *item = ts ? [self itemForTS:ts] : nil;
    [self hoverKey:item ? item->key : nil];
}

- (void)hoverKey:(NSString *)key {
    if (key == _hoveredKey || [key isEqualToString:_hoveredKey]) return;
    SNMessageRowView *old = (SNMessageRowView *)_visible[_hoveredKey ?: @""];
    if ([old isKindOfClass:SNMessageRowView.class]) old.hovered = NO;
    _hoveredKey = [key copy];
    SNMessageRowView *row = (SNMessageRowView *)_visible[key ?: @""];
    if ([row isKindOfClass:SNMessageRowView.class]) row.hovered = YES;
    [self placeActionBar];
}

- (void)placeActionBar {
    SNListItem *item = _hoveredKey ? _itemsByKey[_hoveredKey] : nil;
    // Reactions, replies and the rest need the message on Slack, on screen, and not being edited.
    // A message only the user sees has nothing to act on in Slack.
    if (!item || !_visible[item->key] || item->kind != SNItemMessage || item->message.sendState != SNMessageSent || item->message.isEphemeral || [item->key isEqualToString:_editingKey]) {
        _actionBar.hidden = YES;
        return;
    }
    [_actionBar showForMessage:item->message inThread:_mode == SNMessageListThread];
    // It straddles the row's top edge, but stays inside the list at the top.
    CGFloat y = MAX(item->top + SNActionBarTopOffset, NSMinY(_scroll.contentView.bounds));
    NSRect frame = NSMakeRect(_laidWidth - SNActionBarRightInset - _actionBar.width, y, _actionBar.width, SNActionBarHeight);
    if (!NSEqualRects(frame, _actionBar.frame)) _actionBar.frame = frame;
    _actionBar.hidden = NO;
}

- (SNMessageRowView *)rowForTS:(NSString *)ts {
    for (NSView *view in _visible.allValues)
        if ([view isKindOfClass:SNMessageRowView.class] && [((SNMessageRowView *)view).message.ts isEqualToString:ts]) return (SNMessageRowView *)view;
    return nil;
}

#pragma mark Actions

- (SNMessage *)hoveredMessage {
    SNListItem *item = _hoveredKey ? _itemsByKey[_hoveredKey] : nil;
    return item ? item->message : nil;
}

/// The row stays hovered while a menu or the emoji picker opened from it is open.
- (void)holdHoverUntilClosed:(void (^)(void (^released)(void)))open {
    _holdHover = YES;
    __weak SNMessageListView *weakSelf = self;
    open(^{
        SNMessageListView *list = weakSelf;
        if (!list) return;
        list->_holdHover = NO;
        [list hoverFromMouse];
    });
}

- (void)perform:(SNMessageAction)action reaction:(NSString *)reaction rect:(NSRect)rect {
    SNMessage *message = self.hoveredMessage;
    if (!message) return;
    switch (action) {
    case SNMessageActionQuickReaction: [self.source toggleReaction:reaction onMessage:message]; break;
    case SNMessageActionAddReaction: [self pickReactionFor:message from:_actionBar.frame inView:_document rightAligned:YES]; break;
    case SNMessageActionReply: [self.delegate messageList:self openThreadOfMessage:message]; break;
    case SNMessageActionMore: [self showMoreMenuFor:message rect:rect]; break;
    default: break;
    }
}

/// The picker opens under the bar, its right edge 7 pt right of the bar's (measured live). The
/// source counts the reaction towards frequent emoji.
- (void)pickReactionFor:(SNMessage *)message from:(NSRect)anchor inView:(NSView *)view rightAligned:(BOOL)rightAligned {
    CGFloat pickerWidth = SNEmojiPickerSize.width;
    NSRect rect = rightAligned ? NSMakeRect(NSMaxX(anchor) + 7 - pickerWidth, NSMinY(anchor), pickerWidth, anchor.size.height) : anchor;
    id<SNSource> source = self.source;
    [self holdHoverUntilClosed:^(void (^released)(void)) {
        SNEmojiPicker *picker = [SNEmojiPicker showForRect:rect inView:view placement:SNPlacementBelow source:source completion:^(NSString *name) {
            [source toggleReaction:name onMessage:message];
        }];
        picker.onClose = released;
    }];
}

- (NSArray<SNMenuItem *> *)menuItemsForMessage:(SNMessage *)message {
    SNMenuItem * (^item)(NSString *, NSString *, NSString *, void (^)(void)) = ^(NSString *key, NSString *icon, NSString *shortcut, void (^action)(void)) {
        SNMenuItem *menuItem = [SNMenuItem itemWithTitle:SNLocalized(key) action:action];
        menuItem.icon = icon;
        menuItem.iconSize = 18;
        menuItem.shortcut = shortcut;
        return menuItem;
    };
    SNMenuItem * (^submenu)(NSString *, NSString *) = ^(NSString *key, NSString *icon) {
        SNMenuItem *menuItem = item(key, icon, nil, nil);
        menuItem.submenu = YES;
        return menuItem;
    };
    id<SNSource> source = self.source;
    __weak SNMessageListView *weakSelf = self;
    NSString *conversationID = message.conversationID ?: _conversationID;
    NSString *text = [_renderer documentForMessage:message].plainText;
    NSString *link = [message permalinkInWorkspace:source.workspace].absoluteString;
    if (!link) {
        link = [NSString stringWithFormat:@"%@archives/%@/p%@", source.workspace.url.absoluteString ?: @"", conversationID,
                                          [message.ts stringByReplacingOccurrencesOfString:@"." withString:@""]];
        if (message.isReply) link = [link stringByAppendingFormat:@"?thread_ts=%@&cid=%@", message.threadTS, conversationID];
    }
    void (^copy)(NSString *) = ^(NSString *value) {
        [NSPasteboard.generalPasteboard clearContents];
        [NSPasteboard.generalPasteboard setString:value forType:NSPasteboardTypeString];
    };
    BOOL saved = conversationID ? [source isMessageSavedWithTS:message.ts inConversation:conversationID] : NO;
    SNMenuItem *save = item(saved ? @"channel.menu.unsave" : @"channel.menu.save", saved ? @"bookmark-filled" : @"bookmark", @"⇧⌘S", ^{
        if (conversationID) [source setSaved:!saved messageWithTS:message.ts inConversation:conversationID];
    });
    SNMenuItem *remind = submenu(@"channel.menu.remind", @"reminder");
    SNMenuItem *follow = item(@"channel.menu.follow", @"notifications", nil, nil);
    SNMenuItem *organize = submenu(@"channel.menu.organize", nil);
    SNMenuItem *apps = submenu(@"channel.menu.apps", nil);
    remind.disabled = follow.disabled = organize.disabled = apps.disabled = YES;
    NSMutableArray<SNMenuItem *> *items = [NSMutableArray new];
    [items addObjectsFromArray:@[
        item(@"channel.menu.unread", @"mark-as-unread", @"U", ^{ [weakSelf markUnreadFrom:message]; }),
        save, remind, follow, [SNMenuItem separator],
        item(@"channel.menu.copylink", @"link", @"L", ^{ copy(link); }), item(@"channel.menu.copy", @"text", @"⌘C", ^{ copy(text); }),
    ]];
    if (SNMessageIsEditable(message, source)) {
        SNMenuItem *remove = item(@"channel.menu.delete", @"trash", nil, ^{ [weakSelf confirmDeleteOfMessage:message]; });
        remove.danger = YES;
        [items addObjectsFromArray:@[ [SNMenuItem separator], item(@"channel.menu.edit", @"edit", @"E", ^{ [weakSelf editMessage:message]; }), remove ]];
    }
    [items addObjectsFromArray:@[ [SNMenuItem separator], organize, apps ]];
    return items;
}

- (void)showMoreMenuFor:(SNMessage *)message rect:(NSRect)rect {
    SNMenu *menu = [[SNMenu alloc] initWithItems:[self menuItemsForMessage:message] width:0];
    // m_msgmore_open: the menu's box covers the button's left 7.5 pt and starts 16.5 pt above it
    // (the menu keeps 4 pt from its anchor).
    NSRect anchor = NSOffsetRect([_document convertRect:rect fromView:_actionBar], kMoreMenuOverlap + 4, -kMoreMenuRise);
    [self holdHoverUntilClosed:^(void (^released)(void)) {
        SNPopover *popover = [menu showForRect:anchor inView:self->_document placement:SNPlacementLeft];
        popover.onClose = released;
    }];
}

#pragma mark Editing

- (void)editMessage:(SNMessage *)message {
    if (!SNMessageIsEditable(message, self.source)) return;
    SNListItem *item = _itemsByKey[message.identifier];
    if (!item || item->kind != SNItemMessage) return;
    [self dropEditor];
    _editor = [[SNMessageEditor alloc] initWithMessage:item->message source:self.source];
    _editingKey = item->key;
    __weak SNMessageListView *weakSelf = self;
    _editor.heightChanged = ^(SNMessageEditor *editor) { [weakSelf relayoutKeepingPlace]; };
    _editor.finished = ^(SNMessageEditor *editor) {
        SNMessageListView *list = weakSelf;
        if (!list || list->_editor != editor) return;
        [list endEditing];
        [list.delegate messageListDidFinishEditing:list];
    };
    _editor.deleteRequested = ^(SNMessage *edited) { [weakSelf confirmDeleteOfMessage:edited]; };
    [_document addSubview:_editor positioned:NSWindowBelow relativeTo:_newDivider];
    [self hoverKey:nil];
    [self relayoutKeepingPlace];
    [self scrollToShow:item];
    [_editor focus];
}

- (void)dropEditor {
    if (!_editor) return;
    if (_visible[_editingKey] == _editor) [_visible removeObjectForKey:_editingKey];
    [_editor removeFromSuperview];
    _editor = nil;
    _editingKey = nil;
}

- (void)endEditing {
    if (!_editor) return;
    [self dropEditor];
    [self relayoutKeepingPlace];
}

/// The least scrolling that brings the whole item into view (its top when it is taller).
- (void)scrollToShow:(SNListItem *)item {
    NSRect visible = _scroll.contentView.bounds;
    if (item->top < NSMinY(visible) || item->height > visible.size.height) [self keepPlaceAt:item->top];
    else if (item->top + item->height > NSMaxY(visible)) [self keepPlaceAt:item->top + item->height - visible.size.height];
}

- (void)confirmDeleteOfMessage:(SNMessage *)message {
    if (!self.window) return;
    // The message as the dialog's content width shows it, in a bordered box (scrolling when tall).
    static const CGFloat previewWidth = 464, previewPad = 4, maxPreviewHeight = 320;
    SNMessageLayout *layout = [SNMessageLayout layoutForMessage:message continuation:NO style:SNMessageRowThreadReply width:previewWidth renderer:_renderer];
    CGFloat contentHeight = layout.height + 2 * previewPad;
    CGFloat maxAllowed = MIN(maxPreviewHeight, MAX(80, NSHeight(self.window.contentView.bounds) - 260));
    SNMessagePreview *preview = [[SNMessagePreview alloc] initWithFrame:NSMakeRect(0, 0, previewWidth, MIN(contentHeight, maxAllowed))];
    SNMessageRowView *row = [[SNMessageRowView alloc] initWithSource:self.source];
    row.now = self.now;
    [row showMessage:message layout:layout];
    if (contentHeight > maxAllowed) {
        NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSInsetRect(preview.bounds, 1, 1)];
        scroll.drawsBackground = NO;
        scroll.hasVerticalScroller = YES;
        scroll.scrollerStyle = NSScrollerStyleOverlay;
        scroll.scrollerKnobStyle = NSScrollerKnobStyleLight;
        scroll.autohidesScrollers = YES;
        SNMessageListDocumentView *doc = [[SNMessageListDocumentView alloc] initWithFrame:NSMakeRect(0, 0, previewWidth - 2, contentHeight - 2)];
        row.frame = NSMakeRect(0, previewPad - 1, previewWidth - 2, layout.height);
        [doc addSubview:row];
        scroll.documentView = doc;
        preview.scrollView = scroll;
        [preview addSubview:scroll];
    } else {
        row.frame = NSMakeRect(0, previewPad, previewWidth, layout.height);
        [preview addSubview:row];
    }
    id<SNSource> source = self.source;
    [SNConfirmDialog showInWindow:self.window
                            title:SNLocalized(@"channel.delete.title")
                             text:SNLocalized(@"channel.delete.text")
                        accessory:preview
                     confirmTitle:SNLocalized(@"channel.delete.confirm")
                       completion:^(BOOL confirmed) {
                           if (confirmed) [source deleteMessage:message];
                       }];
}

#pragma mark Row delegate

- (void)messageRow:(SNMessageRowView *)row activateTarget:(SNRenderTarget *)target {
    if (target.kind == SNRenderTargetExpand || target.kind == SNRenderTargetCollapse)
        return [self messageRow:row setItems:@[ target.value ] expanded:target.kind == SNRenderTargetExpand];
    [self.delegate messageList:self activateTarget:target inMessage:row.message];
}

- (void)messageRow:(SNMessageRowView *)row setItems:(NSArray<NSString *> *)keys expanded:(BOOL)expanded {
    if (row.message) [self.source setItems:keys expanded:expanded inMessages:@[ row.message ]];
}

- (void)messageRowOpenThread:(SNMessageRowView *)row { [self.delegate messageList:self openThreadOfMessage:row.message]; }

- (void)messageRow:(SNMessageRowView *)row toggleReaction:(NSString *)name {
    if (row.message) [self.source toggleReaction:name onMessage:row.message];
}

- (void)messageRow:(SNMessageRowView *)row addReactionFromView:(NSView *)view {
    if (row.message) [self pickReactionFor:row.message from:view.bounds inView:view rightAligned:NO];
}

- (void)messageRowRetrySend:(SNMessageRowView *)row {
    if (row.message) [self.source retrySendingMessage:row.message];
}

/// A message Slack never got goes without asking: nobody else saw it.
- (void)messageRowDiscardSend:(SNMessageRowView *)row {
    if (row.message) [self.source deleteMessage:row.message];
}

- (void)messageRowNeedsLayout:(SNMessageRowView *)row {
    if (!row.message) return;
    [_layouts removeObjectForKey:row.message.identifier];
    [self relayoutKeepingPlace];
    [self tile];
}

@end
