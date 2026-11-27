// The huddle UI rendered from the public fixture (no live capture of a huddle exists): checked
// against the CSS's colours at known points, and the header against channel_header_tabs_default
// wherever the huddle control leaves it as it was.
#import "snapshot.h"
#import "source.h"
#import "test.h"
#import "ui/channel/list.h"
#import "ui/channel/pane.h"
#import "ui/huddle/footer.h"
#import "ui/kit/popover.h"
#import "ui/shell/shell.h"
#import "ui/sidebar/pane.h"

static SNShell *Shell(SNHuddleFixture *source, NSString *conversationID, SNTab tab) {
    SNShell *shell = [[SNShell alloc] initWithSource:source defaults:nil];
    [shell setWindowActive:YES];
    [shell go:[SNLocation locationWithTab:tab conversation:conversationID thread:nil]];
    return shell;
}

/// A view's top-left in the window's pixels' points.
static NSPoint Origin(NSView *view, SNShell *shell) {
    NSRect rect = [view convertRect:view.bounds toView:nil];
    return NSMakePoint(NSMinX(rect), shell.window.contentView.bounds.size.height - NSMaxY(rect));
}

/// Within 3 of the token on each channel (the render is sRGB, the tokens are too).
static BOOL Near(uint32_t pixel, SNColorToken token) {
    for (int shift = 8; shift <= 24; shift += 8)
        if (abs((int)((pixel >> shift) & 0xff) - (int)((token >> shift) & 0xff)) > 3) return NO;
    return YES;
}

static SNHuddle *Live(NSArray<NSString *> *people) { return [SNHuddle huddleWithJSON:SNTestRoom(@"R01LIVE", @"C02RANDOM", people, NO)]; }

SN_SNAPSHOT(HuddleHeaderStates) {
    SNHuddleFixture *source = [SNHuddleFixture fixture];
    // The DMs tab, as the capture's window: the header is as wide there.
    SNShell *shell = Shell(source, @"C02RANDOM", SNTabDirectMessages);
    SNChannelHeader *header = ((SNChannelPane *)[shell paneInSlot:SNPaneSlotPrimary]).header;
    [source setHuddle:Live(@[ @"U02SAM", @"U03PRIYA" ]) inConversation:@"C02RANDOM"];
    SNPixels *active = SNRenderWindow(shell.window);
    NSPoint origin = Origin(header, shell), control = Origin(header.huddle, shell);
    CGFloat controlX = control.x - origin.x;
    // The capture is a DM's header: its title differs, and its huddle control is the idle one.
    SNCompareWithReference(@"huddle_header_active", active, @"channel_header_tabs_default", origin, 1, @[
        [SNRegion ignored:@"title (a channel here, a DM there)" rect:NSMakeRect(0, 0, controlX - 40, 49)],
        [SNRegion ignored:@"huddle control (no capture of a huddle)" rect:NSMakeRect(controlX - 30, 8, NSWidth(header.huddle.frame) + 30, 32)],
        [SNRegion region:@"bell, search, more" rect:NSMakeRect(NSMaxX(header.huddle.frame) + 4, 10, NSWidth(header.frame) - NSMaxX(header.huddle.frame) - 12, 32) budget:4],
        [SNRegion region:@"tabs" rect:NSMakeRect(16, 52, 400, 30) budget:15],
        [SNRegion region:@"tab bar line" rect:NSMakeRect(130, 86, 700, 2) budget:2],
    ]);
    SNExpect(Near([active colorAtPoint:NSMakePoint(control.x + 1, control.y + 14)], SNPaletteJade5), "the active container is jade-5");
    SNExpect(Near([active colorAtPoint:NSMakePoint(control.x + NSWidth(header.huddle.frame) - 2, control.y + 4)], SNPaletteJade5), "behind the caret too");

    source.fakeCall = [[SNCall alloc] initWithConversationID:@"C02RANDOM" huddleID:@"R01LIVE" state:SNCallConnected muted:YES speaking:[NSSet set] mutedUsers:[NSSet set]];
    SNSettle(0.3);
    SNPixels *inCall = SNRenderWindow(shell.window);
    control = Origin(header.huddle, shell);
    SNSaveSnapshot(@"huddle_header_in_call", inCall);
    SNExpect(Near([inCall colorAtPoint:NSMakePoint(control.x + 2, control.y + 4)], SNPaletteJade50), "in the huddle the jade-50 fill has slid in");
}

