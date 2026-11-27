// The files attached to a composer, in the row between its text and its footer, as the web
// client's CSS draws them (p-multi_file_upload__file_gallery in the composer, p-gallery_scroller):
// 62 pt items 12 pt apart, 8 pt in from the box; pictures as 62 pt thumbnails with 12 pt corners,
// other files as 234 pt cards with the type icon, the name and the kind. A 22 pt circle on each
// item's top-right corner holds a spinner while it uploads, a warning when it failed, and the
// remove x under the pointer. Arrows past the box's edges scroll a row wider than the box.
#import <AppKit/AppKit.h>

#import "model/upload.h"

NS_ASSUME_NONNULL_BEGIN

/// The row's height in the box: 8 pt above and under the 62 pt items.
static const CGFloat SNComposerAttachmentsHeight = 78;
/// How far the view reaches above its row, so the circles on the items' corners are not cut.
static const CGFloat SNComposerAttachmentsOverhang = 8;

@interface SNComposerAttachments : NSView
@property (nonatomic, copy) NSArray<SNUpload *> *uploads;
/// The remove x was clicked.
@property (nonatomic, copy, nullable) void (^remove)(SNUpload *upload);
/// The item views in order, and the scroll arrows, for tests and snapshots.
@property (nonatomic, readonly) NSArray<NSView *> *itemViews;
@property (nonatomic, readonly) NSView *leftArrow, *rightArrow;
@end

NS_ASSUME_NONNULL_END
