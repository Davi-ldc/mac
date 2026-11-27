// The rail's tabs other than Home show their own list in the sidebar column (the DMs list, the
// Activity feed) and a peek of it when the pointer rests on the tab. A module provides one by
// registering a pane for its tab from +load, the way column panes register (pane.h):
//
//   + (void)load { SNRegisterTabPane(SNTabDirectMessages, self); }
//
// The shell creates the pane the first time its tab is shown or peeked, puts its view in the
// sidebar column while the tab is current and calls showLocation: on every move like any pane.
// A tab without a registered pane keeps the sidebar slot's pane.
#import <AppKit/AppKit.h>

#import "ui/shell/pane.h"

NS_ASSUME_NONNULL_BEGIN

/// The rail peek's width (effects.txt [A7], measured live).
static const CGFloat SNPeekWidth = 360;

@protocol SNTabPane <SNPane>
@optional
/// A new view for the tab's peek, SNPeekWidth wide and as tall as it likes. Choosing something
/// in it should navigate; the shell closes the peek on any navigation.
- (NSView *)peekView;
@end

void SNRegisterTabPane(SNTab tab, Class<SNTabPane> _Nullable paneClass);
Class<SNTabPane> _Nullable SNRegisteredTabPane(SNTab tab);

NS_ASSUME_NONNULL_END
