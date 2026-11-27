// The window and everything in it: background, top bar, rail and content card, with the panes
// registered for each column (see pane.h). It is also the navigator: it keeps the location and
// the back/forward history and tells every pane where the window went.
#import <AppKit/AppKit.h>

#import "source/source.h"
#import "ui/shell/card.h"
#import "ui/shell/pane.h"
#import "ui/shell/rail.h"
#import "ui/shell/topbar.h"
#import "ui/shell/window.h"

NS_ASSUME_NONNULL_BEGIN

@interface SNShell : NSObject <SNNavigator>
/// `defaults` keeps the column widths and the last location across launches; nil keeps
/// nothing (tests and snapshots start from the same state every time).
- (instancetype)initWithSource:(id<SNSource>)source defaults:(nullable NSUserDefaults *)defaults;
@property (nonatomic, readonly) id<SNSource> source;
@property (nonatomic, readonly) SNMainWindow *window;
@property (nonatomic, readonly) SNTopBar *topBar;
@property (nonatomic, readonly) SNRail *rail;
@property (nonatomic, readonly) SNContentCard *card;
/// The pane in each slot; a plain view stands in for a slot nothing registered for.
- (nullable id<SNPane>)paneInSlot:(SNPaneSlot)slot;
/// The pane listing a rail tab in the sidebar column (tabs.h), created on first use; Home's is
/// the sidebar slot's pane, and a tab without its own has none.
- (nullable id<SNPane>)paneForTab:(SNTab)tab;
/// Moves to `location`, recording the current one in the back history.
- (void)go:(SNLocation *)location;
- (void)goBack;
- (void)goForward;
/// Slack's help centre in the browser (the top bar's help button, F1).
- (void)openHelp;
/// Opens the search modal over the top bar's field (ui/shell/search.h).
- (void)openSearch;
/// Applies the background-window look (rail, top bar and background dimmed); the window calls
/// it when its key state changes.
- (void)setWindowActive:(BOOL)active;
@end

NS_ASSUME_NONNULL_END
