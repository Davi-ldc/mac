// "Also send to #channel" under a thread's composer: a checkbox and its label. Checked, the
// next reply is also posted to the conversation (reply_broadcast); sending unchecks it, as in
// Slack.
#import "ui/kit/hoverview.h"

NS_ASSUME_NONNULL_BEGIN

@interface SNComposerBroadcastToggle : SNHoverView
@property (nonatomic, copy) NSString *label;
@property (nonatomic, getter=isChecked) BOOL checked;
@end

NS_ASSUME_NONNULL_END
