// Messages: history and threads, sending and changing them, read marks, Later, collapsed items and
// search. Writes apply locally at once; a failure reverts them (a send marks the message failed).
#import <Foundation/Foundation.h>

#import "model/message.h"
#import "model/search.h"

NS_ASSUME_NONNULL_BEGIN

/// "<conversation ID>/<thread ts>".
NSString *SNThreadKey(NSString *conversationID, NSString *threadTS);
/// "<conversation ID>/<message identifier>": stable while a pending message becomes sent.
NSString *SNMessageKey(SNMessage *message);

@protocol SNMessagesSource <NSObject>
/// The conversation's newest message outside threads, from memory or the cache, without loading
/// its history; nil while unknown: the source then asks Slack and announces SNChangeMessages.
- (nullable SNMessage *)latestMessageInConversation:(NSString *)conversationID;
/// A message from what is decoded or its one cached row (a reply's under `threadTS`), without
/// decoding a page, keeping anything decoded or asking Slack; nil when not cached.
- (nullable SNMessage *)cachedMessageWithTS:(NSString *)ts inConversation:(NSString *)conversationID threadTS:(nullable NSString *)threadTS;
/// The loaded part of a conversation's history, oldest first; may be empty until it loads.
- (NSArray<SNMessage *> *)messagesInConversation:(NSString *)conversationID;
/// The message of messagesInConversation: with this SNMessage.identifier (what a message key
/// names), found without copying the history; nil when the decoded history holds none.
- (nullable SNMessage *)messageWithIdentifier:(NSString *)identifier inConversation:(NSString *)conversationID;
/// A thread's parent followed by its replies, oldest first.
- (NSArray<SNMessage *> *)threadInConversation:(NSString *)conversationID ts:(NSString *)threadTS;
/// YES while older history exists beyond what is loaded.
- (BOOL)hasOlderMessagesInConversation:(NSString *)conversationID;
/// Asks for the page before the loaded history; the change arrives as a notification.
- (void)loadOlderMessagesInConversation:(NSString *)conversationID;
/// The user read the conversation up to `ts` (the source debounces the server call).
- (void)markConversation:(NSString *)conversationID readThrough:(NSString *)ts;
/// "Mark unread": the conversation becomes unread from `message` on, at once.
- (void)markConversation:(NSString *)conversationID unreadFrom:(SNMessage *)message;
/// Adds the user's reaction, or removes it when they already reacted with it; `name` without
/// colons, skin tones as "thumbsup::skin-tone-2".
- (void)toggleReaction:(NSString *)name onMessage:(SNMessage *)message;
/// The conversation is being shown: loads its newest page when nothing is loaded and keeps it
/// decoded (memory holds only the few most recently loaded conversations and threads).
- (void)loadConversation:(NSString *)conversationID;
/// YES when the loaded history stops before the conversation's newest message (after
/// loadMessagesAround:).
- (BOOL)hasNewerMessagesInConversation:(NSString *)conversationID;
- (void)loadNewerMessagesInConversation:(NSString *)conversationID;
/// Replaces the loaded history with a page around `ts` (a search result, a permalink).
- (void)loadMessagesAround:(NSString *)ts inConversation:(NSString *)conversationID;
/// A page of history is on its way.
- (BOOL)isLoadingMessagesInConversation:(NSString *)conversationID;
/// The thread is being shown: fetches its replies (shown from the cache meanwhile).
- (void)loadThread:(NSString *)threadTS inConversation:(NSString *)conversationID;
/// Sends `text` (mrkdwn, the fallback) with optional rich_text `blocks`; `broadcast` also posts
/// a thread reply to the conversation. Returns the pending message, already in the history or
/// thread.
- (SNMessage *)sendText:(NSString *)text
                 blocks:(nullable NSArray<NSDictionary *> *)blocks
         inConversation:(NSString *)conversationID
               threadTS:(nullable NSString *)threadTS
              broadcast:(BOOL)broadcast;
/// The same with legacy attachments (a GIF from the picker: an image block inside one), shown at
/// once and sent as chat.postMessage's attachments.
- (SNMessage *)sendText:(NSString *)text
                 blocks:(nullable NSArray<NSDictionary *> *)blocks
            attachments:(NSArray<NSDictionary *> *)attachments
         inConversation:(NSString *)conversationID
               threadTS:(nullable NSString *)threadTS
              broadcast:(BOOL)broadcast;
/// Sends a failed message again.
- (void)retrySendingMessage:(SNMessage *)message;
- (void)editMessage:(SNMessage *)message text:(NSString *)text blocks:(nullable NSArray<NSDictionary *> *)blocks;
/// Deletes the message; a pending or failed one is only dropped from this device.
- (void)deleteMessage:(SNMessage *)message;
/// Like markConversation:readThrough:, for a thread (debounced as well).
- (void)markThread:(NSString *)threadTS inConversation:(NSString *)conversationID readThrough:(NSString *)ts;
/// "Mark unread" on a thread reply: the thread (not the conversation) becomes unread from `reply`
/// on, at once, and a read mark of the thread still waiting is dropped.
- (void)markThread:(NSString *)threadTS inConversation:(NSString *)conversationID unreadFrom:(SNMessage *)reply;
/// Whether a message is in the user's Later list as far as this device knows: its "saved" state,
/// or what was saved or taken out here.
- (BOOL)isMessageSavedWithTS:(NSString *)ts inConversation:(NSString *)conversationID;
/// "Save for later" / "Remove from Later" (saved.add / saved.delete), at once; undone if Slack
/// refuses. Announced as SNChangeActivity and the message's SNChangeMessageKeys.
- (void)setSaved:(BOOL)saved messageWithTS:(NSString *)ts inConversation:(NSString *)conversationID;
/// What the user chose for an item of a message (its collapse toggle, /collapse, /expand), kept on
/// this device by the item's key as Slack's client keeps its "expandables" (render/expandable.h
/// makes the keys); nil when never chosen: the item then follows the preferences.
- (nullable NSNumber *)expandedStateOfItem:(NSString *)key;
/// Collapses or expands the items at once and keeps the choice; the messages holding them change
/// (SNChangeMessageKeys).
- (void)setItems:(NSArray<NSString *> *)keys expanded:(BOOL)expanded inMessages:(NSArray<SNMessage *> *)messages;
/// search.messages; `page` starts at 1. `completion` runs on the main thread once, with the
/// result or an error.
- (void)searchMessages:(NSString *)query
                  page:(NSInteger)page
            completion:(void (^)(SNSearchResult *_Nullable result, NSError *_Nullable error))completion;
@end

NS_ASSUME_NONNULL_END
