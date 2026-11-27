// The shell's composition, geometry and navigation.
#import "app/launch.h"
#import "test.h"
#import "ui/shell/shell.h"

/// Records what the shell tells a pane.
@interface SNRecordingPane : NSObject <SNPane>
@property (nonatomic) NSMutableArray<SNLocation *> *shown;
@end

@implementation SNRecordingPane
@synthesize view = _view;

- (instancetype)initWithSource:(id<SNSource>)source navigator:(id<SNNavigator>)navigator {
    if (!(self = [super init])) return nil;
    _view = [[NSView alloc] initWithFrame:NSZeroRect];
    _shown = [NSMutableArray new];
    return self;
}

- (void)showLocation:(SNLocation *)location { [self.shown addObject:location]; }
- (CGFloat)minimumWidth { return 220; }

@end

static SNShell *Shell(void) { return [[SNShell alloc] initWithSource:SNOpenFixture(SNPublicFixture()) defaults:nil]; }

SN_TEST(ShellLaysOutSlacksGrid) {
    SNShell *shell = Shell();
    NSView *root = shell.window.contentView;
    [root layoutSubtreeIfNeeded];
    SNExpect(NSEqualSizes(root.frame.size, SNWindowDefaultSize), "1435 x 938 window");
    SNExpect(NSEqualRects(shell.topBar.frame, NSMakeRect(0, 0, 1435, 40)), "40 pt top bar");
    SNExpect(NSEqualRects(shell.rail.frame, NSMakeRect(0, 40, 70, 898)), "70 pt rail under it");
    SNExpect(NSEqualRects(shell.card.frame, NSMakeRect(70, 40, 1361, 894)), "card inset 4 pt right and bottom");
    NSButton *close = [shell.window standardWindowButton:NSWindowCloseButton];
    NSRect lights = [close convertRect:close.bounds toView:nil];
    SNExpect(NSMinX(lights) == 12 && SNWindowDefaultSize.height - NSMidY(lights) == 19, "traffic lights at x 12, centred 19 pt down");
    SNExpect([shell.topBar.searchPlaceholder isEqualToString:@"Search Northwind Studio"], "search placeholder names the workspace");
}

SN_TEST(ShellDimsInTheBackground) {
    SNShell *shell = Shell();
    SNExpect(shell.rail.dimmed && shell.topBar.dimmed, "starts dimmed: the window is not key");
    [shell setWindowActive:YES];
    SNExpect(!shell.rail.dimmed && !shell.topBar.dimmed, "active window is not dimmed");
}

SN_TEST(ShellComposesRegisteredPanes) {
    Class previous = SNRegisteredPane(SNPaneSlotSidebar);
    SNRegisterPane(SNPaneSlotSidebar, SNRecordingPane.class);
    SNShell *shell = Shell();
    SNRegisterPane(SNPaneSlotSidebar, previous);
    SNRecordingPane *pane = (SNRecordingPane *)[shell paneInSlot:SNPaneSlotSidebar];
    SNExpect([pane isKindOfClass:SNRecordingPane.class], "registered class fills the slot");
    SNExpect(pane.view.superview != nil && shell.card.sidebarMinimumWidth == 220, "its view is in the card, its minimum width kept");
    SNExpect(pane.shown.count == 1, "told the first location");
    [shell openConversation:@"D05SAM"];
    SNExpect(pane.shown.count == 2 && [pane.shown.lastObject.conversationID isEqualToString:@"D05SAM"], "told every move");
}

SN_TEST(ShellNavigatesWithHistory) {
    SNShell *shell = Shell();
    NSString *first = shell.location.conversationID;
    SNExpect([first isEqualToString:@"C03DESIGN"], "opens at the sidebar's first conversation");
    SNExpect(!shell.topBar.backButton.isEnabled && !shell.topBar.forwardButton.isEnabled, "no history yet");
    [shell openConversation:@"D05SAM"];
    [shell openThread:@"1795192800.000103" inConversation:@"D05SAM"];
    SNExpect(shell.card.secondaryVisible, "a thread opens the thread column");
    [shell goBack];
    SNExpect(!shell.card.secondaryVisible && [shell.location.conversationID isEqualToString:@"D05SAM"], "back closes it");
    [shell goBack];
    SNExpect([shell.location.conversationID isEqualToString:first] && shell.topBar.forwardButton.isEnabled, "back to the start");
    [shell goForward];
    SNExpect([shell.location.conversationID isEqualToString:@"D05SAM"], "forward");
    [shell selectTab:SNTabDirectMessages];
    SNExpect(shell.rail.currentTab == SNTabDirectMessages && shell.rail.tabs[1].isCurrent, "rail follows the tab");
}

SN_TEST(ShellClampsColumns) {
    SNShell *shell = Shell();
    SNContentCard *card = shell.card;
    [shell.window.contentView layoutSubtreeIfNeeded];
    card.sidebarWidth = 50;
    [card layoutSubtreeIfNeeded];
    NSView *sidebarColumn = card.subviews.firstObject.subviews[0];
    SNExpect(sidebarColumn.frame.size.width == SNSidebarMinimumWidth, "sidebar no narrower than 180");
    card.sidebarWidth = 5000;
    [card layoutSubtreeIfNeeded];
    SNExpect(sidebarColumn.frame.size.width == 1359 - 1 - SNPrimaryMinimumWidth, "conversation keeps 300 pt");
    [card setSidebarCollapsed:YES animated:NO];
    [card layoutSubtreeIfNeeded];
    SNExpect(sidebarColumn.frame.size.width == 0, "collapsed");
}