SN_SNAPSHOT(HuddleSidebarStates) {
    SNHuddleFixture *source = [SNHuddleFixture fixture];
    SNShell *shell = Shell(source, @"C01GENERAL", SNTabHome);
    SNSidebarPane *sidebar = (SNSidebarPane *)[shell paneInSlot:SNPaneSlotSidebar];
    [source setHuddle:Live(@[ @"U02SAM", @"U03PRIYA", @"U04JORDAN" ]) inConversation:@"C02RANDOM"];
    source.usersInHuddles = [NSSet setWithObjects:@"U02SAM", @"U03PRIYA", @"U04JORDAN", nil];
    source.invites = @[ [SNHuddleInvite inviteWithJSON:@{@"channel_id" : @"C02RANDOM", @"call_id" : @"R01LIVE", @"sender_user_id" : @"U02SAM"} received:NSDate.date] ];
    SNSettle(0.1);
    SNPixels *invited = SNRenderWindow(shell.window);
    SNSaveSnapshot(@"huddle_sidebar_invite", invited);
    SNSidebarRowView *row = [sidebar.list rowForKey:[SNSidebarPane keyForConversation:@"C02RANDOM" inSection:@"L03CHANNELS"]];
    NSPoint rowOrigin = Origin(row, shell);
    // The badge ends where the mention badge would, 16 pt from the row's right; its middle is
    // 14 pt down, its last 6 pt are padding.
    SNExpect(Near([invited colorAtPoint:NSMakePoint(rowOrigin.x + NSWidth(row.frame) - 16 - 3, rowOrigin.y + 14)], SNThemeBaseInvHgl1),
             "the channel's huddle badge is theme base-inv-hgl-1");
    SNHuddleSidebarFooter *footer = nil;
    for (NSView *view in sidebar.view.subviews)
        if ([view isKindOfClass:SNHuddleSidebarFooter.class]) footer = (SNHuddleSidebarFooter *)view;
    NSPoint footerOrigin = Origin(footer, shell);
    SNExpect(Near([invited colorAtPoint:NSMakePoint(footerOrigin.x + 30, footerOrigin.y + 8 + 4)], SNThemeBaseInvPry), "the invitation's box is theme base-inv-pry");

    source.invites = @[];
    source.fakeCall = [[SNCall alloc] initWithConversationID:@"C02RANDOM" huddleID:@"R01LIVE" state:SNCallConnected muted:NO
                                                    speaking:[NSSet setWithObject:@"U03PRIYA"] mutedUsers:[NSSet set]];
    SNSettle(0.1);
    SNPixels *inCall = SNRenderWindow(shell.window);
    SNSaveSnapshot(@"huddle_sidebar_call", inCall);
    footerOrigin = Origin(footer, shell);
    NSRect mic = [footer.micButton convertRect:footer.micButton.bounds toView:footer];
    SNExpect(Near([inCall colorAtPoint:NSMakePoint(footerOrigin.x + NSMinX(mic) + 6, footerOrigin.y + NSMidY(mic))], SNThemeBasePry), "the unmuted mic is theme base-pry");
}

SN_SNAPSHOT(HuddleMessageStates) {
    SNHuddleFixture *source = [SNHuddleFixture fixture];
    SNShell *shell = Shell(source, @"C02RANDOM", SNTabHome);
    SNSettle(0.2);
    SNPixels *pixels = SNRenderWindow(shell.window);
    SNSaveSnapshot(@"huddle_messages", pixels);
    SNMessageListView *list = ((SNChannelPane *)[shell paneInSlot:SNPaneSlotPrimary]).list;
    SNMessage *live = nil;
    for (SNMessage *message in [source messagesInConversation:@"C02RANDOM"])
        if ([[SNHuddle huddleWithJSON:message.json[@"room"] ?: @{}].identifier isEqualToString:@"R01LIVE"]) live = message;
    SNMessageRowView *row = live ? [list rowForTS:live.ts] : nil;
    SNExpect(row != nil, "the live huddle's message is on screen");
    if (!row) return;
    NSPoint origin = Origin(row, shell);
    SNMessageLayout *layout = row.layout;
    SNExpect(layout.huddleLive, "the fixture's newest huddle goes on");
    SNExpect(Near([pixels colorAtPoint:NSMakePoint(origin.x + NSWidth(row.frame) - 40, origin.y + NSHeight(row.frame) - 3)], SNPaletteJade0), "a live huddle's message is jade-0");
    SNExpect(Near([pixels colorAtPoint:NSMakePoint(origin.x + NSMinX(layout.avatarRect) + 3, origin.y + NSMidY(layout.avatarRect))], SNPaletteJade60), "its square is jade-60");
    SNExpect(Near([pixels colorAtPoint:NSMakePoint(origin.x + NSMinX(layout.liveBadgeRect) + 3, origin.y + NSMidY(layout.liveBadgeRect))], SNPaletteJade80), "the LIVE badge is jade-80");
}

SN_SNAPSHOT(HuddleHeaderStarting) {
    SNHuddleFixture *source = [SNHuddleFixture fixture];
    SNShell *shell = Shell(source, @"C02RANDOM", SNTabDirectMessages);
    SNChannelHeader *header = ((SNChannelPane *)[shell paneInSlot:SNPaneSlotPrimary]).header;
    // Drawn once first: the overlay host only has its size after the window's first layout.
    SNRenderWindow(shell.window);
    header.huddle.options.action(header.huddle.options);
    SNPopover *popover = SNPopover.current;
    SNPixels *menu = SNRenderWindow(shell.window);
    SNSaveSnapshot(@"huddle_header_menu", menu);
    NSRect caret = [header.huddle.options convertRect:header.huddle.options.bounds toView:nil];
    NSRect panel = [popover.content convertRect:popover.content.bounds toView:nil];
    SNExpect(popover && fabs(NSMidX(panel) - (NSMidX(caret) + 5)) <= 1 && fabs(NSMaxY(panel) - (NSMinY(caret) + 5)) <= 1,
             "the caret's menu opens centred under it, 5 pt right and 5 pt up");
    [popover close];

    source.fakeCall = [[SNCall alloc] initWithConversationID:@"C02RANDOM" huddleID:nil state:SNCallJoining muted:YES speaking:[NSSet set] mutedUsers:[NSSet set]];
    SNSettle(0.3);
    SNPixels *joining = SNRenderWindow(shell.window);
    NSPoint control = Origin(header.huddle, shell);
    SNSaveSnapshot(@"huddle_header_starting", joining);
    SNExpect(Near([joining colorAtPoint:NSMakePoint(control.x + 2, control.y + 4)], SNPaletteJade50), "a huddle being started already shows the jade-50 fill");
}
