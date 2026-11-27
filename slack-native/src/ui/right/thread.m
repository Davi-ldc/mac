// Owns the thread column: its header, the thread's list and the reply composer.
#import "render/strings.h"
#import "ui/channel/pane.h"
#import "ui/composer/composer.h"
#import "ui/composer/pasteboard.h"
#import "ui/kit/label.h"
#import "ui/present/message.h"
#import "ui/right/panels.h"
#import "ui/right/thread.h"

/// The parent message starts 12 pt under the header (gutter padding-top 20 in the thread).
static const CGFloat kListTop = 12, kListBottomInset = 18;
/// The header's close: a medium icon button (its 20 pt x) in a 28 pt box, #444649 under the
/// pointer (measured on live/click/t_thread_close; CSS's base-ter is darker).
static const CGFloat kCloseBox = 28, kCloseIcon = 20;
static const SNColorToken kCloseHover = 0x444649ff;

@interface SNThreadPaneView : NSView
@property (nonatomic, weak) SNThreadPane *pane;
@end

@interface SNThreadPane () <SNMessageListDelegate, SNChangeObserver>
- (void)layoutIn:(NSRect)bounds;
@end

@implementation SNThreadPaneView
- (BOOL)isFlipped { return YES; }
// Files dragged over the column attach to its composer.
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)drag { return [self.pane.composer dragEntered:drag overView:self]; }
- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)drag { return [self.pane.composer dragEntered:drag overView:self]; }
- (void)draggingExited:(id<NSDraggingInfo>)drag { [self.pane.composer dragExited]; }
- (BOOL)performDragOperation:(id<NSDraggingInfo>)drag { return [self.pane.composer performDrag:drag]; }

- (void)layout {
    [super layout];
    [self.pane layoutIn:self.bounds];
}
@end

@implementation SNThreadPane {
    id<SNSource> _source;
    __weak id<SNNavigator> _navigator;
    SNThreadPaneView *_view;
    SNLabel *_title;
    NSString *_conversationID, *_threadTS;
    SNMessage *_parent;
    /// A flexpane shown instead of a thread, and its name.
    NSView<SNPanelView> *_panel;
    NSString *_panelName;
}

+ (void)load { SNRegisterPane(SNPaneSlotSecondary, self); }

- (instancetype)initWithSource:(id<SNSource>)source navigator:(id<SNNavigator>)navigator {
    if (!(self = [super init])) return nil;
    _source = source;
    _navigator = navigator;
    _view = [[SNThreadPaneView alloc] initWithFrame:NSMakeRect(0, 0, 393, 893)];
    [_view registerForDraggedTypes:SNComposerFileTypes()];
    _view.pane = self;
    _title = [SNLabel labelWithText:SNLocalized(@"thread.title") font:SNFont(SNFontSizeBase, SNFontWeightBlack) color:SNColorContentPry];
    _title.lineHeight = SNThreadHeaderHeight;
    _more = [SNKebabButton kebabWithSize:28 iconSize:20];
    _more.tooltip = SNLocalized(@"thread.more");
    _more.tooltipPlacement = SNPlacementBelow;
    _more.enabled = NO;
    _close = [SNButton iconButtonNamed:@"close" size:kCloseBox iconSize:kCloseIcon];
    _close.hoverFillColor = kCloseHover;
    _close.transitionDuration = 0;
    _close.tooltip = SNLocalized(@"thread.close");
    _close.tooltipPlacement = SNPlacementBelow;
    __weak SNThreadPane *weakSelf = self;
    _close.action = ^(SNButton *button) {
        SNThreadPane *pane = weakSelf;
        [pane->_navigator closeThread];
    };
    _list = [[SNMessageListView alloc] initWithSource:source mode:SNMessageListThread];
    _list.delegate = self;
    _list.bottomInset = kListBottomInset;
    _composer = [[SNComposer alloc] initWithSource:source];
    _composer.navigator = navigator;
    _composer.heightDidChange = ^(SNComposer *composer) { weakSelf.view.needsLayout = YES; };
    _composer.editLastMessage = ^(SNComposer *composer) {
        SNThreadPane *pane = weakSelf;
        for (SNMessage *message in [pane threadMessages].reverseObjectEnumerator)
            if (SNMessageIsEditable(message, pane->_source)) {
                [pane.list editMessage:message];
                return;
            }
    };
    for (NSView *view in @[ _list, _composer, _title, _more, _close ]) [_view addSubview:view];
    [source addChangeObserver:self];
    return self;
}

