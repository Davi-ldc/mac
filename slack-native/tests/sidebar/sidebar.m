// The Home sidebar's contents from the sections, navigation, updates from the source by changed
// IDs, collapse, hover without layout, the cost of a long list, and the header's filter with its
// keyboard.
#import <QuartzCore/QuartzCore.h>

#import "app/launch.h"
#import "render/strings.h"
#import "store/fixture.h"
#import "test.h"
#import "ui/kit/avatar.h"
#import "ui/kit/button.h"
#import "ui/shell/shell.h"
#import "ui/sidebar/pane.h"

/// Records moves instead of making them.
@interface SNSidebarTestNavigator : NSObject <SNNavigator>
@property (nonatomic) SNLocation *location;
@property (nonatomic) NSMutableArray<NSString *> *opened;
@property (nonatomic, copy) NSString *searched;
@end

@implementation SNSidebarTestNavigator
- (instancetype)init {
    if (!(self = [super init])) return nil;
    _location = [SNLocation locationWithTab:SNTabHome conversation:nil thread:nil];
    _opened = [NSMutableArray new];
    return self;
}
- (void)go:(SNLocation *)location { self.location = location; }
- (void)openConversation:(NSString *)conversationID { [self.opened addObject:conversationID]; }
- (void)openThread:(NSString *)threadTS inConversation:(NSString *)conversationID {}
- (void)closeThread {}
- (void)selectTab:(SNTab)tab {}
- (void)openSearchWithQuery:(NSString *)query { self.searched = query; }
- (void)resetSidebarFilter {}
@end

/// The pane in an offscreen window at the live column's size.
static SNSidebarPane *PaneOn(id<SNSource> source, SNSidebarTestNavigator *navigator) {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 311, 893) styleMask:NSWindowStyleMaskBorderless
                                                     backing:NSBackingStoreBuffered
                                                       defer:YES];
    window.releasedWhenClosed = NO;
    SNSidebarPane *pane = [[SNSidebarPane alloc] initWithSource:source navigator:navigator];
    pane.view.frame = window.contentView.bounds;
    [window.contentView addSubview:pane.view];
    [pane.view layoutSubtreeIfNeeded];
    [pane.list layoutSubtreeIfNeeded];
    return pane;
}

static NSArray<NSString *> *Keys(SNSidebarPane *pane, SNSidebarItemKind kind) {
    NSMutableArray *keys = [NSMutableArray new];
    for (SNSidebarItem *item in pane.list.items)
        if (item.kind == kind) [keys addObject:item.key];
    return keys;
}

SN_TEST(SidebarListsTheSectionsOfThePublicFixture) {
    SNSetLanguage(@"en");
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    SNSidebarPane *pane = PaneOn(source, [SNSidebarTestNavigator new]);
    NSArray<NSString *> *headings = Keys(pane, SNSidebarItemHeading);
    // users.channelSections chains stars -> Projects -> channels -> DMs.
    SNExpect(headings.count == 4, "a heading per section");
    SNExpect([headings.firstObject isEqualToString:[SNSidebarPane keyForSection:@"L01STARS"]], "sections in their chained order");
    SNExpect(Keys(pane, SNSidebarItemPage).count == 4, "four page links");
    SNExpect([pane.list itemForKey:[SNSidebarPane keyForConversation:@"C03DESIGN" inSection:@"L01STARS"]] != nil, "a starred channel under Starred");
    SNExpect([pane.list itemForKey:[SNSidebarPane keyForConversation:@"C03DESIGN" inSection:@"L03CHANNELS"]] == nil,
             "a channel in another section is not repeated under Channels");
    SNExpect([pane.list itemForKey:[SNSidebarPane keyForConversation:@"D05SAM" inSection:@"L04DMS"]] != nil, "DMs under Direct messages");
    SNExpect([pane.list itemForKey:[SNSidebarPane keyForConversation:@"G07MPDM" inSection:@"L04DMS"]] != nil, "group DMs too");
    SNExpect(Keys(pane, SNSidebarItemAdd).count == 1, "Add channels ends the channels section");
    SNExpect(Keys(pane, SNSidebarItemHint).count == 0, "no hint under a section with conversations");
    SNSetLanguage(@"pt-BR");
}

