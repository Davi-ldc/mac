// What the huddle UI shows for each state, made-up data: the header's control (idle, a huddle to
// join, the user in it), the sidebar's badge and the DM headphones, huddle messages and their
// wording, call blocks, the invitation and the call footer with their buttons, and that nothing
// offers to join when the build cannot; then the real store's events driving the same views.
#import "model/json.h"
#import "render/message.h"
#import "source.h"
#import "test.h"
#import "ui/channel/messagelayout.h"
#import "ui/channel/pane.h"
#import "ui/huddle/footer.h"
#import "ui/kit/popover.h"
#import "ui/profile/profilecard.h"
#import "ui/shell/shell.h"
#import "ui/sidebar/pane.h"

static SNHuddle *Huddle(NSString *roomID, NSString *conversationID, NSArray<NSString *> *people, BOOL ended) {
    return [SNHuddle huddleWithJSON:SNTestRoom(roomID, conversationID, people, ended)];
}

static SNCall *Call(NSString *conversationID, SNCallState state, BOOL muted, NSSet<NSString *> *speaking) {
    return [[SNCall alloc] initWithConversationID:conversationID huddleID:@"R01LIVE" state:state muted:muted speaking:speaking mutedUsers:[NSSet set]];
}

static SNShell *ShellOn(SNHuddleFixture *source, NSString *conversationID) {
    SNShell *shell = [[SNShell alloc] initWithSource:source defaults:nil];
    [shell go:[SNLocation locationWithTab:SNTabHome conversation:conversationID thread:nil]];
    SNSettle(0.05);
    return shell;
}

static SNChannelHeader *HeaderOf(SNShell *shell) { return ((SNChannelPane *)[shell paneInSlot:SNPaneSlotPrimary]).header; }
static SNSidebarPane *SidebarOf(SNShell *shell) { return (SNSidebarPane *)[shell paneInSlot:SNPaneSlotSidebar]; }

static SNHuddleSidebarFooter *FooterOf(SNShell *shell) {
    for (NSView *view in SidebarOf(shell).view.subviews)
        if ([view isKindOfClass:SNHuddleSidebarFooter.class]) return (SNHuddleSidebarFooter *)view;
    return nil;
}

static SNSidebarRowState *RowState(SNShell *shell, NSString *conversationID, NSString *section) {
    SNSidebarListView *list = SidebarOf(shell).list;
    SNSidebarItem *item = [list itemForKey:[SNSidebarPane keyForConversation:conversationID inSection:section]];
    return item ? [list.delegate sidebarList:list stateForItem:item] : nil;
}

static void Click(SNHoverView *view) {
    if (view.enabled && view.action) view.action(view);
}

SN_TEST(HuddleHeaderFollowsTheHuddleAndTheCall) {
    SNHuddleFixture *source = [SNHuddleFixture fixture];
    SNShell *shell = ShellOn(source, @"C02RANDOM");
    SNHuddleHeaderControl *control = HeaderOf(shell).huddle;
    CGFloat idle = control.preferredWidth;
    SNExpect(idle == 48 && !control.button.title, "idle: the 28 pt headphones and the 20 pt caret");
    [source setHuddle:Huddle(@"R01LIVE", @"C02RANDOM", @[ @"U02SAM", @"U03PRIYA" ], NO) inConversation:@"C02RANDOM"];
    SNExpect([control.button.title isEqualToString:@"2"], "a huddle going on shows how many are in it");
    // 2 + 2 faces of 20 + 8, the 20 pt glyph, 4 and the count, 4; then the caret.
    SNExpect(control.preferredWidth > idle + 40, "and their faces before the headphones");
    Click(control.button);
    SNExpect([source.joined isEqualToArray:@[ @"C02RANDOM" ]], "the button joins it");
    source.fakeCall = Call(@"C02RANDOM", SNCallConnected, YES, [NSSet set]);
    SNExpect(!control.button.title && control.preferredWidth == idle, "in it: the leave button alone");
    Click(control.button);
    SNExpect(source.leaves == 1, "which leaves");
    source.fakeCall = nil;
    source.joinable = NO;
    [source setHuddle:Huddle(@"R01LIVE", @"C02RANDOM", @[ @"U02SAM" ], NO) inConversation:@"C02RANDOM"];
    Click(control.button);
    SNExpect(source.joined.count == 1 && [control.button.title isEqualToString:@"1"], "without libwebrtc it shows the huddle but cannot join");
    [source setHuddle:nil inConversation:@"C02RANDOM"];
    SNExpect(control.preferredWidth == idle, "an ended huddle leaves the idle button");
}

