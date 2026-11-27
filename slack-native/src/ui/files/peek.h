// The "Files and links" tab's peek (FilesTabPeek in files_tab_view__preview; effects.txt [L9],
// b4_files_peek): 360 pt wide under the tab, the conversation's files and links in one list by
// when they were shared, 61 pt file rows and 63 pt link rows with a line between them, as tall
// as its rows plus 10 pt and at most 600 (then it scrolls); the skeleton while any of its lists
// loads (430 pt), "No files or links found for this channel." in 200 pt when all are empty. It
// fades in over 150 ms, stays while the pointer is on the tab or on it (or outside the window)
// and closes once the pointer rests on something else.
#import <AppKit/AppKit.h>

#import "ui/files/attachments.h"

NS_ASSUME_NONNULL_BEGIN

static const CGFloat SNFilesPeekWidth = 360;

/// The list inside the peek, sized to what it shows.
@interface SNFilesPeekView : NSView
- (instancetype)initWithSource:(id<SNSource>)source attachments:(SNConversationAttachments *)attachments;
/// Lays the rows out again from the attachments (and takes its new height).
- (void)update;
/// The rows shown (SNFileRow, SNLinkRow or SNFileSkeletonRow), top to bottom, for tests.
@property (nonatomic, readonly) NSArray<NSView *> *rows;
@end

@interface SNFilesPeek : NSObject
/// Opens the peek under `tab` (the box 8 pt left of the tab, 31.5 pt under its top), closing any
/// other; nil when the tab is in no window.
+ (nullable instancetype)showUnderTab:(NSView *)tab source:(id<SNSource>)source attachments:(SNConversationAttachments *)attachments;
+ (nullable SNFilesPeek *)current;
@property (nonatomic, readonly) NSView *panel;
@property (nonatomic, readonly) SNFilesPeekView *list;
/// Re-reads the attachments after they changed.
- (void)update;
- (void)close;
@end

NS_ASSUME_NONNULL_END
