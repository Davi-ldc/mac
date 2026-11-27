// The one reader of Slack's text: rich_text elements and mrkdwn. It walks them once and tells a
// sink what it meets, block by block and then piece by piece, so the message document
// (render/message.h), the one-line previews and notifications, and the composer's document all
// read Slack's text the same way. Imports model only; what a piece looks like is the sink's.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Inline formatting, as rich_text's style object and mrkdwn's markers give it.
typedef NS_OPTIONS(NSUInteger, SNInlineStyle) {
    SNInlineBold = 1 << 0,
    SNInlineItalic = 1 << 1,
    SNInlineStrike = 1 << 2,
    SNInlineCode = 1 << 3,
    SNInlineUnderline = 1 << 4,
};

typedef NS_ENUM(NSInteger, SNTextBlockKind) {
    /// Lines of text (rich_text_section, mrkdwn outside fences and quotes).
    SNTextSection,
    SNTextListItem,
    SNTextQuote,
    SNTextCode,
};

/// What the walker reports. A sink overrides what it keeps; the rest does nothing.
@interface SNTextSink : NSObject
/// A block starts; what follows until the next is its text. A list item has its nesting
/// (`indent`, 0 outermost) and its number in an ordered list (0 for a bullet).
- (void)beginBlock:(SNTextBlockKind)kind indent:(NSInteger)indent number:(NSInteger)number;
- (void)appendText:(NSString *)text style:(SNInlineStyle)style;
/// `url` as Slack wrote it (it may not parse); `text` the label, nil for a bare link.
- (void)appendLink:(NSString *)url text:(nullable NSString *)text style:(SNInlineStyle)style;
/// Mentions; `label` is what mrkdwn carried after the bar (<@U1|robin>).
- (void)appendUser:(NSString *)userID label:(nullable NSString *)label;
- (void)appendChannel:(NSString *)channelID label:(nullable NSString *)label style:(SNInlineStyle)style;
- (void)appendUsergroup:(NSString *)groupID label:(nullable NSString *)label;
/// "here", "channel" or "everyone".
- (void)appendBroadcast:(NSString *)range;
/// `name` with its skin tone as Slack writes it ("wave::skin-tone-3"); `unicode` is rich_text's
/// code points ("1f44b-1f3fc"), nil from mrkdwn and for custom emoji.
- (void)appendEmoji:(NSString *)name unicode:(nullable NSString *)unicode style:(SNInlineStyle)style;
/// <!date^...> and rich_text dates: Slack's format tokens, an optional link and the text to show
/// without them.
- (void)appendDate:(NSTimeInterval)timestamp format:(nullable NSString *)format link:(nullable NSString *)link
          fallback:(nullable NSString *)fallback
             style:(SNInlineStyle)style;
/// Whether mrkdwn's :name: is an emoji; NO keeps it text. Asked for every name, known or not.
- (BOOL)knowsEmoji:(NSString *)name;
@end

/// A rich_text block's elements: sections, lists, quotes, preformatted text.
void SNWalkRichText(NSArray *elements, SNTextSink *sink);
/// The rich_text blocks among Block Kit `blocks`, one after another.
void SNWalkRichTextBlocks(NSArray *blocks, SNTextSink *sink);
/// Inline elements (a section's, a table cell's), with `style` added to each.
void SNWalkRichInline(NSArray *elements, SNInlineStyle style, SNTextSink *sink);
/// mrkdwn as Slack sends it in "text": ```fences``` as code blocks (the newline beside a fence
/// is the fence's), runs of "> " lines as quotes, the rest as sections; `style` under all of it.
void SNWalkMrkdwn(NSString *text, SNInlineStyle style, SNTextSink *sink);
/// mrkdwn without blocks: <entities>, *bold*, _italic_, ~strike~, `code`, :emoji: and escapes.
void SNWalkMrkdwnInline(NSString *text, SNInlineStyle style, SNTextSink *sink);

/// mrkdwn's three escapes undone (&lt; &gt; &amp;).
NSString *SNMrkdwnDecode(NSString *text);
/// rich_text's emoji code points ("1f44d-1f3fb") as text; nil when they are not code points.
NSString *_Nullable SNTextFromCodePoints(NSString *codePoints);
/// The other way: text as rich_text's "unicode" writes it.
NSString *SNCodePointsOfText(NSString *text);

NS_ASSUME_NONNULL_END
