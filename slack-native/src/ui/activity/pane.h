// The Activity tab's pane in the sidebar column (registered for SNTabActivity, see
// ui/shell/tabs.h): the "Atividade" header with Slack's unreads switch, filter tabs (all, VIP
// with VIPs, mentions, threads, reactions) and the source's Activity feed, newest first, asked for again
// each time the tab or its peek shows and paged in as the list scrolls. Its peek is the same
// feed under a compact header, with a spinner while nothing is known yet.
#import "ui/activity/list.h"
#import "ui/kit/listheader.h"
#import "ui/shell/tabs.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SNActivityFilter) {
    SNActivityAll,
    SNActivityMentions,
    SNActivityThreads,
    SNActivityReactions,
    /// After All where the plan offers VIPs and the user has some: the feed of VIP activity.
    SNActivityVIP,
};

@interface SNActivityPane : NSObject <SNTabPane>
@property (nonatomic, readonly) SNListHeader *header;
@property (nonatomic, readonly) SNActivityListView *list;
@property (nonatomic) SNActivityFilter filter;
@end

NS_ASSUME_NONNULL_END
