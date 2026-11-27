// Turns what Slack sends into documents (render/document.h): rich_text blocks, the mrkdwn
// fallback text, Block Kit blocks and legacy attachments, with mentions named from the source.
#import <Foundation/Foundation.h>

#import "source/source.h"
#import "render/document.h"

NS_ASSUME_NONNULL_BEGIN

@interface SNRenderer : NSObject
- (instancetype)initWithSource:(id<SNSource>)source;
@property (nonatomic, readonly) id<SNSource> source;
/// The clock the relative dates ("today", "2 days ago") are worded against; now by default.
@property (nonatomic) NSDate *now;

/// A user's name as messages show it: their visible name, else `fallback`, else the ID.
- (NSString *)nameOfUser:(NSString *)userID fallback:(nullable NSString *)fallback;
/// The sender as messages show them: the user's name, else the integration's own name, else its
/// bot's (bots.info).
- (NSString *)senderOfMessage:(SNMessage *)message;
/// Whether `change` renamed a user, bot, user group or channel, or changed a custom emoji, that
/// the documents and names given so far show, or moved the time zone they show times in; they are
/// stale then, and what is remembered starts over. Presence, unread counts and the user's frequent
/// emoji never make them stale.
- (BOOL)isStaleAfterChange:(SNChange *)change;

/// A huddle_thread message's huddle: the source's while it is the same room (the live one), else
/// the message's own "room".
- (nullable SNHuddle *)huddleOfMessage:(SNMessage *)message;
/// What a huddle_thread message shows in its sender's place: "A huddle is happening" (or the
/// huddle's name), "A huddle happened".
- (NSString *)huddleStatusOfMessage:(SNMessage *)message;

/// A message's body: its blocks (or its mrkdwn text when it has none), then its attachments.
/// System messages (joins, topic, purpose, renames, integrations, deleted parents, huddles) and
/// thread broadcasts get Slack's wording.
- (SNRenderDocument *)documentForMessage:(SNMessage *)message;
/// The same in a thread, where a broadcast reply says it was also sent to the conversation.
- (SNRenderDocument *)documentForMessage:(SNMessage *)message inThread:(BOOL)inThread;
/// A message as one paragraph for list rows and notifications: its rich_text (else its mrkdwn,
/// else its first file's title) with every block run on a space apart, after `prefix`.
- (SNRenderDocument *)previewOfMessage:(SNMessage *)message style:(SNTextStyle)style prefix:(nullable NSString *)prefix;
/// Stateless one-shot preview without allocating a fresh SNRenderer or dependency maps.
+ (SNRenderDocument *)previewOfMessage:(SNMessage *)message source:(id<SNSource>)source style:(SNTextStyle)style prefix:(nullable NSString *)prefix;
/// Block Kit blocks, rich_text included.
- (NSArray<SNRenderBlock *> *)blocksForBlockKit:(NSArray<NSDictionary *> *)blocks;
/// One rich_text block's elements: sections, lists, quotes and preformatted text.
- (NSArray<SNRenderBlock *> *)blocksForRichText:(NSDictionary *)block;
/// mrkdwn as Slack sends it in "text": entities (<@U..>, <#C..|..>, <!here>, <url|label>, dates),
/// *bold*, _italic_, ~strike~, `code`, ```blocks```, > quotes and :emoji:.
- (NSArray<SNRenderBlock *> *)blocksForMrkdwn:(NSString *)text style:(SNTextStyle)style;
/// Legacy attachments, link unfurls and shared messages.
- (NSArray<SNRenderBlock *> *)blocksForAttachments:(NSArray<NSDictionary *> *)attachments;
@end

NS_ASSUME_NONNULL_END
