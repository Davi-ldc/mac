// The contract between the data side and the UI: what a window reads and what it asks for, one
// protocol per feature. The store (src/store) implements it for a signed-in workspace;
// SNFixtureSource is the same store over a folder of saved API responses. Everything happens on
// the main thread.
//
// Reads are synchronous and answer from memory (or the on-disk cache); a read that has nothing
// yet returns empty or nil and starts loading, and the result arrives as a change
// (source/change.h). Requests apply at once where Slack's own client does (optimistic send, edit,
// delete, reactions, read marks) and are reconciled with the server afterwards.
#import "source/activity.h"
#import "source/change.h"
#import "source/compose.h"
#import "source/conversations.h"
#import "source/files.h"
#import "source/huddles.h"
#import "source/messages.h"
#import "source/people.h"
#import "source/settings.h"
#import "source/slack.h"

NS_ASSUME_NONNULL_BEGIN

@protocol SNSource <SNPeopleSource, SNConversationsSource, SNMessagesSource, SNComposeSource, SNSettingsSource, SNActivitySource, SNFilesSource,
                    SNHuddlesSource, SNSlackSource>
/// `observer` hears of every change once per run-loop turn, after the observers added before it;
/// held weakly.
- (void)addChangeObserver:(id<SNChangeObserver>)observer;
@end

NS_ASSUME_NONNULL_END