static NSView *FindView(NSView *view, Class viewClass) {
    if ([view isKindOfClass:viewClass]) return view;
    for (NSView *subview in view.subviews) {
        NSView *found = FindView(subview, viewClass);
        if (found) return found;
    }
    return nil;
}

/// The options caret's menu, with its first item chosen; NO when no menu opened.
static BOOL ChooseFromOptions(SNHuddleHeaderControl *control) {
    Click(control.options);
    SNMenu *menu = (SNMenu *)FindView(SNPopover.current.content, SNMenu.class);
    if (!menu) return NO;
    menu.highlightedIndex = 0;
    [menu keyDown:[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0 context:nil
                                 characters:@"\r" charactersIgnoringModifiers:@"\r" isARepeat:NO keyCode:36]];
    [SNPopover.current close];
    return YES;
}

SN_TEST(HuddleHeaderStartsAHuddle) {
    SNHuddleFixture *source = [SNHuddleFixture fixture];
    SNShell *shell = ShellOn(source, @"C02RANDOM");
    SNHuddleHeaderControl *control = HeaderOf(shell).huddle;
    SNExpect([control.button.tooltip isEqualToString:@"Start huddle in #random"], "idle, the button offers to start a huddle in the channel");
    Click(control.button);
    SNExpect([source.joined isEqualToArray:@[ @"C02RANDOM" ]], "and starts it");
    source.fakeCall = Call(@"C02RANDOM", SNCallJoining, YES, [NSSet set]);
    SNExpect(!control.button.title && [control.button.tooltip isEqualToString:@"Leave huddle"], "while it starts, the control is already the leave button");
    SNExpect(!ChooseFromOptions(control), "and the caret has nothing it can offer");
    source.fakeCall = nil;
    SNExpect(ChooseFromOptions(control) && source.joined.count == 2, "idle, the caret's Start Huddle starts it too");
    [source setHuddle:Huddle(@"R01LIVE", @"C02RANDOM", @[ @"U02SAM" ], NO) inConversation:@"C02RANDOM"];
    SNExpect([control.button.tooltip isEqualToString:@"Join huddle in #random"] && ChooseFromOptions(control) && source.joined.count == 3,
             "with a huddle going on, the caret joins it");

    [shell go:[SNLocation locationWithTab:SNTabHome conversation:@"D05SAM" thread:nil]];
    SNSettle(0.05);
    control = HeaderOf(shell).huddle;
    SNExpect([control.button.tooltip isEqualToString:@"Start huddle with Sam Chen"], "a DM's button starts a huddle with the person");
    Click(control.button);
    SNExpect([source.joined.lastObject isEqualToString:@"D05SAM"], "there");

    source.joinable = NO;
    [shell go:[SNLocation locationWithTab:SNTabHome conversation:@"C02RANDOM" thread:nil]];
    SNSettle(0.05);
    control = HeaderOf(shell).huddle;
    [source setHuddle:nil inConversation:@"C02RANDOM"];
    Click(control.button);
    SNExpect(source.joined.count == 4 && !ChooseFromOptions(control), "without libwebrtc nothing starts");
}

