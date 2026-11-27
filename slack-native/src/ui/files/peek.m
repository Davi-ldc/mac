// Owns the peek's rows, size, placement and closing.
#import "render/strings.h"
#import "ui/files/peek.h"
#import "ui/files/rows.h"
#import "ui/kit/label.h"
#import "ui/kit/overlay.h"

/// FilesTabPeek's height: each row's estimate (file 61, link 63, list-loading 420) plus 10, at
/// most 600; 200 for the empty placeholder.
static const CGFloat kFileEstimate = 61, kLinkEstimate = 63, kLoadingEstimate = 420, kExtra = 10, kMaximum = 600, kEmpty = 200;
/// The tab's listLoadingFragment: the first, five more and the last skeleton row.
static const NSUInteger kSkeletonRows = 7;
/// b4_files_peek: the box starts 8 pt left of the tab and 31.5 pt under its top.
static const CGFloat kLeftOfTab = 8, kBelowTabTop = 31.5;

@interface SNFilesPeekDocument : NSView
@end

@implementation SNFilesPeekDocument
- (BOOL)isFlipped { return YES; }
@end

@implementation SNFilesPeekView {
    id<SNSource> _source;
    SNConversationAttachments *_attachments;
    NSScrollView *_scroll;
    SNFilesPeekDocument *_document;
    SNLabel *_empty;
    NSMutableArray<NSView *> *_rows;
}

- (instancetype)initWithSource:(id<SNSource>)source attachments:(SNConversationAttachments *)attachments {
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, SNFilesPeekWidth, kEmpty)])) return nil;
    _source = source;
    _attachments = attachments;
    _rows = [NSMutableArray new];
    _scroll = [[NSScrollView alloc] initWithFrame:self.bounds];
    _scroll.drawsBackground = NO;
    _scroll.hasVerticalScroller = YES;
    _scroll.scrollerStyle = NSScrollerStyleOverlay;
    _scroll.autohidesScrollers = YES;
    _document = [[SNFilesPeekDocument alloc] initWithFrame:self.bounds];
    _scroll.documentView = _document;
    // The explorer's empty state: c-empty_state's 18 pt black title, centred in 200 pt.
    _empty = [SNLabel labelWithText:SNLocalized(@"files.tab.empty") font:SNFont(SNFontSizeSubtitle, SNFontWeightBlack) color:SNColorContentPry];
    _empty.lineHeight = 22.5;
    _empty.maximumLines = 0;
    _empty.alignment = NSTextAlignmentCenter;
    for (NSView *view in @[ _scroll, _empty ]) [self addSubview:view];
    [self update];
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)layout {
    [super layout];
    _scroll.frame = self.bounds;
    CGFloat width = NSWidth(self.bounds), height = NSHeight(self.bounds);
    CGFloat emptyHeight = [_empty heightForWidth:MAX(0, width - 32)];
    _empty.frame = NSMakeRect(16, round((height - emptyHeight) / 2), MAX(0, width - 32), emptyHeight);
}

- (NSArray<NSView *> *)rows { return _rows; }

- (void)update {
    for (NSView *row in _rows) [row removeFromSuperview];
    [_rows removeAllObjects];
    BOOL loading = [_attachments isLoading:SNAttachmentAll];
    BOOL query = _attachments.query.length > 0;
    BOOL nothing = !loading && !_attachments.media.count && !_attachments.files.count && !_attachments.links.count;
    CGFloat estimate = 0, y = 0;
    if (nothing) {
        estimate = kEmpty;
    } else if (loading) {
        for (NSUInteger i = 0; i < kSkeletonRows; i++) {
            SNFileSkeletonRow *row = [[SNFileSkeletonRow alloc] initWithStyle:SNFileRowPeek index:i last:i + 1 == kSkeletonRows];
            CGFloat height = SNFileRowHeight(SNFileRowPeek, i + 1 == kSkeletonRows);
            row.frame = NSMakeRect(0, y, SNFilesPeekWidth, height);
            y += height;
            [_rows addObject:row];
        }
        estimate = kLoadingEstimate + kExtra;
    } else {
        NSArray<SNAttachment *> *items = [_attachments mixedIncludingMedia:query];
        for (NSUInteger i = 0; i < items.count; i++) {
            SNAttachment *item = items[i];
            BOOL last = i + 1 == items.count;
            NSView *row;
            CGFloat height;
            if (item.file) {
                SNFileRow *fileRow = [[SNFileRow alloc] initWithSource:_source style:SNFileRowPeek];
                fileRow.file = item.file;
                fileRow.detail = SNFileRowDetailShared;
                fileRow.showsActionOnHover = YES;
                fileRow.last = last;
                row = fileRow;
                height = SNFileRowHeight(SNFileRowPeek, last);
                estimate += kFileEstimate;
            } else {
                SNLinkRow *linkRow = [[SNLinkRow alloc] initWithStyle:SNFileRowPeek];
                linkRow.link = item.link;
                linkRow.last = last;
                row = linkRow;
                height = SNLinkRowHeight(SNFileRowPeek, last);
                estimate += kLinkEstimate;
            }
            row.frame = NSMakeRect(0, y, SNFilesPeekWidth, height);
            y += height;
            [_rows addObject:row];
        }
        estimate += kExtra;
    }
    for (NSView *row in _rows) [_document addSubview:row];
    CGFloat height = MIN(estimate, kMaximum);
    _empty.hidden = !nothing;
    _scroll.hidden = nothing;
    [self setFrameSize:NSMakeSize(SNFilesPeekWidth, height)];
    _scroll.frame = self.bounds;
    _document.frame = NSMakeRect(0, 0, SNFilesPeekWidth, MAX(y, height));
    CGFloat emptyHeight = [_empty heightForWidth:SNFilesPeekWidth - 32];
    _empty.frame = NSMakeRect(16, round((height - emptyHeight) / 2), SNFilesPeekWidth - 32, emptyHeight);
}

