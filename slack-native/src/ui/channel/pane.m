// Owns the conversation column's layout and its reactions to navigation and source changes.
#import "render/images.h"
#import "render/strings.h"
#import "ui/channel/browser.h"
#import "ui/channel/pane.h"
#import "ui/composer/composer.h"
#import "ui/composer/pasteboard.h"
#import "ui/files/browser.h"
#import "ui/files/peek.h"
#import "ui/files/tab.h"
#import "ui/kit/label.h"
#import "ui/present/message.h"
#import "ui/profile/profilecard.h"
#import "ui/shell/card.h"

/// Space between the last message and the composer (measured on the captures).
static const CGFloat kListBottomInset = 18;

void SNActivateTarget(SNRenderTarget *target, SNMessage *message, id<SNNavigator> navigator) {
    NSString *conversationID = message.conversationID ?: navigator.location.conversationID;
    switch (target.kind) {
    case SNRenderTargetLink:
        if ([target.value hasPrefix:@"thread:"] && conversationID) {
            [navigator openThread:[target.value substringFromIndex:7] inConversation:conversationID];
            return;
        }
        // Only web links leave the app.
        if ([target.value hasPrefix:@"https://"] || [target.value hasPrefix:@"http://"] || [target.value hasPrefix:@"mailto:"])
            [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:target.value]];
        return;
    case SNRenderTargetChannel: [navigator openConversation:target.value]; return;
    default: return;
    }
}

/// Slack's unavailable-channel card (p-unavailable_channel): at most 528 wide, 96 pt down, padded
/// 48 by 64, the 22 pt black title over 15 pt text in content-sec, centred.
@interface SNUnavailableConversationView : NSView
@end

@implementation SNUnavailableConversationView {
    SNLabel *_title, *_text;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _title = [SNLabel labelWithText:SNLocalized(@"channel.unavailable.title") font:SNFont(SNFontSizeTitle, SNFontWeightBlack) color:SNColorContentPry];
    _text = [SNLabel labelWithText:SNLocalized(@"channel.unavailable.text") font:SNFont(SNFontSizeBase, SNFontWeightRegular) color:SNColorContentSec];
    for (SNLabel *label in @[ _title, _text ]) {
        label.maximumLines = 0;
        label.alignment = NSTextAlignmentCenter;
        [self addSubview:label];
    }
    _title.lineHeight = 28;
    _text.lineHeight = 22;
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)layout {
    [super layout];
    CGFloat card = MIN(528, NSWidth(self.bounds)), width = MAX(0, card - 2 * 64), x = round((NSWidth(self.bounds) - width) / 2), y = 96 + 48;
    CGFloat title = [_title heightForWidth:width];
    _title.frame = NSMakeRect(x, y, width, title);
    _text.frame = NSMakeRect(x, y + title + 8, width, [_text heightForWidth:width]);
}

@end

@interface SNChannelPaneView : NSView <SNCardHeaderProvider>
@property (nonatomic, weak) SNChannelPane *pane;
@end

@interface SNChannelPane () <SNMessageListDelegate, SNChangeObserver>
- (void)layoutIn:(NSRect)bounds;
@end

@implementation SNChannelPaneView
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
- (NSView *)cardHeaderView { return self.pane.header; }
@end

@implementation SNChannelPane {
    id<SNSource> _source;
    __weak id<SNNavigator> _navigator;
    SNChannelPaneView *_view;
    NSString *_conversationID, *_lastRead;
    /// The conversation the header and composer were set up for; nil while it is unknown.
    SNConversation *_shown;
    /// The pages shown instead of a conversation, made the first time.
    SNChannelBrowserView *_browser;
    SNFilesBrowserView *_filesBrowser;
    /// The conversation's "Files and links" tab, made the first time, and its lists (shared with
    /// the tab's peek), made for each conversation.
    SNConversationFilesView *_filesTab;
    SNConversationAttachments *_attachments;
    NSString *_filesPage;
    BOOL _showsFilesTab;
    /// What shows instead of the history when Slack refused the conversation.
    SNUnavailableConversationView *_unavailable;
    BOOL _refused;
}

+ (void)load { SNRegisterPane(SNPaneSlotPrimary, self); }