SN_TEST(HuddleSidebarShowsBadgesAndHeadphones) {
    SNHuddleFixture *source = [SNHuddleFixture fixture];
    SNShell *shell = ShellOn(source, @"C01GENERAL");
    SNExpect(RowState(shell, @"C02RANDOM", @"L03CHANNELS").huddleCount == 0, "no badge without a huddle");
    [source setHuddle:Huddle(@"R01LIVE", @"C02RANDOM", @[ @"U02SAM", @"U03PRIYA", @"U04JORDAN" ], NO) inConversation:@"C02RANDOM"];
    SNSidebarRowState *state = RowState(shell, @"C02RANDOM", @"L03CHANNELS");
    SNExpect(state.huddleCount == 3 && state.huddleFaces.count == 2 && !state.myHuddle, "the badge counts everyone, two faces before it");
    source.fakeCall = Call(@"C02RANDOM", SNCallConnected, YES, [NSSet set]);
    SNExpect(RowState(shell, @"C02RANDOM", @"L03CHANNELS").myHuddle, "the user's own huddle");
    [source setHuddle:Huddle(@"R00DONE", @"C02RANDOM", @[ @"U02SAM" ], YES) inConversation:@"C02RANDOM"];
    SNExpect(RowState(shell, @"C02RANDOM", @"L03CHANNELS").huddleCount == 0, "an ended huddle has no badge");
    SNExpect(!RowState(shell, @"D05SAM", @"L04DMS").userInHuddle, "a DM's person outside huddles keeps their status");
    source.usersInHuddles = [NSSet setWithObject:@"U02SAM"];
    SNExpect(RowState(shell, @"D05SAM", @"L04DMS").userInHuddle, "in a huddle, the headphones take its place");
}

SN_TEST(HuddleMessagesSayWhoIsThere) {
    SNHuddleFixture *source = [SNHuddleFixture fixture];
    SNRenderer *renderer = [[SNRenderer alloc] initWithSource:source];
    SNMessage * (^message)(NSDictionary *) = ^(NSDictionary *room) {
        return [SNMessage messageWithJSON:@{@"type" : @"message", @"subtype" : @"huddle_thread", @"user" : @"U02SAM", @"ts" : @"1795294800.000110", @"text" : @"", @"room" : room}
                           conversationID:SNJSONStrings(room, @"channels").firstObject];
    };
    NSString * (^said)(NSDictionary *) = ^(NSDictionary *room) { return [renderer documentForMessage:message(room)].plainText; };
    SNExpect([said(SNTestRoom(@"R1", @"C02RANDOM", @[ @"U02SAM", @"U03PRIYA" ], NO)) isEqualToString:@"Sam Chen and priya are already there."], "live, without the user");
    SNExpect([said(SNTestRoom(@"R1", @"C02RANDOM", @[ @"U02SAM", @"U03PRIYA", @"U04JORDAN" ], NO)) isEqualToString:@"Sam Chen and 2 others are already there."], "the first and how many others");
    SNExpect([said(SNTestRoom(@"R1", @"C02RANDOM", @[ @"U01ALEX", @"U02SAM" ], NO)) isEqualToString:@"Sam Chen is here too."], "live, with the user");
    SNExpect([said(SNTestRoom(@"R1", @"C02RANDOM", @[ @"U01ALEX" ], NO)) hasPrefix:@"You’re the only one here."], "the user alone");
    SNExpect([said(SNTestRoom(@"R1", @"C02RANDOM", @[ @"U01ALEX", @"U02SAM", @"U05TAYLOR" ], YES)) isEqualToString:@"You, Sam Chen, and Taylor Kim were in the huddle for 25m."], "ended, with the user");
    SNExpect([said(SNTestRoom(@"R1", @"C02RANDOM", @[ @"U02SAM" ], YES)) isEqualToString:@"Sam Chen was in the huddle for 25m."], "ended, without");
    SNExpect([said(SNTestRoom(@"R1", @"D05SAM", @[ @"U02SAM" ], NO)) isEqualToString:@""], "a DM's huddle says nothing while it goes on without the user");

    SNMessage *live = message(SNTestRoom(@"R01LIVE", @"C02RANDOM", @[ @"U02SAM", @"U03PRIYA" ], NO));
    SNExpect([[renderer huddleStatusOfMessage:live] isEqualToString:@"A huddle is happening"], "the status in the sender's place");
    SNMessageLayout *layout = [SNMessageLayout layoutForMessage:live continuation:NO style:SNMessageRowInConversation width:842 renderer:renderer];
    SNExpect(layout.isHuddle && layout.huddleLive && !NSIsEmptyRect(layout.liveBadgeRect), "live: the LIVE badge after the status");
    SNExpect(!NSIsEmptyRect(layout.joinRect) && layout.huddleFaces.count == 2, "Join Huddle with the faces under the text");
    SNExpect(NSMinX(layout.timeRect) > NSMaxX(layout.liveBadgeRect), "the time after the badge");
    source.joinable = NO;
    SNExpect(NSIsEmptyRect([SNMessageLayout layoutForMessage:live continuation:NO style:SNMessageRowInConversation width:842 renderer:renderer].joinRect),
             "no Join without libwebrtc");
    source.joinable = YES;
    // The store's copy of the same room wins: the huddle ended since the message was cached.
    [source setHuddle:Huddle(@"R01LIVE", @"C02RANDOM", @[ @"U02SAM", @"U03PRIYA" ], YES) inConversation:@"C02RANDOM"];
    SNMessageLayout *ended = [SNMessageLayout layoutForMessage:live continuation:NO style:SNMessageRowInConversation width:842 renderer:renderer];
    SNExpect(!ended.huddleLive && NSIsEmptyRect(ended.joinRect) && [ended.senderName isEqualToString:@"A huddle happened"], "an ended huddle's message");
}

