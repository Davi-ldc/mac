// The user's menu, from the rail's avatar (Slack's UserMenu, classic layout): the status
// ("Update your status", or the one set and "Clear status"), "Set yourself as away" or "active",
// Profile, Preferences and "Sign out of <workspace>". Slack's notification pausing, account
// settings and downloads are not offered.
#import <AppKit/AppKit.h>

#import "source/source.h"
#import "ui/kit/popover.h"
#import "ui/shell/pane.h"

NS_ASSUME_NONNULL_BEGIN

/// The menu's items for the user as the source has them (tests read their titles).
NSArray<SNMenuItem *> *SNYouMenuItems(id<SNSource> source, id<SNNavigator> navigator, NSWindow *window);
/// Opens the menu to the right of `view` (the avatar).
SNPopover *_Nullable SNShowYouMenu(NSView *view, id<SNSource> source, id<SNNavigator> navigator);

NS_ASSUME_NONNULL_END
