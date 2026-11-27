// The 40 pt top bar (components.json top_nav*): the sidebar toggle, back/forward/history, the
// search field (it opens the search modal on mouse-down, effects.txt [A3]), Slack's AI button and
// help. It drags the window like a titlebar.
#import <AppKit/AppKit.h>

#import "ui/kit/button.h"

NS_ASSUME_NONNULL_BEGIN

static const CGFloat SNTopBarHeight = 40;

@interface SNTopBar : NSView
@property (nonatomic, readonly) SNButton *sidebarButton, *backButton, *forwardButton, *historyButton, *aiButton, *helpButton;
/// The search field's resting look.
@property (nonatomic, readonly) SNHoverView *searchField;
/// Called when the mouse goes down on the search field: Slack opens search then, not on release.
@property (nonatomic, copy, nullable) void (^searchPressed)(void);
/// "Search <workspace>".
@property (nonatomic, copy) NSString *searchPlaceholder;
/// Slack shows the bar's contents at 66% opacity while the window is in the background.
@property (nonatomic) BOOL dimmed;
@end

NS_ASSUME_NONNULL_END
