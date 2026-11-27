// The workspace menu: opening from the rail, its rows and keys; and its look against the capture.
#import "app/launch.h"
#import "snapshot.h"
#import "test.h"
#import "ui/kit/popover.h"
#import "ui/shell/shell.h"
#import "ui/shell/workspacemenu.h"

static NSEvent *Key(unsigned short code) {
    return [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0 context:nil
                          characters:@"" charactersIgnoringModifiers:@"" isARepeat:NO keyCode:code];
}

/// The view of `className` under `view`, depth first.
static NSView *Find(NSView *view, NSString *className) {
    if ([NSStringFromClass(view.class) isEqualToString:className]) return view;
    for (NSView *subview in view.subviews) {
        NSView *found = Find(subview, className);
        if (found) return found;
    }
    return nil;
}

static SNWorkspaceMenu *OpenMenu(SNShell *shell) {
    [shell.window.contentView layoutSubtreeIfNeeded];
    shell.rail.workspaceChosen(Find(shell.rail, @"SNWorkspaceTile"));
    return (SNWorkspaceMenu *)Find(SNPopover.current.content, @"SNWorkspaceMenu");
}

SN_TEST(WorkspaceMenuOpensFromTheRail) {
    SNShell *shell = [[SNShell alloc] initWithSource:SNOpenFixture(SNPublicFixture()) defaults:nil];
    SNWorkspaceMenu *menu = OpenMenu(shell);
    SNExpect(menu != nil, "the workspace tile opens the menu");
    SNExpect(menu.bounds.size.width == 320, "320 pt wide");
    SNExpect(menu.itemTitles.count == 5 && [menu.itemTitles.lastObject isEqualToString:@"Sign out"], "five rows, sign out last");
    SNExpect(shell.window.firstResponder == menu, "it takes the keyboard");
    [menu keyDown:Key(125)];
    [menu keyDown:Key(125)];
    SNExpect(menu.highlightedIndex == 1, "Down highlights the rows in turn");
    [menu keyDown:Key(126)];
    [menu keyDown:Key(126)];
    SNExpect(menu.highlightedIndex == 0, "Up stops at the first");
    [menu close];
    SNExpect(SNPopover.current == nil, "closing removes it");
}

SN_SNAPSHOT(WorkspaceMenuMatchesTheCapture) {
    SNShell *shell = [[SNShell alloc] initWithSource:SNOpenFixture(SNPrivateFixture() ?: SNPublicFixture()) defaults:nil];
    SNWorkspaceMenu *menu = OpenMenu(shell);
    menu.highlightedIndex = NSNotFound;
    SNSettle(0.1);
    SNPixels *window = SNRenderWindow(shell.window);
    SNSaveSnapshot(@"workspace_menu_window", window);
    NSRect frame = [shell.window.contentView convertRect:menu.bounds fromView:menu];
    // The capture opened the menu from the sidebar's title, here it hangs off the rail: the
    // comparison follows the menu. The workspace's icon and name are made up.
    static const NSPoint kCaptureMenu = {119, 91};
    SNCompareWithReference(@"workspace_menu", window, @"live/click/m_ws_open", NSMakePoint(NSMinX(frame) - kCaptureMenu.x, NSMinY(frame) - kCaptureMenu.y), 0, @[
        [SNRegion region:@"header's edge" rect:NSMakeRect(119, 91, 24, 72) budget:2],
        [SNRegion ignored:@"workspace icon and name (made up)" rect:NSMakeRect(143, 91, 296, 72)],
        [SNRegion region:@"plan note" rect:NSMakeRect(119, 163.5, 320, 65) budget:10],
        [SNRegion region:@"upsell" rect:NSMakeRect(119, 229.5, 320, 114) budget:10],
        [SNRegion ignored:@"invite (names the workspace)" rect:NSMakeRect(119, 344.5, 320, 44)],
        [SNRegion region:@"preferences and tools" rect:NSMakeRect(119, 389.5, 320, 72) budget:8],
        [SNRegion region:@"mobile app" rect:NSMakeRect(119, 462.5, 320, 45) budget:8],
        [SNRegion region:@"sign out" rect:NSMakeRect(119, 508.5, 320, 48) budget:8],
    ]);
    [menu close];
}