- (instancetype)initWithSource:(id<SNSource>)source navigator:(id<SNNavigator>)navigator {
    if (!(self = [super init])) return nil;
    _source = source;
    _navigator = navigator;
    _view = [[SNChannelPaneView alloc] initWithFrame:NSMakeRect(0, 0, 842, 893)];
    [_view registerForDraggedTypes:SNComposerFileTypes()];
    _view.pane = self;
    _header = [[SNChannelHeader alloc] initWithSource:source];
    _list = [[SNMessageListView alloc] initWithSource:source mode:SNMessageListChannel];
    _list.delegate = self;
    _list.bottomInset = kListBottomInset;
    _composer = [[SNComposer alloc] initWithSource:source];
    _composer.navigator = navigator;
    __weak SNChannelPane *weakSelf = self;
    _composer.heightDidChange = ^(SNComposer *composer) { weakSelf.view.needsLayout = YES; };
    _composer.editLastMessage = ^(SNComposer *composer) {
        SNChannelPane *pane = weakSelf;
        [pane editLastOf:[pane->_source messagesInConversation:pane->_conversationID ?: @""]];
    };
    _header.attachments = ^SNConversationAttachments * { return [weakSelf attachments]; };
    _header.tabChosen = ^(NSUInteger index) {
        SNChannelPane *pane = weakSelf;
        id<SNNavigator> navigator = pane ? pane->_navigator : nil;
        SNLocation *here = navigator.location;
        if (!here.conversationID) return;
        [navigator go:[SNLocation locationWithTab:here.tab conversation:here.conversationID thread:nil page:index == 2 ? SNPageConversationFiles : nil
                                            panel:here.panel]];
    };
    _header.closeAction = ^{
        SNChannelPane *pane = weakSelf;
        id<SNNavigator> navigator = pane->_navigator;
        [navigator go:[SNLocation locationWithTab:navigator.location.tab conversation:nil thread:nil]];
    };
    _header.search.action = ^(SNButton *button) {
        SNChannelPane *pane = weakSelf;
        [pane->_navigator openSearchWithQuery:nil];
    };
    // The profile card's buttons and clicks on people move this window, from this column's messages
    // or the thread's.
    SNProfileCard.navigator = navigator;
    // The header goes in the card, across this column and the thread's.
    for (NSView *view in @[ _list, _composer ]) [_view addSubview:view];
    [source addChangeObserver:self];
    return self;
}

- (NSView *)view { return _view; }
- (CGFloat)minimumWidth { return 300; }
- (BOOL)showsUnavailable { return _refused; }

- (void)layoutIn:(NSRect)bounds {
    _browser.frame = bounds;
    _filesBrowser.frame = bounds;
    _unavailable.frame = bounds;
    _filesTab.frame = bounds;
    CGFloat composerHeight = self.composer.preferredHeight;
    self.composer.frame = NSMakeRect(0, bounds.size.height - composerHeight, bounds.size.width, composerHeight);
    self.list.frame = NSMakeRect(0, 0, bounds.size.width, MAX(0, bounds.size.height - composerHeight));
}

- (void)showLocation:(SNLocation *)location {
    [self.header closeFilesPreview];
    BOOL page = [location.page isEqualToString:SNPageChannels];
    if (page) {
        if (!_browser) {
            _browser = [[SNChannelBrowserView alloc] initWithSource:_source navigator:_navigator];
            _browser.frame = _view.bounds;
            [_view addSubview:_browser];
            [_browser reload];
        }
    } else if (_browser) {
        // Tear down hidden visited browsers so their rows, layers and thumbnails are freed.
        _browser.hidden = YES;
        SNReleaseViewImages(_browser);
        [_browser removeFromSuperview];
        _browser = nil;
    }
    BOOL files = [@[ SNPageFiles, SNPageFilesCanvases, SNPageFilesLists ] containsObject:location.page ?: @""];
    if (files) {
        BOOL fresh = !_filesBrowser;
        if (fresh) {
            _filesBrowser = [[SNFilesBrowserView alloc] initWithSource:_source navigator:_navigator];
            _filesBrowser.frame = _view.bounds;
            [_view addSubview:_filesBrowser];
        }
        if (fresh || ![_filesPage isEqualToString:location.page]) [_filesBrowser showPage:location.page];
    } else if (_filesBrowser) {
        _filesBrowser.hidden = YES;
        SNReleaseViewImages(_filesBrowser);
        [_filesBrowser removeFromSuperview];
        _filesBrowser = nil;
    }
    _filesPage = files ? location.page : nil;
    self.header.collapsed = page || files;
    self.list.highlightedTS = location.threadTS;
    NSString *conversationID = location.conversationID;
    BOOL filesTab = conversationID && [location.page isEqualToString:SNPageConversationFiles];
    BOOL moved = !(conversationID == _conversationID || [conversationID isEqualToString:_conversationID]);
    if (moved) {
        _conversationID = [conversationID copy];
        _shown = nil;
        _attachments = nil;
    }
    // Each visit to the tab asks for its lists again.
    if (filesTab && (!_showsFilesTab || moved)) [self.attachments reload];
    _showsFilesTab = filesTab;
    if (moved) [self showConversationIfKnown];
    else [self showFilesTabIfChosen];
    if (location.messageTS && !location.threadTS && _conversationID) [self.list jumpToMessageTS:location.messageTS];
}

- (SNConversationAttachments *)attachments {
    if (!_attachments && _conversationID) {
        _attachments = [[SNConversationAttachments alloc] initWithSource:_source conversationID:_conversationID];
        __weak SNChannelPane *weakSelf = self;
        SNConversationAttachments *attachments = _attachments;
        __weak SNConversationAttachments *weakAttachments = attachments;
        attachments.changed = ^{
            SNChannelPane *pane = weakSelf;
            if (!pane || pane->_attachments != weakAttachments) return;
            if (pane->_showsFilesTab) [pane->_filesTab update];
            if ([SNFilesPeek.current.panel isDescendantOf:pane->_view.window.contentView]) [SNFilesPeek.current update];
        };
    }
    return _attachments;
}

