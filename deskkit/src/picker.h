// The Raycast-style panel shared by the launcher and the clipboard history: a stack of
// screens (searchable lists or forms) with Raycast's keyboard behaviour.
#import <AppKit/AppKit.h>

#import "items.h"

NS_ASSUME_NONNULL_BEGIN

@interface DKPicker : NSObject
/// `logo` is shown at the left of the root screen's search field.
- (instancetype)initWithRootPage:(DKPage *)page logo:(NSImage *)logo;
/// Makes the panel and fills in the root screen without showing it, which the first show
/// would otherwise do while the user waits.
- (void)warmUp;
/// Shows the root screen and takes keyboard focus, remembering the app that had it.
- (void)show;
/// Shows `screen` on its own, as its own hotkey opens it: Esc and the back button close the
/// panel, since there is no root screen to go back to.
- (void)showScreen:(DKScreen *)screen;
/// Shows the root screen, or `screen` on its own, behind other windows without taking
/// focus, where a window capture can still see it: for checking the look (DESKKIT_SHOW)
/// while someone works.
- (void)showForInspection:(nullable DKScreen *)screen;
/// Types `query` into the current list's search field.
- (void)search:(NSString *)query;
/// Closes the panel, for when an action already moves focus somewhere (opening an app).
/// Closed, the panel keeps its views and goes back to the root screen, so that the next
/// show has only to put it on screen.
- (void)hide;
/// Closes the panel and gives focus back to the app that had it before.
- (void)dismiss;
- (void)pushScreen:(DKScreen *)screen;
/// Opens or closes the selected row's Actions menu, as ⌘K does.
- (void)toggleActions;
/// Back to the previous screen; on the screen the panel opened with, closes the panel.
- (void)pop;
/// Runs the current list's query again, keeping the selection where it was.
- (void)reload;
/// Asks the rows on screen for their icons again, after a new icon became available.
- (void)reloadIcons;
/// The app that was in front when the panel opened.
@property(readonly, nullable) NSRunningApplication *previousApplication;
@property(readonly, getter=isVisible) BOOL visible;
@end

NS_ASSUME_NONNULL_END
