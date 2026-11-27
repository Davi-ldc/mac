// The rail's peeks: they let clicks through, leave other popovers open, close when the pointer
// leaves, and the Home peek's own controls work.
#import "app/launch.h"
#import "test.h"
#import "ui/kit/overlay.h"
#import "ui/kit/popover.h"
#import "ui/shell/search.h"
#import "ui/shell/shell.h"
#import "ui/sidebar/header.h"

static SNShell *PeekShell(void) {
    SNShell *shell = [[SNShell alloc] initWithSource:SNOpenFixture(SNPublicFixture()) defaults:nil];
    [shell.window.contentView layoutSubtreeIfNeeded];
    return shell;
}

static SNRailTab *Tab(SNShell *shell, SNTab tab) {
    for (SNRailTab *candidate in shell.rail.tabs)
        if (candidate.tab == tab) return candidate;
    return nil;
}

static NSView *Find(NSView *view, Class kind) {
    if ([view isKindOfClass:kind]) return view;
    for (NSView *subview in view.subviews) {
        NSView *found = Find(subview, kind);
        if (found) return found;
    }
    return nil;
}

SN_TEST(ShellPeekLetsClicksThrough) {
    SNShell *shell = PeekShell();
    SNRailTab *dms = Tab(shell, SNTabDirectMessages);
    [shell.rail showPeekForTab:SNTabDirectMessages];
    SNExpect(shell.rail.peekPanel && [SNOverlayHost hostForWindow:shell.window].outsideClick == nil, "an open peek does not catch clicks around it");
    // hitTest: takes the point in the content view's superview, the window's coordinates.
    NSPoint centre = [dms convertPoint:NSMakePoint(NSMidX(dms.bounds), NSMidY(dms.bounds)) toView:nil];
    NSView *hit = [shell.window.contentView hitTest:centre];
    SNExpect(hit == dms || [hit isDescendantOf:dms], "so the first click on its tab reaches the tab");
    NSEvent *exit = [NSEvent enterExitEventWithType:NSEventTypeMouseExited location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0 context:nil
                                        eventNumber:0 trackingNumber:0 userData:NULL];
    [dms mouseExited:exit];
    SNExpect(shell.rail.peekPanel != nil, "the pointer can cross to the peek");
    SNSettle(SNLiveHoverCardCloseDelay + 0.1);
    SNExpect(shell.rail.peekPanel == nil, "it closes once the pointer left the tab without reaching it");
}

SN_TEST(ShellPeekLeavesTheSearchOpen) {
    SNShell *shell = PeekShell();
    shell.topBar.searchPressed();
    [shell.rail showPeekForTab:SNTabActivity];
    SNExpect(SNSearchModal.current != nil && shell.rail.peekPanel != nil, "a peek opening does not close the search");
    [SNSearchModal.current close];
    [shell.rail closePeek];
}

SN_TEST(ShellHomePeekOpensTheWorkspaceMenu) {
    SNShell *shell = PeekShell();
    [shell selectTab:SNTabDirectMessages];
    [shell.rail showPeekForTab:SNTabHome];
    SNSidebarHeaderView *header = (SNSidebarHeaderView *)Find(shell.rail.peekPanel, SNSidebarHeaderView.class);
    header.titleButton.action(header.titleButton);
    SNExpect(header && SNPopover.current != nil, "the workspace name in the Home peek opens its menu");
    [SNPopover.current close];
    [shell.rail closePeek];
}