/// The conversation's "Files and links" in place of its messages and composer.
- (void)showFilesTabIfChosen {
    BOOL filesTab = _showsFilesTab && _shown;
    if (filesTab) {
        if (!_filesTab) {
            _filesTab = [[SNConversationFilesView alloc] initWithSource:_source];
            _filesTab.frame = _view.bounds;
            [_view addSubview:_filesTab];
        }
        _filesTab.attachments = self.attachments;
    } else if (_filesTab) {
        _filesTab.hidden = YES;
        SNReleaseViewImages(_filesTab);
        [_filesTab removeFromSuperview];
        _filesTab = nil;
    }
    self.header.selectedTab = filesTab ? 2 : 0;
    self.list.hidden = filesTab || !_conversationID || _refused;
    self.composer.hidden = filesTab || !_shown;
}

/// Until the source knows the conversation (a link to a channel not loaded yet) the column shows
/// the history loading with neither header nor composer, so nothing is written to the one before;
/// once Slack refuses it (deleted, private, never existed), Slack's unavailable state instead.
- (void)showConversationIfKnown {
    SNConversation *conversation = _conversationID ? [_source conversationWithID:_conversationID] : nil;
    BOOL unavailable = _refused = !conversation && _conversationID && [_source isConversationUnavailable:_conversationID];
    if (unavailable && !_unavailable) {
        _unavailable = [[SNUnavailableConversationView alloc] initWithFrame:_view.bounds];
        [_view addSubview:_unavailable];
    }
    _unavailable.hidden = !unavailable;
    self.list.hidden = !_conversationID || unavailable;
    self.header.hidden = self.composer.hidden = !conversation;
    if (!_shown) [self.composer showConversation:conversation ? _conversationID : nil threadTS:nil];
    if (conversation && !_shown) {
        _shown = conversation;
        // The "Novo" line stays where it was when the conversation opened, after it is read.
        _lastRead = conversation.lastRead;
        [self.header showConversation:conversation closable:_navigator.location.tab == SNTabDirectMessages];
    }
    if (_conversationID) [_source loadConversation:_conversationID];
    [self reloadMessages];
    [self showFilesTabIfChosen];
}

- (void)reloadMessages {
    NSArray<SNMessage *> *messages = _conversationID ? [_source messagesInConversation:_conversationID] : @[];
    [self.list showMessages:messages inConversation:_conversationID threadTS:nil lastRead:_shown ? _lastRead : nil];
}

- (void)sourceChanged:(SNChange *)change {
    BOOL stale = [self.list applyChange:change];
    if (!_conversationID) return;
    if (!_shown) {
        if ([change.conversations containsObject:_conversationID]) {
            [self showConversationIfKnown];
            return;
        }
    } else {
        SNConversation *conversation = [_source conversationWithID:_conversationID];
        // A DM's title, picture and presence, and a group DM's names, come from its people.
        BOOL people = ([change.users count] && (conversation.kind == SNConversationGroupDirect ||
                                                              (conversation.userID && [change.users containsObject:conversation.userID]))) ||
                      (conversation.userID && [change.presence containsObject:conversation.userID]);
        if (conversation && ([change.conversations containsObject:_conversationID] || people)) {
            _shown = conversation;
            [self.header showConversation:conversation closable:_navigator.location.tab == SNTabDirectMessages];
            if ([change.conversations containsObject:_conversationID] && conversation.hasUnreads && conversation.lastRead &&
                ([SNMessageListView isReadHeldForKey:_conversationID] || !_lastRead || SNCompareTS(conversation.lastRead, _lastRead) == NSOrderedAscending)) {
                _lastRead = conversation.lastRead;
                [self.list updateLastRead:_lastRead];
            }
        }
    }
    if (stale || ([change.messages containsObject:_conversationID] && ![self.list showChangedMessages:change])) [self reloadMessages];
}

#pragma mark List delegate

- (void)messageList:(SNMessageListView *)list openThreadOfMessage:(SNMessage *)message {
    [_navigator openThread:message.threadTS ?: message.ts inConversation:message.conversationID ?: _conversationID];
}

- (void)messageList:(SNMessageListView *)list activateTarget:(SNRenderTarget *)target inMessage:(SNMessage *)message {
    SNActivateTarget(target, message, _navigator);
}

- (void)messageListDidFinishEditing:(SNMessageListView *)list { [self.composer focus]; }

- (void)focusForTyping {
    if (_browser && !_browser.hidden) [_browser focusSearch];
    else if (_filesBrowser && !_filesBrowser.hidden) [_filesBrowser focusSearch];
    else if (!self.composer.hidden) [self.composer focus];
}

/// Up in an empty composer edits the user's latest message shown here.
- (void)editLastOf:(NSArray<SNMessage *> *)messages {
    for (SNMessage *message in messages.reverseObjectEnumerator)
        if (!message.isReply && SNMessageIsEditable(message, _source)) {
            [self.list editMessage:message];
            return;
        }
}

@end
