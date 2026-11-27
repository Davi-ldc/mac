// What Slack calls a conversation wherever it is listed or addressed (sidebar, DMs, search,
// composer placeholder, conversation header): a DM by the other person, a group DM by its other
// members, a channel by its name.
#import "source/source.h"

NS_ASSUME_NONNULL_BEGIN

/// A group DM's members other than the user, as the handles of its "mpdm-ana--bia--me-1" name, in
/// that order (Slack lists group DMs without their members).
NSArray<NSString *> *SNGroupDMHandles(SNConversation *conversation, id<SNSource> source);
/// The people of a DM or group DM other than the user that the source knows (fewer than the
/// handles while some are still being looked up; they arrive as SNChangeUsers).
NSArray<SNUser *> *SNConversationPeople(SNConversation *conversation, id<SNSource> source);
/// "Ana, Bia" for a group DM (a handle stands for a member not known yet), the person's name for
/// a DM (its user ID until known), the name without '#' for a channel.
NSString *SNConversationTitle(SNConversation *conversation, id<SNSource> source);

NS_ASSUME_NONNULL_END