SN_TEST(SidebarRowsShowTheirConversationState) {
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    SNSidebarTestNavigator *navigator = [SNSidebarTestNavigator new];
    SNSidebarPane *pane = PaneOn(source, navigator);
    for (SNSidebarItem *item in pane.list.items) {
        if (item.kind != SNSidebarItemConversation) continue;
        SNConversation *conversation = [source conversationWithID:item.conversationID];
        SNSidebarRowState *state = [pane.list.delegate sidebarList:pane.list stateForItem:item];
        SNExpect(state.unread == conversation.hasUnreads, "unread follows the counts");
        SNExpect(state.mentions == (conversation.isMuted ? 0 : conversation.mentionCount), "mention badge unless muted");
        if (conversation.kind == SNConversationDirect) SNExpect(state.user != nil && state.title.length, "a DM shows its person");
        if (conversation.kind == SNConversationGroupDirect) SNExpect(state.memberCount > 0 && [state.title containsString:@", "], "a group DM lists its members");
        if (conversation.kind == SNConversationPrivateChannel) SNExpect([state.icon isEqualToString:@"lock"], "private channels show a lock");
    }
    [pane showLocation:[SNLocation locationWithTab:SNTabHome conversation:@"C01GENERAL" thread:nil]];
    SNSidebarRowView *row = [pane.list rowForKey:[SNSidebarPane keyForConversation:@"C01GENERAL" inSection:@"L03CHANNELS"]];
    SNExpect(row.state.selected, "the open conversation's row is selected");
    SNExpect(row.hoverColor == 0, "a selected row does not change under the pointer");

    NSString *dm = [SNSidebarPane keyForConversation:@"D05SAM" inSection:@"L04DMS"];
    SNSidebarRowView *dmRow = [pane.list rowForKey:dm];
    SNAvatarView *avatar = nil;
    for (NSView *view in dmRow.subviews)
        if ([view isKindOfClass:SNAvatarView.class]) avatar = (SNAvatarView *)view;
    SNExpect(avatar != nil && !avatar.hidden && avatar.imageURL != nil, "a DM row has its person's avatar");
    dmRow.pressed = YES;
    [dmRow mouseUp:[NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0
                                       context:nil eventNumber:0 clickCount:1 pressure:0]];
    SNExpect([navigator.opened.lastObject isEqualToString:@"D05SAM"], "clicking a row opens its conversation through the navigator");
}

SN_TEST(SidebarUpdatesOnlyTheChangedRows) {
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    SNSidebarPane *pane = PaneOn(source, [SNSidebarTestNavigator new]);
    NSString *general = [SNSidebarPane keyForConversation:@"C01GENERAL" inSection:@"L03CHANNELS"];
    NSString *random = [SNSidebarPane keyForConversation:@"C02RANDOM" inSection:@"L03CHANNELS"];
    SNSidebarRowView *generalRow = [pane.list rowForKey:general], *randomRow = [pane.list rowForKey:random];
    SNSidebarRowState *before = randomRow.state;
    [source setDraft:@"hello" inConversation:@"C01GENERAL" threadTS:nil];
    SNExpect([pane.list rowForKey:general] == generalRow && generalRow.state.draft, "the changed row redraws with its draft");
    SNExpect(randomRow.state == before, "other rows are left alone");
    [source setDraft:nil inConversation:@"C01GENERAL" threadTS:nil];
    SNExpect(!generalRow.state.draft, "the draft marker goes with the draft");
}

SN_TEST(SidebarCollapsesASection) {
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    SNSidebarPane *pane = PaneOn(source, [SNSidebarTestNavigator new]);
    NSString *heading = [SNSidebarPane keyForSection:@"L03CHANNELS"];
    NSUInteger before = pane.list.items.count;
    SNSidebarRowView *row = [pane.list rowForKey:heading];
    [pane.list hoverKey:heading];
    SNExpect(row.state && ![row actionButton:@"menu"].hidden, "the heading shows its menu button under the pointer");
    row.action(row);
    SNExpect(pane.list.items.count < before && [pane.list rowForKey:heading] == row, "rows go at once, the heading row stays");
    SNExpect([pane.list itemForKey:[SNSidebarPane keyForConversation:@"C02RANDOM" inSection:@"L03CHANNELS"]] == nil,
             "read channels hide in a collapsed section");
    SNExpect([pane.list itemForKey:[SNSidebarPane keyForConversation:@"C01GENERAL" inSection:@"L03CHANNELS"]] != nil,
             "unread ones stay");
    SNExpect(row.state.collapsed && row.state.unread, "the collapsed heading is bold with its unreads");
    row.action(row);
    SNExpect(pane.list.items.count == before, "expanding brings them back");
}

