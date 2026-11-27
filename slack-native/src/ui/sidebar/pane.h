// The Home sidebar (SNPaneSlotSidebar): the workspace header, the page links, then the user's
// sections from users.channelSections with their channels, DMs and group DMs; also the Home
// tab's peek. The header's "Encontrar uma conversa..." field filters the list in place, as
// Slack's sidebar text filter does: 150 ms after the typing stops, the page links go and every
// section shows open with only the conversations whose name holds the text (case, spaces and
// hyphens ignored), in the sidebar's order; nothing found offers to search the workspace.
#import "ui/shell/pane.h"
#import "ui/shell/tabs.h"
#import "ui/sidebar/header.h"
#import "ui/sidebar/list.h"

NS_ASSUME_NONNULL_BEGIN

/// Empties the sidebar's filter (Slack's "sidebar-text-filter-reset" event): posted when the Home
/// tab is chosen while it shows and when the search modal opens what was chosen in it.

@interface SNSidebarPane : NSObject <SNTabPane>
@property (nonatomic, readonly) SNSidebarHeaderView *header;
@property (nonatomic, readonly) SNSidebarListView *list;
/// The list key of a conversation's row in a section ("<section>/<conversation>").
+ (NSString *)keyForConversation:(NSString *)conversationID inSection:(NSString *)sectionID;
+ (NSString *)keyForSection:(NSString *)sectionID;
@end

NS_ASSUME_NONNULL_END
