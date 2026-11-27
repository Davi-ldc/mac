// The Files tab's list in the sidebar column (UnifiedFilesSidebarView, p-browse_sidebar): the
// "Files" header with Create new, then the pages (All files, Canvases, Lists) as 28 pt rows, and
// under a divider the files the user opened here ("Recently viewed"), each with a remove button
// on hover. Choosing a page shows it in the conversation column.
#import <AppKit/AppKit.h>

#import "ui/shell/tabs.h"

NS_ASSUME_NONNULL_BEGIN

@interface SNFilesSidebarPane : NSObject <SNTabPane>
/// The rows top to bottom (pages, divider, heading, files), for tests.
@property (nonatomic, readonly) NSArray<NSView *> *rows;
@property (nonatomic, readonly) NSView *createButton;
@end

NS_ASSUME_NONNULL_END
