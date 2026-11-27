// The thread column (SNPaneSlotSecondary, components.json thread_pane_flexpane, measured live):
// it opens and closes in one frame at 393 pt. A 49 pt header with "Conversa" in 15 pt black, the
// kebab and the close button; the parent message, the replies count line and the replies in the
// conversation's message rows; the composer for replies at the bottom.
#import <AppKit/AppKit.h>

#import "ui/channel/kebab.h"
#import "ui/channel/list.h"
#import "ui/shell/pane.h"

NS_ASSUME_NONNULL_BEGIN

@class SNComposer;

static const CGFloat SNThreadHeaderHeight = 49;

@interface SNThreadPane : NSObject <SNPane>
@property (nonatomic, readonly) SNMessageListView *list;
@property (nonatomic, readonly) SNComposer *composer;
@property (nonatomic, readonly) SNKebabButton *more;
@property (nonatomic, readonly) SNButton *close;
@end

NS_ASSUME_NONNULL_END
