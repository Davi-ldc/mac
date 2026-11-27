// A message, decoded from conversations.history/.replies "messages", a message event or
// chat.postMessage's "message"; with its reactions and files.
#import <Foundation/Foundation.h>

#import "model/workspace.h"

NS_ASSUME_NONNULL_BEGIN

@interface SNReaction : NSObject <NSCopying>
/// The emoji name without colons; skin tones as "thumbsup::skin-tone-2".
@property (nonatomic, readonly) NSString *name;
/// Slack lists at most some of the users; `count` is the real total.
@property (nonatomic, readonly) NSArray<NSString *> *userIDs;
@property (nonatomic, readonly) NSInteger count;
+ (nullable instancetype)reactionWithJSON:(NSDictionary *)json;
+ (instancetype)reactionWithName:(NSString *)name userIDs:(NSArray<NSString *> *)userIDs count:(NSInteger)count;
/// The reaction in the API's shape.
@property (nonatomic, readonly) NSDictionary *json;
@end

@interface SNFile : NSObject <NSCopying>
@property (nonatomic, readonly) NSString *fileID;
@property (nonatomic, readonly) NSString *name, *title;
@property (nonatomic, readonly, nullable) NSString *mimeType, *fileType, *prettyType;
@property (nonatomic, readonly) long long size;
@property (nonatomic, readonly, nullable) NSString *userID;
/// Need the session's cookie and token.
@property (nonatomic, readonly, nullable) NSURL *privateURL, *downloadURL;
@property (nonatomic, readonly, nullable) NSURL *permalink;
/// thumb_<size> URLs by size (64, 80, 160, 360, 480, 720, 800, 960, 1024); also need auth.
@property (nonatomic, readonly) NSDictionary<NSNumber *, NSURL *> *thumbnailURLs;
/// original_w/original_h for images; zero when unknown.
@property (nonatomic, readonly) CGSize originalSize;
/// "hosted", "external", "snippet", "post", "tombstone" (deleted).
@property (nonatomic, readonly, nullable) NSString *mode;
/// "slack_image", "slack_video", "slack_audio" for what was recorded or pasted in Slack.
@property (nonatomic, readonly, nullable) NSString *subtype;
/// A video's poster (thumb_video) and its size; its transcoded stream (mp4); an audio clip's
/// transcoded stream (aac).
@property (nonatomic, readonly, nullable) NSURL *videoThumbnailURL, *mp4URL, *aacURL;
@property (nonatomic, readonly) CGSize videoThumbnailSize;
/// A document's first page (thumb_pdf) and its size.
@property (nonatomic, readonly, nullable) NSURL *pdfThumbnailURL;
@property (nonatomic, readonly) CGSize pdfThumbnailSize;
/// Length of a video or audio file; zero when unknown.
@property (nonatomic, readonly) NSTimeInterval duration;
/// Where the reader stopped playing it last time (media_progress), zero once watched through.
@property (nonatomic, readonly) NSTimeInterval playbackOffset;
/// A clip's transcript status ("none", "processing", "complete", "failed") and its first words.
@property (nonatomic, readonly, nullable) NSString *transcriptionStatus, *transcriptionPreview;
@property (nonatomic, readonly) BOOL transcriptionHasMore;
/// An audio clip's loudness samples (0-100), for its waveform.
@property (nonatomic, readonly) NSArray<NSNumber *> *waveform;
/// A text file's or snippet's first lines: plain (preview) and as the server highlighted them
/// (preview_highlight, CodeMirror markup); the file's line count and those not in the preview.
@property (nonatomic, readonly, nullable) NSString *preview, *previewHighlight;
@property (nonatomic, readonly) NSInteger lineCount, moreLineCount;
/// The preview stops before the end of the file (preview_is_truncated).
@property (nonatomic, readonly) BOOL previewIsTruncated;
/// Shared from Google Drive, Dropbox... (is_external); external_type names the service.
@property (nonatomic, readonly) BOOL isExternal;
@property (nonatomic, readonly, nullable) NSString *externalType;
/// The file on this device that a message being sent from here shows (sn_local_url, a file
/// URL) until Slack's copy of the message replaces it.
@property (nonatomic, readonly, nullable) NSURL *localURL;
/// When it was uploaded (created), shared (timestamp), last edited (updated) and last opened by
/// the reader (last_read, which Slack sends in seconds or milliseconds), in Unix seconds; zero
/// when unknown.
@property (nonatomic, readonly) NSTimeInterval created, timestamp, updated, lastRead;
/// The uploader's name as Slack spelled it on the file (username), for apps and the deleted.
@property (nonatomic, readonly, nullable) NSString *userName;
/// What Slack sent, kept to store the file again (the Files tab's recently viewed list).
@property (nonatomic, readonly) NSDictionary *json;
+ (nullable instancetype)fileWithJSON:(NSDictionary *)json;
/// The smallest thumbnail at least `pixels` on its longer side, else the original picture
/// (url_private) when it is bigger than every thumbnail; the local file while it has one.
- (nullable NSURL *)thumbnailURLForPixels:(CGFloat)pixels;
@end