/// Hovering must not lay anything out: a row's state changes its layers and nothing else.
SN_TEST(SidebarHoversWithoutLayoutAndScrollsALongList) {
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    SNSidebarPane *pane = PaneOn(source, [SNSidebarTestNavigator new]);
    NSMutableArray<SNSidebarItem *> *items = [NSMutableArray new];
    for (NSUInteger i = 0; i < 600; i++) {
        SNSidebarItem *item = [SNSidebarItem new];
        item.kind = SNSidebarItemConversation;
        item.key = [NSString stringWithFormat:@"L03CHANNELS/C01GENERAL#%lu", (unsigned long)i];
        item.conversationID = @"C01GENERAL";
        item.height = 28;
        [items addObject:item];
    }
    [pane.list showItems:items];
    [pane.list layoutSubtreeIfNeeded];
    NSUInteger rows = 0;
    for (NSView *view in pane.list.scrollView.documentView.subviews) rows += !view.hidden;
    SNExpect(rows < 50, "only the visible rows exist");
    [pane.list hoverKey:items[3].key];
    SNExpect(!pane.list.needsLayout && !pane.list.scrollView.documentView.needsLayout, "hover lays nothing out");

    CFTimeInterval start = CACurrentMediaTime();
    NSClipView *clip = pane.list.scrollView.contentView;
    for (NSUInteger step = 0; step < 300; step++) {
        [clip scrollToPoint:NSMakePoint(0, step * 50)];
        [pane.list.scrollView reflectScrolledClipView:clip];
    }
    double perFrame = (CACurrentMediaTime() - start) / 300 * 1000;
    printf("     sidebar scroll through 600 rows: %.2f ms per step\n", perFrame);
    SNExpect(perFrame < 4, "scrolling a long list stays cheap");
}

SN_TEST(SidebarPeekAndClose) {
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    SNSidebarPane *pane = PaneOn(source, [SNSidebarTestNavigator new]);
    NSView *peek = pane.peekView;
    SNSidebarListView *peekList = nil;
    for (NSView *view in peek.subviews)
        if ([view isKindOfClass:SNSidebarListView.class]) peekList = (SNSidebarListView *)view;
    SNExpect(peek.frame.size.width == SNPeekWidth && peekList.items.count == pane.list.items.count, "the Home peek lists the sidebar");

    NSString *dm = [SNSidebarPane keyForConversation:@"D05SAM" inSection:@"L04DMS"];
    [pane.list hoverKey:dm];
    SNSidebarRowView *row = [pane.list rowForKey:dm];
    SNHoverView *close = [row actionButton:@"close"];
    SNExpect(close && !close.hidden, "a hovered DM shows its close button");
    close.action(close);
    SNExpect([pane.list itemForKey:dm] == nil && [peekList itemForKey:dm] == nil, "closing the DM takes it out of the sidebar and the peek");
}

static NSEvent *Key(unsigned short code, NSEventModifierFlags modifiers) {
    return [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:modifiers timestamp:0 windowNumber:0 context:nil
                          characters:@"" charactersIgnoringModifiers:@"" isARepeat:NO keyCode:code];
}

/// Types into the header's field the way the keyboard does, then lets the filter settle.
static void Type(SNSidebarPane *pane, NSString *text) {
    SNFilterField *field = pane.header.filterField;
    [field focus];
    NSTextView *editor = (NSTextView *)field.textField.currentEditor;
    [editor selectAll:nil];
    [editor insertText:text replacementRange:editor.selectedRange];
}

/// The field editor's command, as a key bound to it sends it.
static void Command(SNSidebarPane *pane, SEL command) {
    [(NSTextView *)pane.header.filterField.textField.currentEditor doCommandBySelector:command];
}

SN_TEST(SidebarFilterFindsConversationsInPlace) {
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    SNSidebarPane *pane = PaneOn(source, [SNSidebarTestNavigator new]);
    SNFilterField *field = pane.header.filterField;
    NSUInteger all = pane.list.items.count;
    [field focus];
    SNExpect(field.focused, "clicking the field gives it the caret in place");
    Type(pane, @"GEN");
    SNExpect(pane.list.items.count == all, "the list waits for the typing to settle");
    SNExpect(!field.clearButton.hidden, "the clear button shows with the text");
    SNSettle(0.25);
    NSArray *keys = [pane.list.items valueForKey:@"key"];
    NSArray *general = @[ [SNSidebarPane keyForSection:@"L03CHANNELS"], [SNSidebarPane keyForConversation:@"C01GENERAL" inSection:@"L03CHANNELS"] ];
    SNExpect([keys isEqualToArray:general], "only the matching channel under its section, no page links (case ignored)");

    Type(pane, @"sam c");
    SNSettle(0.25);
    keys = [pane.list.items valueForKey:@"key"];
    SNExpect([keys containsObject:[SNSidebarPane keyForConversation:@"D05SAM" inSection:@"L04DMS"]] &&
                 [keys containsObject:[SNSidebarPane keyForConversation:@"G07MPDM" inSection:@"L04DMS"]],
             "people match by name, spaces ignored, in DMs and group DMs");
    SNExpect(![keys containsObject:[SNSidebarPane keyForConversation:@"D06PRIYA" inSection:@"L04DMS"]], "others do not");

    Type(pane, @"de-sign");
    SNSettle(0.25);
    keys = [pane.list.items valueForKey:@"key"];
    NSArray *design = @[
        [SNSidebarPane keyForSection:@"L01STARS"], [SNSidebarPane keyForConversation:@"C03DESIGN" inSection:@"L01STARS"], @"gap:L02PROJECTS",
        [SNSidebarPane keyForSection:@"L02PROJECTS"], [SNSidebarPane keyForConversation:@"C03DESIGN" inSection:@"L02PROJECTS"]
    ];
    SNExpect([keys isEqualToArray:design], "hyphens ignored, sections in the sidebar's order");

    Command(pane, @selector(cancelOperation:));
    SNExpect(field.text.length == 0 && pane.list.items.count == all && field.focused, "Escape empties the field at once and keeps the caret");
}