SN_TEST(HuddleCallBlocksShowTheCall) {
    SNHuddleFixture *source = [SNHuddleFixture fixture];
    SNRenderer *renderer = [[SNRenderer alloc] initWithSource:source];
    renderer.now = [NSDate dateWithTimeIntervalSince1970:1795294800 + 600];
    NSDictionary *block = @{@"type" : @"call", @"call_id" : @"R0CALL", @"api_decoration_available" : @NO,
                            @"call" : @{@"v1" : @{@"id" : @"R0CALL", @"app_id" : @"A0VIDEO", @"name" : @"Weekly review", @"date_start" : @1795294800,
                                                  @"active_participants" : @[ @{@"slack_id" : @"U02SAM"} ], @"all_participants" : @[ @{@"slack_id" : @"U02SAM"} ],
                                                  @"join_url" : @"https://video.example.com/j/123", @"display_id" : @"123"}}};
    NSString *text = [[SNRenderDocument documentWithBlocks:[renderer blocksForBlockKit:@[ block ]]] plainText];
    SNExpect([text containsString:@"Weekly review"] && [text containsString:@"Started 10 minutes ago"], "the call's name and how long it has run");
    SNExpect([text containsString:@"Waiting for others to join"], "one person waits for others");
}

SN_TEST(HuddleFooterOffersTheInvitationAndTheCall) {
    SNHuddleFixture *source = [SNHuddleFixture fixture];
    SNShell *shell = ShellOn(source, @"C01GENERAL");
    SNHuddleSidebarFooter *footer = FooterOf(shell);
    SNExpect(footer && footer.preferredHeight == 0, "nothing at the bottom of the sidebar at first");
    SNHuddleInvite *invite = [SNHuddleInvite inviteWithJSON:@{@"channel_id" : @"C02RANDOM", @"call_id" : @"R01LIVE", @"sender_user_id" : @"U02SAM"} received:NSDate.date];
    source.invites = @[ invite ];
    SNExpect(footer.preferredHeight > 100 && footer.joinButton && footer.declineButton, "an invitation with Join and Decline");
    SNExpect(NSMaxY(SidebarOf(shell).list.frame) <= NSMinY(footer.frame) + 0.5, "the list ends above it");
    Click(footer.joinButton);
    SNExpect([source.joined isEqualToArray:@[ @"C02RANDOM" ]] && [source.dismissed containsObject:invite], "Join joins and the invitation goes");
    source.joinable = NO;
    source.invites = @[ [SNHuddleInvite inviteWithJSON:@{@"channel_id" : @"D05SAM", @"call_id" : @"R2", @"sender_user_id" : @"U02SAM"} received:NSDate.date] ];
    SNExpect(!footer.joinButton && footer.declineButton, "without libwebrtc only Decline");
    Click(footer.declineButton);
    SNExpect(source.invites.count == 0 && footer.preferredHeight == 0, "Decline dismisses it");

    [source setHuddle:Huddle(@"R01LIVE", @"C02RANDOM", @[ @"U01ALEX", @"U02SAM", @"U03PRIYA" ], NO) inConversation:@"C02RANDOM"];
    source.fakeCall = Call(@"C02RANDOM", SNCallConnected, YES, [NSSet set]);
    SNExpect(footer.micButton && footer.leaveButton && [footer.speakerID isEqualToString:@"U02SAM"], "the call: someone else in it, the mic, Leave");
    Click(footer.micButton);
    SNExpect([source.mutes isEqualToArray:@[ @NO ]], "the muted mic unmutes");
    source.fakeCall = Call(@"C02RANDOM", SNCallConnected, NO, [NSSet setWithObjects:@"U01ALEX", @"U03PRIYA", nil]);
    SNExpect([footer.speakerID isEqualToString:@"U03PRIYA"] && [footer.micButton.icon.iconName isEqualToString:@"microphone"], "the one heard, someone else before the user");
    Click(footer.leaveButton);
    SNExpect(source.leaves == 1, "Leave leaves");
    source.fakeCall = nil;
    SNExpect(footer.preferredHeight == 0 && !footer.micButton, "the footer goes with the call");
}

