// The conversation column (SNPaneSlotPrimary): the header and tabs, the message list and the
// composer under it. It follows the navigator's location and re-reads the source when the open
// conversation's messages change; the list marks what it shows as read.
#import <AppKit/AppKit.h>

#import "ui/channel/header.h"
#import "ui/channel/list.h"
#import "ui/shell/pane.h"

NS_ASSUME_NONNULL_BEGIN

@class SNComposer;

@interface SNChannelPane : NSObject <SNPane>
@property (nonatomic, readonly) SNChannelHeader *header;
@property (nonatomic, readonly) SNMessageListView *list;
@property (nonatomic, readonly) SNComposer *composer;
/// Slack refused the conversation: its unavailable state shows instead of the history.
@property (nonatomic, readonly) BOOL showsUnavailable;
@end

/// Opens what a click in a message refers to: web links in the browser, channels and threads
/// through the navigator. Shared by the conversation and the thread.
void SNActivateTarget(SNRenderTarget *target, SNMessage *message, id<SNNavigator> navigator);

NS_ASSUME_NONNULL_END