- (NSView *)view { return _view; }
- (CGFloat)minimumWidth { return 300; }

- (void)layoutIn:(NSRect)bounds {
    _panel.frame = bounds;
    CGFloat width = bounds.size.width, composerHeight = self.composer.preferredHeight, centre = SNThreadHeaderHeight / 2;
    _title.frame = NSMakeRect(16, 0, MAX(0, width - 100), SNThreadHeaderHeight);
    // The same measured centres as the conversation header's close and kebab buttons.
    _close.frame = NSMakeRect(width - 26 - kCloseBox / 2, centre - kCloseBox / 2, kCloseBox, kCloseBox);
    _more.frame = NSMakeRect(width - 58 - 14, centre - 14, 28, 28);
    self.composer.frame = NSMakeRect(0, bounds.size.height - composerHeight, width, composerHeight);
    CGFloat top = SNThreadHeaderHeight + kListTop;
    self.list.frame = NSMakeRect(0, top, width, MAX(0, bounds.size.height - top - composerHeight));
}

- (void)showPanel:(NSString *)name {
    if ([name isEqualToString:_panelName]) return;
    [_panel removeFromSuperview];
    _panelName = [name copy];
    __weak id<SNNavigator> navigator = _navigator;
    _panel = name ? SNMakePanel(name, _source, ^{ [navigator go:[navigator.location locationWithPanel:nil]]; }) : nil;
    if (_panel) {
        _panel.frame = _view.bounds;
        [_view addSubview:_panel];
    }
    for (NSView *view in @[ _list, _composer, _title, _more, _close ]) view.hidden = _panel != nil;
}

- (void)showLocation:(SNLocation *)location {
    [self showPanel:location.panel];
    NSString *conversationID = location.threadTS ? location.conversationID : nil, *threadTS = conversationID ? location.threadTS : nil;
    BOOL same = (threadTS == _threadTS || [threadTS isEqualToString:_threadTS]) && (conversationID == _conversationID || [conversationID isEqualToString:_conversationID]);
    if (!same) {
        // Closing forgets the thread: nothing of it is shown, reloaded or marked while hidden.
        _conversationID = [conversationID copy];
        _threadTS = [threadTS copy];
        [self.composer showConversation:_conversationID threadTS:_threadTS];
        if (_threadTS) [_source loadThread:_threadTS inConversation:_conversationID];
        [self reload];
    }
    if (_threadTS && location.messageTS) [self.list jumpToMessageTS:location.messageTS];
}

- (void)reload {
    NSArray<SNMessage *> *messages = [self threadMessages];
    _parent = messages.firstObject;
    [self.list showMessages:messages inConversation:_conversationID threadTS:_threadTS lastRead:nil];
}

/// The replies as loaded, or the parent alone (from the history) until they arrive.
- (NSArray<SNMessage *> *)threadMessages {
    if (!_threadTS) return @[];
    NSArray<SNMessage *> *thread = [_source threadInConversation:_conversationID ts:_threadTS];
    if (thread.count) return thread;
    for (SNMessage *message in [_source messagesInConversation:_conversationID])
        if ([message.ts isEqualToString:_threadTS]) return @[ message ];
    return @[];
}

- (void)sourceChanged:(SNChange *)change {
    BOOL stale = [self.list applyChange:change];
    if (!_threadTS) return;
    // The thread's own changes; the conversation's only while the parent is not shown yet (it
    // comes from the history then).
    BOOL changed = stale || [change.threads containsObject:SNThreadKey(_conversationID, _threadTS)];
    NSSet<NSString *> *keys = change.messageKeys;
    if (!changed && _parent) changed = [keys containsObject:SNMessageKey(_parent)];
    else if (!changed) changed = [change.messages containsObject:_conversationID];
    if (changed) [self reload];
}

- (void)messageList:(SNMessageListView *)list openThreadOfMessage:(SNMessage *)message {}

- (void)messageList:(SNMessageListView *)list activateTarget:(SNRenderTarget *)target inMessage:(SNMessage *)message {
    SNActivateTarget(target, message, _navigator);
}

- (void)messageListDidFinishEditing:(SNMessageListView *)list { [self.composer focus]; }

- (void)focusForTyping {
    if (_panel) [_panel focusForTyping];
    else if (!self.composer.hidden) [self.composer focus];
}

@end
