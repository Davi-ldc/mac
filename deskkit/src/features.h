// Entry points of the features, each of which runs on its own once started.
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class NSPasteboard;

/// Records what is copied, for the launcher's Clipboard History.
void DKStartClipboardHistory(void);
/// cmd+space opens the launcher; cmd+shift+v opens the clipboard history on its own.
void DKStartLauncher(void);
/// cmd+shift+c opens Claude Code in the Clad folder; pressing r before releasing adds
/// --resume.
void DKStartClaudeShortcut(void);
/// What the shortcut does, in a new tab of Ghostty's front window or in a new window when
/// there is none. The arguments are appended to the claude command. NO when Ghostty refuses.
BOOL DKOpenClaude(NSString *arguments);
/// In Ghostty, cmd+q only quits when held, and cmd+v pastes a copied image.
void DKStartGhostty(void);
/// Closing the last window of a Dock app quits it.
void DKStartLastWindowRule(void);
/// When the focused window closes and nothing takes focus, the window used before it does.
void DKStartRefocus(void);
/// New screenshots in ~/Pictures are also put on the clipboard.
void DKStartScreenshotCopy(void);
/// Rectangle's shortcuts for moving and resizing windows.
void DKStartSnapping(void);

/// Opens one launcher screen ("launcher", "quicklinks", "create", "history" or "actions"),
/// with a query after a colon typed into its search field ("launcher:c"), behind other
/// windows, without focus or shortcuts, for checking the look.
void DKInspectLauncher(NSString *show);
/// Prints the launcher's first `count` results for `query`, one per line: title, kind, match
/// score, frecency, remembered-query class and key, tab separated (`deskkit --rank <query>
/// [count]`).
int DKPrintRanking(NSString *query, NSUInteger count);

/// True when the pasteboard holds an image and no text, which is when Ghostty gets cmd+v as
/// ctrl+v: Claude Code reads clipboard images on ctrl+v.
BOOL DKPasteboardHoldsOnlyImage(NSPasteboard *pasteboard);

/// Target frame of a snapping action in Accessibility coordinates (origin at the top
/// left of the primary screen); CGRectNull for an unknown action.
CGRect DKSnapTarget(NSString *action, CGRect window, CGRect visible);

NS_ASSUME_NONNULL_END
