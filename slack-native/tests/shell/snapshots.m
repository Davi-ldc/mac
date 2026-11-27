// The shell against the official app's captures, and its hover and press states.
#import "app/launch.h"
#import "snapshot.h"
#import "test.h"
#import "ui/shell/shell.h"

/// The window of the captures: the private fixture (laid out like them) on the DMs tab with the
/// newest DM open, the window in the background like when they were taken.
static SNShell *ReferenceShell(void) {
    NSURL *fixture = SNPrivateFixture() ?: SNPublicFixture();
    id<SNSource> source = SNOpenFixture(fixture);
    SNShell *shell = [[SNShell alloc] initWithSource:source defaults:nil];
    [shell go:[SNLocation locationWithTab:SNTabDirectMessages conversation:source.directMessages.firstObject.conversationID thread:nil]];
    return shell;
}

SN_SNAPSHOT(ShellMatchesTheCaptures) {
    SNShell *shell = ReferenceShell();
    SNPixels *window = SNRenderWindow(shell.window);
    SNSaveSnapshot(@"shell_window", window);

    // The top bar and the corner crops start at known points; the rail's crop is placed by search.
    SNCompareWithReference(@"shell_topbar", window, @"topbar_default", NSZeroPoint, 0, @[
        [SNRegion region:@"traffic lights" rect:NSMakeRect(0, 0, 76, 40) budget:3],
        [SNRegion region:@"background" rect:NSMakeRect(104, 0, 190, 40) budget:1],
        [SNRegion region:@"sidebar toggle" rect:NSMakeRect(76, 0, 28, 40) budget:2],
        [SNRegion region:@"history buttons" rect:NSMakeRect(294, 0, 100, 40) budget:2],
        [SNRegion region:@"search field" rect:NSMakeRect(394, 4, 22, 32) budget:2],
        [SNRegion ignored:@"search placeholder (workspace name differs)" rect:NSMakeRect(416, 4, 584, 32)],
        // Slack draws its Slackbot picture here, not an icon.
        [SNRegion region:@"ai button" rect:NSMakeRect(1002, 0, 36, 40) budget:30],
        [SNRegion ignored:@"app chip (not in the data yet)" rect:NSMakeRect(1338, 0, 60, 40)],
        [SNRegion region:@"help" rect:NSMakeRect(1398, 0, 37, 40) budget:8],
        [SNRegion region:@"card top edge" rect:NSMakeRect(70, 40, 1361, 1) budget:2],
    ]);

    SNCompareWithReference(@"shell_rail", window, @"rail_default", NSMakePoint(0, 40), 1, @[
        [SNRegion ignored:@"workspace tile (made-up icon)" rect:NSMakeRect(0, 0, 70, 56)],
        [SNRegion region:@"home" rect:NSMakeRect(0, 61, 70, 68) budget:5],
        [SNRegion region:@"dms (current)" rect:NSMakeRect(0, 129, 70, 68) budget:5],
        [SNRegion region:@"activity" rect:NSMakeRect(0, 197, 70, 68) budget:5],
        [SNRegion region:@"files" rect:NSMakeRect(0, 265, 70, 68) budget:5],
        [SNRegion region:@"agents" rect:NSMakeRect(0, 333, 70, 92) budget:5],
        [SNRegion region:@"background" rect:NSMakeRect(0, 430, 70, 290) budget:1],
        [SNRegion region:@"create" rect:NSMakeRect(0, 730, 70, 44) budget:3],
        [SNRegion region:@"theme" rect:NSMakeRect(0, 782, 70, 44) budget:3],
        [SNRegion ignored:@"avatar (made-up picture)" rect:NSMakeRect(0, 834, 70, 44)],
        [SNRegion region:@"card left edge" rect:NSMakeRect(70, 0, 1, 880) budget:2],
    ]);

    SNCompareWithReference(@"shell_card_corner", window, @"content_card_corner_topleft", NSMakePoint(60, 30), 0, @[
        [SNRegion region:@"outside the card" rect:NSMakeRect(0, 0, 40, 10) budget:1],
        [SNRegion region:@"rounded corner" rect:NSMakeRect(8, 8, 14, 14) budget:6],
        [SNRegion region:@"sidebar fill" rect:NSMakeRect(11, 11, 15, 29) budget:1],
        [SNRegion ignored:@"sidebar title (sidebar pane)" rect:NSMakeRect(26, 11, 14, 29)],
    ]);
}

SN_SNAPSHOT(ShellHoverAndPressStates) {
    SNShell *shell = ReferenceShell();
    SNRail *rail = shell.rail;
    rail.tabs[2].hovered = YES;
    rail.tabs[3].hovered = rail.tabs[3].pressed = YES;
    rail.createButton.hovered = YES;
    rail.themeButton.hovered = rail.themeButton.pressed = YES;
    shell.topBar.backButton.hovered = YES;
    shell.topBar.historyButton.hovered = shell.topBar.historyButton.pressed = YES;
    shell.topBar.helpButton.hovered = YES;
    SNSettle(0.3);
    SNSaveSnapshot(@"shell_hover_pressed", SNRenderWindow(shell.window));
    [shell setWindowActive:YES];
    SNSaveSnapshot(@"shell_active_window", SNRenderWindow(shell.window));
}

SN_SNAPSHOT(ShellPublicFixture) {
    SNShell *shell = [[SNShell alloc] initWithSource:SNOpenFixture(SNPublicFixture()) defaults:nil];
    [shell openThread:@"1795192800.000103" inConversation:@"C01GENERAL"];
    SNSaveSnapshot(@"shell_public", SNRenderWindow(shell.window));
}
