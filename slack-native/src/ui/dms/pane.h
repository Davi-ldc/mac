// The DMs tab's pane in the sidebar column (registered for SNTabDirectMessages, see
// ui/shell/tabs.h): the "Mensagens diretas" header, the filter field and the DM list, newest
// first, with each DM's latest message; its peek is the list under a compact header.
#import "ui/dms/list.h"
#import "ui/kit/listheader.h"
#import "ui/shell/tabs.h"

NS_ASSUME_NONNULL_BEGIN

@interface SNDMsPane : NSObject <SNTabPane>
@property (nonatomic, readonly) SNListHeader *header;
@property (nonatomic, readonly) SNDMListView *list;
@end

NS_ASSUME_NONNULL_END
