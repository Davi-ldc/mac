// The composer: typing, drafts, attached files, slash commands, reminders and GIFs. Drafts are kept
// on this device per conversation and per thread. Each attached file uploads as soon as it is
// attached (one at a time, as Slack's upload queue) and waits on its composer until the message is
// sent; kept for this session.
#import <Foundation/Foundation.h>

#import "model/command.h"
#import "model/message.h"
#import "model/upload.h"

NS_ASSUME_NONNULL_BEGIN

@protocol SNComposeSource <NSObject>
/// The user typed in the composer; the source tells Slack at most every few seconds.
- (void)userIsTypingInConversation:(NSString *)conversationID threadTS:(nullable NSString *)threadTS;
/// Users typing now, in order of who started first; each expires a few seconds after their last
/// typing event or when their message arrives. `threadTS` nil is the conversation itself.
- (NSArray<NSString *> *)typingUserIDsInConversation:(NSString *)conversationID threadTS:(nullable NSString *)threadTS;
- (nullable NSString *)draftInConversation:(NSString *)conversationID threadTS:(nullable NSString *)threadTS;
/// nil or empty clears the draft.
- (void)setDraft:(nullable NSString *)text inConversation:(NSString *)conversationID threadTS:(nullable NSString *)threadTS;
/// The files attached to the composer of a conversation or thread, in the order attached.
- (NSArray<SNUpload *> *)uploadsInConversation:(NSString *)conversationID threadTS:(nullable NSString *)threadTS;
/// Attaches local files (folders and empty files are the caller's to refuse) and starts uploading
/// them.
- (void)attachFiles:(NSArray<NSURL *> *)files inConversation:(NSString *)conversationID threadTS:(nullable NSString *)threadTS;
/// Takes a file off its composer: its upload stops, and a file already on Slack is deleted.
- (void)removeUpload:(SNUpload *)upload;
/// sendText:blocks:inConversation:threadTS:broadcast: with attached files, which leave their
/// composer: the message shows them at once and is shared (files.share) once they are on Slack.
/// A file whose upload failed is uploaded again, as Slack's client retries failed files on send.
- (SNMessage *)sendText:(NSString *)text
                 blocks:(nullable NSArray<NSDictionary *> *)blocks
                uploads:(NSArray<SNUpload *> *)uploads
         inConversation:(NSString *)conversationID
               threadTS:(nullable NSString *)threadTS
              broadcast:(BOOL)broadcast;
/// Commands for the composer's list in a conversation or thread, best match first: the ones Slack's
/// client runs itself (type "client") and client.appCommands' (asked once a session, kept across
/// launches; SNChangeCommands when they arrive), without the ones Slack's list leaves out (not
/// autocompleted, offered elsewhere, or unable to run there). `query` is what follows the slash;
/// empty lists them all.
- (NSArray<SNCommand *> *)commandsMatching:(NSString *)query
                            inConversation:(nullable NSString *)conversationID
                                  threadTS:(nullable NSString *)threadTS
                                     limit:(NSUInteger)limit;
/// The command a typed name runs ("/Part" runs /leave): the client's own before client.appCommands'.
- (nullable SNCommand *)commandNamed:(NSString *)name;
/// Runs what the composer sent as `typed` (the command word as typed, "/Remind") and `blocks` (the
/// rich_text of the rest) with chat.command. Slack's answer, or why it failed, shows as a message
/// only the user sees, in the thread when sent from one; `completion` gets whether Slack asked to
/// keep the composer's text (keep_input).
- (void)runCommand:(NSString *)typed
            blocks:(nullable NSArray<NSDictionary *> *)blocks
    inConversation:(NSString *)conversationID
          threadTS:(nullable NSString *)threadTS
        completion:(nullable void (^)(BOOL keepInput))completion;
/// A command's answer: a message from Slackbot only the user sees, last in the conversation or
/// thread. Any answer takes the temporary one before it away; a temporary one also goes when the
/// next command runs.
- (void)showCommandFeedback:(NSString *)text inConversation:(NSString *)conversationID threadTS:(nullable NSString *)threadTS temporary:(BOOL)temporary;
/// Takes the temporary answers away, as every command does before it runs.
- (void)clearCommandFeedbackInConversation:(NSString *)conversationID threadTS:(nullable NSString *)threadTS;
/// The Reminder dialog's Save (/remind alone): a reminder of `description` (rich_text blocks) due
/// at `due`, kept in Later (saved.add item_type=reminder, with a client_id of its own).
/// `completion` gets nil or Slack's error ("description_too_long").
- (void)addReminderWithDescription:(NSArray<NSDictionary *> *)description
                               due:(NSDate *)due
                        completion:(nullable void (^)(NSString *_Nullable error))completion;
/// The GIF picker's results (gif.search with `query` and Slack's `reason`, gif.featured without
/// words): Slack's gifs as it sends them ({id, content_description, media_formats: {tinygif, gif:
/// {url, dims, size}}}), or the error.
- (void)searchGIFs:(NSString *)query reason:(NSString *)reason completion:(void (^)(NSArray<NSDictionary *> *_Nullable gifs, NSString *_Nullable error))completion;
@end

NS_ASSUME_NONNULL_END