SN_TEST(HuddleProfileSaysInAHuddle) {
    SNHuddleFixture *source = [SNHuddleFixture fixture];
    SNUser *priya = [source userWithID:@"U03PRIYA"];
    CGFloat height = [[SNProfileCardView alloc] initWithUser:priya source:source].frame.size.height;
    source.usersInHuddles = [NSSet setWithObject:@"U03PRIYA"];
    SNExpect([[SNProfileCardView alloc] initWithUser:priya source:source].frame.size.height > height, "someone in a huddle gets its status line");
}

SN_TEST(HuddleUIFollowsTheStoresEvents) {
    // The real store (no overrides): sh_room_* and huddle_invite as the websocket sends them.
    SNFixtureSource *source = [SNFixtureSource sourceWithFolder:SNPublicFixture()];
    SNShell *shell = [[SNShell alloc] initWithSource:source defaults:nil];
    [shell go:[SNLocation locationWithTab:SNTabHome conversation:@"C01GENERAL" thread:nil]];
    NSDictionary *room = SNTestRoom(@"R0EVENT", @"C01GENERAL", @[ @"U02SAM", @"U03PRIYA" ], NO);
    [source applyEvent:@{@"type" : @"sh_room_join", @"user" : @"U03PRIYA", @"room" : room, @"huddle" : @{@"channel_id" : @"C01GENERAL"}, @"event_ts" : @"1795400000.000001"}];
    SNExpect([HeaderOf(shell).huddle.button.title isEqualToString:@"2"], "the header counts who joined");
    SNExpect(RowState(shell, @"C01GENERAL", @"L03CHANNELS").huddleCount == 2, "the sidebar row too");
    SNExpect(RowState(shell, @"D05SAM", @"L04DMS").userInHuddle, "and a participant's DM shows the headphones");
    [source applyEvent:@{@"type" : @"huddle_invite", @"channel_id" : @"C01GENERAL", @"call_id" : @"R0EVENT", @"sender_user_id" : @"U02SAM"}];
    SNExpect(FooterOf(shell).declineButton != nil, "an invitation shows at the bottom of the sidebar");
    [source applyEvent:@{@"type" : @"huddle_invite_cancel", @"channel_id" : @"C01GENERAL", @"call_id" : @"R0EVENT", @"sender_user_id" : @"U02SAM"}];
    SNExpect(FooterOf(shell).preferredHeight == 0, "and leaves when cancelled");
    NSDictionary *ended = SNTestRoom(@"R0EVENT", @"C01GENERAL", @[ @"U02SAM", @"U03PRIYA" ], YES);
    [source applyEvent:@{@"type" : @"sh_room_update", @"user" : @"U02SAM", @"room" : ended, @"huddle" : @{@"channel_id" : @"C01GENERAL"}, @"event_ts" : @"1795400000.000002"}];
    SNExpect(!HeaderOf(shell).huddle.button.title && RowState(shell, @"C01GENERAL", @"L03CHANNELS").huddleCount == 0, "an ended huddle leaves both");
}
