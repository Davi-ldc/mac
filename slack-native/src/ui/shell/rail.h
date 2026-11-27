// The 70 pt rail at the window's left (components.json tab_rail, workspace_tile, control_strip):
// the workspace tile, the tabs (Home, DMs, Activity, Files, Agents) and, at the bottom, create,
// the theme button and the user's avatar, which opens the user's menu. Resting on a tab that has a peek opens it over the
// sidebar column after 320 ms, fading in over 120 ms (effects.txt [A7], measured live).
#import <AppKit/AppKit.h>

#import "source/source.h"
#import "ui/kit/avatar.h"
#import "ui/kit/button.h"
#import "ui/shell/pane.h"

NS_ASSUME_NONNULL_BEGIN

static const CGFloat SNRailWidth = 70;

@interface SNRailTab : SNHoverView
@property (nonatomic, readonly) SNTab tab;
@property (nonatomic, getter=isCurrent) BOOL current;
/// The tab keeps its hover look while its peek is open.
@property (nonatomic, getter=isPeeking) BOOL peeking;
@end

@interface SNRail : NSView
- (instancetype)initWithSource:(id<SNSource>)source;
@property (nonatomic, readonly) NSArray<SNRailTab *> *tabs;
@property (nonatomic, readonly) SNButton *createButton, *themeButton;
@property (nonatomic, readonly) SNAvatarView *avatar;
/// The user's avatar as a button (it opens the user's menu, ui/shell/youmenu.h).
@property (nonatomic, readonly) SNHoverView *youButton;
@property (nonatomic, copy, nullable) void (^youChosen)(NSView *button);
@property (nonatomic) SNTab currentTab;
@property (nonatomic, copy, nullable) void (^tabChosen)(SNTab tab);
/// The workspace tile was clicked (it opens the workspace menu).
@property (nonatomic, copy, nullable) void (^workspaceChosen)(NSView *tile);
/// The peek for a tab the pointer rests on (effects.txt [A7]): a view SNPeekWidth wide, or nil
/// for a tab without one. Asked each time a peek opens.
@property (nonatomic, copy, nullable) NSView *_Nullable (^peekContent)(SNTab tab);
/// Opens the tab's peek now, as the hover delay would (tests and snapshots).
- (void)showPeekForTab:(SNTab)tab;
/// The open peek's surface, nil when none is open. It closes on navigation and once the pointer
/// has left both it and its tab.
@property (nonatomic, readonly, nullable) NSView *peekPanel;
- (void)closePeek;
/// The rail is drawn at 66% opacity while the window is in the background.
@property (nonatomic) BOOL dimmed;
@end

NS_ASSUME_NONNULL_END
