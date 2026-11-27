// Conversations: the sidebar's sections, the DM list, channels, and what changes them. Each
// completion gets nil when Slack did it, else Slack's error ("cant_leave_general"), or an empty
// string when Slack did not answer.
#import <Foundation/Foundation.h>

#import "model/conversation.h"

NS_ASSUME_NONNULL_BEGIN

@protocol SNConversationsSource <NSObject>
/// nil while unknown (a link to a channel the user is not in, an old DM): the source then asks
/// Slack (conversations.info) and announces SNChangeConversations with the ID once the
/// conversation arrives or turns out to be unavailable.
- (nullable SNConversation *)conversationWithID:(NSString *)conversationID;
/// Slack answered that the conversation does not exist or that the user cannot see it: show that
/// instead of waiting for it.
- (BOOL)isConversationUnavailable:(NSString *)conversationID;
/// Sidebar sections in display order.
@property (nonatomic, readonly) NSArray<SNSection *> *sections;
/// Open DMs and group DMs, newest activity first (the DMs tab).
@property (nonatomic, readonly) NSArray<SNConversation *> *directMessages;
/// Channels the user is in, archived ones left out, by name.
@property (nonatomic, readonly) NSArray<SNConversation *> *memberChannels;
/// The Threads view's unread state (client.counts "threads").
@property (nonatomic, readonly) BOOL hasUnreadThreads;
@property (nonatomic, readonly) NSInteger threadMentionCount;
/// Channels whose name has a word starting with `query`, the user's own first.
- (NSArray<SNConversation *> *)channelsMatching:(NSString *)query limit:(NSUInteger)limit;
/// The channel browser's list (search.modules.channels, 50 a page): with `query` empty, Slack's
/// browse list of channels not archived. `sort` is Slack's ("recommended", "relevant", "name",
/// "created", "member_count"). `completion` gets the page's channels, as the list describes them
/// (name, purpose, members, membership), and how many pages there are; or the error.
- (void)browseChannels:(NSString *)query
                  sort:(NSString *)sort
             ascending:(BOOL)ascending
                  page:(NSInteger)page
            completion:(void (^)(NSArray<SNConversation *> *_Nullable channels, NSInteger pages, NSString *_Nullable error))completion;
/// The browser's Join: conversations.join in the background, the user staying on the list.
- (void)joinChannelFromBrowser:(NSString *)conversationID completion:(nullable void (^)(NSString *_Nullable error))completion;
typedef void (^SNSourceCompletion)(NSString *_Nullable error);
/// Leaves a channel (conversations.leave): it leaves the sidebar at once and comes back if Slack
/// refuses.
- (void)leaveConversation:(NSString *)conversationID completion:(nullable SNSourceCompletion)completion;
/// Joins a public channel (conversations.join).
- (void)joinConversation:(NSString *)conversationID completion:(nullable SNSourceCompletion)completion;
/// conversations.setTopic; Slack posts the change itself.
- (void)setTopic:(NSString *)topic ofConversation:(NSString *)conversationID completion:(nullable SNSourceCompletion)completion;
/// conversations.invite with people or one user group's members.
- (void)inviteUsers:(NSArray<NSString *> *)userIDs
         usergroups:(NSArray<NSString *> *)groupIDs
     toConversation:(NSString *)conversationID
         completion:(nullable SNSourceCompletion)completion;
/// The add-people dialog's Add (conversations.invite with force): `completion` gets the people
/// Slack would not add, by user ID with its error, and the request's own error.
- (void)addUsers:(NSArray<NSString *> *)userIDs
       toChannel:(NSString *)channelID
      completion:(nullable void (^)(NSDictionary<NSString *, NSString *> *refused, NSString *_Nullable error))completion;
/// A DM's or group DM's "Add people" (conversations.createChild): a new group DM with its people and
/// `userIDs`, the history from `start` (Slack's migrate_history_start_ts; nil for none). `completion`
/// gets the new conversation's ID once the source has it, or the error.
- (void)createGroupFromConversation:(NSString *)conversationID
                        addingUsers:(NSArray<NSString *> *)userIDs
                        historyFrom:(nullable NSString *)start
                         completion:(nullable void (^)(NSString *_Nullable conversationID, NSString *_Nullable error))completion;
/// conversations.kick.
- (void)removeUser:(NSString *)userID fromConversation:(NSString *)conversationID completion:(nullable SNSourceCompletion)completion;
/// conversations.rename; `name` as typed (Slack validates it).
- (void)renameConversation:(NSString *)conversationID to:(NSString *)name completion:(nullable SNSourceCompletion)completion;
/// conversations.archive.
- (void)archiveConversation:(NSString *)conversationID completion:(nullable SNSourceCompletion)completion;
- (void)setSection:(NSString *)sectionID collapsed:(BOOL)collapsed;
/// The DM (one user) or group DM (several) with these users, opened when needed. `completion`
/// gets its ID, or nil when it failed.
- (void)openDirectMessageWithUsers:(NSArray<NSString *> *)userIDs completion:(void (^)(NSString *_Nullable conversationID))completion;
/// Takes a DM or group DM off the DM list (conversations.close), at once.
- (void)closeConversation:(NSString *)conversationID;
@end

NS_ASSUME_NONNULL_END