SN_TEST(SidebarFilterOpensCollapsedSectionsAndOffersSearch) {
    SNSetLanguage(@"en");
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    SNSidebarTestNavigator *navigator = [SNSidebarTestNavigator new];
    SNSidebarPane *pane = PaneOn(source, navigator);
    NSString *heading = [SNSidebarPane keyForSection:@"L03CHANNELS"], *random = [SNSidebarPane keyForConversation:@"C02RANDOM" inSection:@"L03CHANNELS"];
    [source setSection:@"L03CHANNELS" collapsed:YES];
    SNExpect([pane.list itemForKey:random] == nil, "a read channel hides in its collapsed section");
    Type(pane, @"rand");
    SNSettle(0.25);
    SNSidebarRowView *row = [pane.list rowForKey:heading];
    SNExpect([pane.list itemForKey:random] != nil && !row.state.collapsed, "filtering shows the section open with its match");
    [source setSection:@"L03CHANNELS" collapsed:NO];

    Type(pane, @"zzz");
    SNSettle(0.25);
    SNExpect(pane.list.items.count == 1 && pane.list.items.firstObject.kind == SNSidebarItemNoResults, "nothing found: one entry says so");
    SNSidebarRowView *empty = [pane.list rowForKey:@"noResults"];
    SNButton *search = (SNButton *)[empty actionButton:@"search"];
    SNExpect([empty.state.title isEqualToString:@"No conversations to show…"] && [search.title isEqualToString:@"Search Northwind Studio"],
             "with a button that searches the workspace");
    search.action(search);
    SNExpect([navigator.searched isEqualToString:@"zzz"], "which searches for the text");
    SNExpect(pane.header.filterField.text.length == 0 && [pane.list itemForKey:@"page:0"] != nil, "and empties the filter");

    Type(pane, @"gen");
    SNSettle(0.25);
    [pane resetFilters];
    SNExpect(pane.header.filterField.text.length == 0 && [pane.list itemForKey:@"page:0"] != nil, "Slack's reset empties it too");
    Type(pane, @"gen");
    SNSettle(0.25);
    [pane showLocation:[SNLocation locationWithTab:SNTabDirectMessages conversation:nil thread:nil]];
    SNExpect(pane.header.filterField.text.length == 0, "and so does leaving the Home tab");
    SNSetLanguage(@"pt-BR");
}

SN_TEST(SidebarFilterHandsTheKeyboardToTheList) {
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    SNSidebarTestNavigator *navigator = [SNSidebarTestNavigator new];
    SNSidebarPane *pane = PaneOn(source, navigator);
    SNFilterField *field = pane.header.filterField;
    Type(pane, @"e");
    SNSettle(0.25);
    Command(pane, @selector(insertNewline:));
    SNExpect(field.focused && navigator.opened.count == 0, "Return in the field opens nothing");
    Command(pane, @selector(moveDown:));
    NSString *first = pane.list.items.firstObject.key;
    SNExpect(pane.list.window.firstResponder == pane.list && [pane.list.focusedKey isEqualToString:first], "Down moves the keyboard to the first row");
    SNExpect(!field.focused, "the field lets the caret go");
    [pane.list keyDown:Key(126, 0)];
    SNExpect([pane.list.focusedKey isEqualToString:first], "Up stops at the first row");
    [pane.list keyDown:Key(125, NSEventModifierFlagFunction | NSEventModifierFlagNumericPad)];
    SNSidebarItem *item = [pane.list itemForKey:pane.list.focusedKey];
    SNExpect(item.kind == SNSidebarItemConversation, "Down moves to the next row");
    [pane.list keyDown:Key(36, 0)];
    SNExpect([navigator.opened.lastObject isEqualToString:item.conversationID], "Return opens it");
    [pane.list keyDown:Key(48, NSEventModifierFlagShift)];
    SNExpect(field.focused && pane.list.focusedKey == nil, "Shift-Tab goes back to the field");
    [field.window makeFirstResponder:nil];
    SNExpect(!field.focused, "the caret leaves with the focus");
}