typedef NS_ENUM(NSInteger, SNMessageSendState) {
    /// On the server (every message that did not start on this device).
    SNMessageSent,
    /// Sent from here, not yet confirmed; shown dimmed.
    SNMessagePending,
    /// Sending failed; the UI offers retry and delete.
    SNMessageFailed,
};

@interface SNMessage : NSObject <NSCopying>
/// A pending message's ts is local until the server confirms it; `identifier` stays the same.
@property (nonatomic, readonly) NSString *ts;
@property (nonatomic, readonly, nullable) NSString *conversationID;
/// Absent for most bot messages, which have botID and username instead.
@property (nonatomic, readonly, nullable) NSString *userID;
@property (nonatomic, readonly, nullable) NSString *botID;
/// A bot's or integration's display name (username, or bot_profile.name).
@property (nonatomic, readonly, nullable) NSString *username;
/// bot_profile.icons or icons image_<size> URLs, for messages without a user.
@property (nonatomic, readonly) NSDictionary<NSNumber *, NSURL *> *botIconURLs;
/// nil for plain messages; "bot_message", "channel_join", "thread_broadcast", "me_message", ...
@property (nonatomic, readonly, nullable) NSString *subtype;
/// mrkdwn fallback text; `blocks` are what Slack renders when present.
@property (nonatomic, readonly) NSString *text;
/// Block Kit and rich_text blocks, as Slack sent them (rendered by src/render).
@property (nonatomic, readonly) NSArray<NSDictionary *> *blocks;
/// Legacy attachments and link unfurls, as Slack sent them.
@property (nonatomic, readonly) NSArray<NSDictionary *> *attachments;
@property (nonatomic, readonly) NSArray<SNFile *> *files;
@property (nonatomic, readonly) NSArray<SNReaction *> *reactions;
/// ts of the thread's parent; equal to `ts` on the parent itself.
@property (nonatomic, readonly, nullable) NSString *threadTS;
@property (nonatomic, readonly) NSInteger replyCount, replyUsersCount;
/// Up to a few repliers' IDs, for the reply bar's avatars.
@property (nonatomic, readonly) NSArray<NSString *> *replyUserIDs;
@property (nonatomic, readonly, nullable) NSString *latestReply;
/// ts of the edit when the message was edited.
@property (nonatomic, readonly, nullable) NSString *editedTS;
@property (nonatomic, readonly, nullable) NSString *clientMessageID;
@property (nonatomic, readonly) BOOL isPinned, isStarred;
/// Only the user sees it (is_ephemeral: a command's answer, an app's reply to them); Slack keeps
/// no copy, so neither does this app.
@property (nonatomic, readonly) BOOL isEphemeral;
@property (nonatomic, readonly) SNMessageSendState sendState;
/// What a row is keyed by: clientMessageID when there is one (it survives the swap of a pending
/// message's local ts for the server's), else ts.
@property (nonatomic, readonly) NSString *identifier;
/// The JSON the message was decoded from. Keys starting with "sn_" are this app's own (the send
/// state); the store persists and patches messages as JSON.
@property (nonatomic, readonly) NSDictionary *json;

/// `conversationID` is the channel the message was listed in; nil takes the JSON's "channel".
+ (nullable instancetype)messageWithJSON:(NSDictionary *)json conversationID:(nullable NSString *)conversationID;
@property (nonatomic, readonly) NSDate *date;
/// A reply within a thread (not the parent, not a broadcast copy in the channel).
@property (nonatomic, readonly) BOOL isReply;
@property (nonatomic, readonly) BOOL isThreadParent;
/// The same message with other reactions (reaction_added and reaction_removed events).
- (instancetype)messageWithReactions:(NSArray<SNReaction *> *)reactions;
/// Decoded again from its JSON with `changes` laid over it; NSNull removes a key.
- (instancetype)messageByMergingJSON:(NSDictionary *)changes;
- (instancetype)messageWithSendState:(SNMessageSendState)sendState;
/// Mentions the user by name (<@U> in the text or a rich_text user element).
- (BOOL)mentionsUser:(NSString *)userID;
/// Mentions @here, @channel or @everyone.
@property (nonatomic, readonly) BOOL mentionsEveryone;
/// Names someone, a user group or a channel (<@U>, <!subteam^S>, <#C> or their rich_text
/// elements), as Slack's getMessageMentions finds them.
@property (nonatomic, readonly) BOOL mentionsAnyone;
/// https://<domain>.slack.com/archives/<conversation>/p<ts digits>, with thread_ts for replies.
- (nullable NSURL *)permalinkInWorkspace:(SNWorkspace *)workspace;
@end

/// Orders Slack timestamps ("1700000000.000100"), which compare as numbers, not strings.
NSComparisonResult SNCompareTS(NSString *a, NSString *b);

NS_ASSUME_NONNULL_END
