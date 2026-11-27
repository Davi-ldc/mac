// The right-hand pane of a list-and-detail screen: a preview and an "Information" table.
#import <AppKit/AppKit.h>

#import "drawnview.h"
#import "items.h"

NS_ASSUME_NONNULL_BEGIN

@interface DKDetailView : DKDrawnView
/// Shows the item's preview text or image and its metadata; nil clears the pane.
- (void)showItem:(nullable DKItem *)item;
@end

NS_ASSUME_NONNULL_END