@end

#pragma mark - Peek

/// The open peek; it owns itself while open.
static SNFilesPeek *gCurrent;

@implementation SNFilesPeek {
    __weak NSView *_tab;
    SNPanelView *_panel;
    id _monitor;
    BOOL _acceptedMouseMoved, _closing;
    NSUInteger _closeDue;
}

+ (SNFilesPeek *)current { return gCurrent; }

+ (instancetype)showUnderTab:(NSView *)tab source:(id<SNSource>)source attachments:(SNConversationAttachments *)attachments {
    SNOverlayHost *host = [SNOverlayHost hostForWindow:tab.window];
    if (!host) return nil;
    [gCurrent close];
    SNFilesPeek *peek = [self new];
    peek->_tab = tab;
    peek->_list = [[SNFilesPeekView alloc] initWithSource:source attachments:attachments];
    SNShadowStack shadow = {2, {{0, 0, 0, 1, SNMeasuredHoverCardRing, NO}, {0, 4, 12, 0, 0x00000014, NO}}};
    peek->_panel = [[SNPanelView alloc] initWithFill:SNColorBasePry radius:SNRadiusLarge shadow:shadow];
    [peek->_panel.contentView addSubview:peek->_list];
    [host addSubview:peek->_panel];
    [peek place];
    gCurrent = peek;
    // effects.txt [L9]: the skeleton (or the rows) fades in over 150 ms.
    peek->_list.alphaValue = 0;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = SNLiveFilesTabPreviewFadeIn;
        context.timingFunction = SNEasePress();
        peek->_list.animator.alphaValue = 1;
    }];
    [peek watchPointer];
    return peek;
}

- (NSView *)panel { return _panel; }

- (void)place {
    NSView *tab = _tab;
    NSView *host = _panel.superview;
    if (!tab || !host) return;
    NSRect target = [host convertRect:tab.bounds fromView:tab];
    NSSize size = _list.frame.size;
    NSRect bounds = NSInsetRect(host.bounds, 8, 8);
    CGFloat width = MIN(size.width, MAX(0, NSWidth(bounds)));
    CGFloat height = MIN(size.height, MAX(0, NSHeight(bounds)));
    CGFloat x = MAX(NSMinX(bounds), MIN(round(NSMinX(target) - kLeftOfTab), NSMaxX(bounds) - width));
    CGFloat y = MAX(NSMinY(bounds), MIN(NSMinY(target) + kBelowTabTop, NSMaxY(bounds) - height));
    _panel.frame = NSMakeRect(x, y, width, height);
    _list.frame = _panel.contentView.bounds;
}

- (void)update {
    [_list update];
    [self place];
}

#pragma mark Closing

/// The pointer in window coordinates and whether it is over the tab or the peek.
- (BOOL)pointerOverPeekInWindow:(NSWindow *)window inside:(BOOL *)inside {
    NSView *content = window.contentView, *tab = _tab;
    NSPoint point = window.mouseLocationOutsideOfEventStream;
    *inside = NSPointInRect([content convertPoint:point fromView:nil], content.bounds);
    NSRect tabRect = tab ? [tab convertRect:tab.bounds toView:nil] : NSZeroRect;
    NSRect panelRect = [_panel convertRect:_panel.bounds toView:nil];
    return NSPointInRect(point, tabRect) || NSPointInRect(point, panelRect);
}

/// Like the rail's peeks: once the pointer rests on something else in the window for the hover
/// card's grace the peek goes; outside the window it waits for the pointer to come back.
- (void)watchPointer {
    NSWindow *window = _tab.window;
    _acceptedMouseMoved = window.acceptsMouseMovedEvents;
    window.acceptsMouseMovedEvents = YES;
    __weak SNFilesPeek *weakSelf = self;
    _monitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskMouseMoved | NSEventMaskLeftMouseDown handler:^NSEvent *(NSEvent *event) {
        SNFilesPeek *peek = weakSelf;
        if (peek && event.window == window) [peek pointerMoved:event];
        return event;
    }];
}

- (void)pointerMoved:(NSEvent *)event {
    NSWindow *window = _tab.window;
    BOOL inside;
    BOOL over = [self pointerOverPeekInWindow:window inside:&inside];
    // A click elsewhere closes it at once.
    if (event.type == NSEventTypeLeftMouseDown && !over) {
        [self close];
        return;
    }
    if (over || !inside) {
        _closeDue++;
        return;
    }
    NSUInteger due = ++_closeDue;
    __weak SNFilesPeek *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SNLiveHoverCardCloseDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SNFilesPeek *peek = weakSelf;
        if (!peek || peek->_closeDue != due) return;
        BOOL stillInside;
        if (![peek pointerOverPeekInWindow:window inside:&stillInside] && stillInside) [peek close];
    });
}

- (void)close {
    if (_closing) return;
    _closing = YES;
    if (_monitor) [NSEvent removeMonitor:_monitor];
    _monitor = nil;
    _tab.window.acceptsMouseMovedEvents = _acceptedMouseMoved;
    [_panel removeFromSuperview];
    if (gCurrent == self) gCurrent = nil;
}

- (void)dealloc {
    if (_monitor) [NSEvent removeMonitor:_monitor];
}

@end
