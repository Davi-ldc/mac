// The Activity tab.
#import <Foundation/Foundation.h>

#import "model/activity.h"
#import "model/message.h"

NS_ASSUME_NONNULL_BEGIN

@protocol SNActivitySource <NSObject>
/// The Activity tab's entries, newest first, as last fetched (kept across launches) and kept up
/// to date by the `activity` websocket events.
@property (nonatomic, readonly) NSArray<SNActivityEntry *> *activityEntries;
/// Fetches the feed's first page again (activity.feed); the answer arrives as SNChangeActivity.
- (void)loadActivity;
/// The next page after the entries held, while Slack has more.
- (void)loadMoreActivity;
@property (nonatomic, readonly) BOOL isLoadingActivity;
@property (nonatomic, readonly) BOOL hasMoreActivity;
/// Slack's "Unreads" switch, shared by the tab and its peek: the feed is asked again holding
/// unread entries only. Kept across launches.
@property (nonatomic) BOOL activityUnreadsOnly;
/// The VIP tab: the feed is asked again holding VIP activity only (Slack's priority-only modes and
/// the VIP tab's types). For the session; while on, the feed is not kept across launches.
@property (nonatomic) BOOL activityVIPOnly;
/// The message an entry is about, when known; nil asks Slack (messages.list) and the answer
/// arrives as SNChangeActivity.
- (nullable SNMessage *)messageForActivityEntry:(SNActivityEntry *)entry;
/// "Mark as read" / "Mark as unread" on an entry (activity.markRead / activity.markUnread): it
/// changes at once (with the unreads switch on, a read entry leaves the feed) and the feed is
/// asked again if Slack refuses. A reaction is not sent, as Slack's client does not send it.
- (void)markActivityEntry:(SNActivityEntry *)entry read:(BOOL)read;
/// "Clear" (activity.archive): the entry leaves the feed at once.
- (void)clearActivityEntry:(SNActivityEntry *)entry;
@end

NS_ASSUME_NONNULL_END
