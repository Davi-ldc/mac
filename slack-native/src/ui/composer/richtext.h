// The composer's document and the message it becomes. The document is an attributed string
// whose meaning lives in the SNRich* attributes (fonts and colours are derived from them for
// display): inline styles, links, mentions and emoji, and per paragraph the list, quote or code
// block it belongs to. Typing turns Slack's markdown shortcuts (*bold*, _italic_, ~strike~,
// `code`, ```, "- ", "1. ", "> ", [text](url)) into those attributes, the way the web client's
// composer does; sending turns the document into a rich_text block and the mrkdwn fallback
// (notes/protocol.txt, RENDERING). Slack's rich_text and mrkdwn come back into a document
// through the one reader of them (text/walk.h).
#import <Foundation/Foundation.h>

#import "text/walk.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SNRichBlockKind) {
    SNRichBlockBullet = 1,
    SNRichBlockOrdered,
    SNRichBlockQuote,
    SNRichBlockCode,
};

typedef NS_ENUM(NSInteger, SNRichEntityKind) {
    SNRichEntityUser,
    SNRichEntityChannel,
    SNRichEntityUsergroup,
    /// @here, @channel, @everyone: the value is "here", "channel" or "everyone".
    SNRichEntityBroadcast,
    /// The value is the emoji's name, with the skin tone as Slack writes it ("wave::skin-tone-3").
    SNRichEntityEmoji,
};

/// A mention or an emoji: its characters in the document behave as one piece.
@interface SNRichEntity : NSObject <NSCopying>
+ (instancetype)entityWithKind:(SNRichEntityKind)kind value:(NSString *)value;
/// An emoji with its code points as Slack writes them ("1f44b-1f3fc"); nil for custom emoji.
+ (instancetype)emojiWithName:(NSString *)name unicode:(nullable NSString *)unicode;
@property (nonatomic, readonly) SNRichEntityKind kind;
@property (nonatomic, readonly, copy) NSString *value;
@property (nonatomic, readonly, copy, nullable) NSString *unicode;
@end

/// The list, quote or code block a paragraph belongs to.
@interface SNRichBlock : NSObject <NSCopying>
+ (instancetype)blockWithKind:(SNRichBlockKind)kind indent:(NSInteger)indent;
@property (nonatomic, readonly) SNRichBlockKind kind;
/// Nesting of list items, 0 for the outermost.
@property (nonatomic, readonly) NSInteger indent;
@property (nonatomic, readonly) BOOL isList;
@end

/// A custom emoji's text in the document: one attachment character, where the text view draws
/// its picture.
extern NSString *const SNRichCustomEmojiText;

/// NSNumber of SNInlineStyle.
extern NSAttributedStringKey const SNRichStyleAttribute;
/// NSString URL.
extern NSAttributedStringKey const SNRichLinkAttribute;
/// SNRichEntity, on all of the entity's characters.
extern NSAttributedStringKey const SNRichEntityAttribute;
/// SNRichBlock, on all of a paragraph's characters including its newline.
extern NSAttributedStringKey const SNRichBlockAttribute;

/// What chat.postMessage gets: the mrkdwn fallback and one rich_text block.
@interface SNRichMessage : NSObject
@property (nonatomic, readonly, copy) NSString *text;
@property (nonatomic, readonly, copy) NSArray<NSDictionary *> *blocks;
@end

/// The message for `document`, without blank lines at either end; nil when nothing is left.
SNRichMessage *_Nullable SNRichMessageFromDocument(NSAttributedString *document);

/// Whether Slack would run the document as a slash command rather than post it: it starts with
/// '/' and a character that is neither '/' nor a space (a space before it, or code, makes it text).
BOOL SNRichStartsWithCommand(NSAttributedString *document);

/// A draft: the document's rich_text blocks as JSON text, kept exactly as typed (blank lines and
/// spaces at the ends, bare URLs as text, underline); nil for a blank document.
NSString *_Nullable SNRichDraftFromDocument(NSAttributedString *document);
/// The document a draft holds; `name` as for SNRichDocumentFromBlocks.
NSMutableAttributedString *SNRichDocumentFromDraft(NSString *draft, NSString *_Nullable (^_Nullable name)(SNRichEntityKind kind, NSString *value));

/// Applies the shortcut the characters just inserted at `inserted` complete, if any (only the
/// semantic attributes change). Returns where the caret goes after it, or NSNotFound when
/// nothing changed; `block` gets the caret paragraph's block, which an empty last paragraph has
/// no character to hold (the text view keeps it in its typing attributes).
NSUInteger SNApplyTypingShortcuts(NSMutableAttributedString *document, NSRange inserted, SNRichBlock *_Nullable *_Nullable block);

/// A document from mrkdwn (a message without rich_text being edited): its entities, markers,
/// fences and quotes become what they stand for. `name` as below.
NSMutableAttributedString *SNRichDocumentFromMrkdown(NSString *mrkdwn, NSString *_Nullable (^_Nullable name)(SNRichEntityKind kind, NSString *value));

/// A document from rich_text blocks (a draft or a message being edited). `name` gives the text
/// shown for a mention: a user's or channel's name without the @ or #.
NSMutableAttributedString *SNRichDocumentFromBlocks(NSArray<NSDictionary *> *blocks,
                                                    NSString *_Nullable (^_Nullable name)(SNRichEntityKind kind, NSString *value));

/// The bare URLs in `range` of `string` (http(s):// or www.), without trailing punctuation: sent
/// as links and shown as links while typing.
void SNRichEnumerateBareLinks(NSString *string, NSRange range, void (^block)(NSRange link));

/// The paragraph range around `location`, including its newline.
NSRange SNRichParagraphRange(NSString *string, NSUInteger location);
/// Gives every paragraph touching `edited` one block (its first character's), so an edit that
/// joins or splits paragraphs leaves each a single list item, quote line or code line.
void SNRichNormalizeParagraphs(NSMutableAttributedString *document, NSRange edited);

NS_ASSUME_NONNULL_END
