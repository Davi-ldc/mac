// What a message's content renders to, and how it is laid out and drawn. The parsers (rich_text,
// mrkdwn, Block Kit, legacy attachments) build an SNRenderDocument: a list of blocks that holds
// no width. -layoutForWidth: breaks it into lines and boxes once; drawing and hit testing then
// only read that layout, so a message list lays out when a message or the width changes, never
// while it scrolls.
//
// Text is laid out like the web client's CSS: Lato 15 on 22 pt lines (line-height 1.46668),
// browser line boxes (SNBaselineOffset), inline padding on chips and code spans, an 8 pt block
// for an empty line, 28 pt list indents with centred markers.
#import <AppKit/AppKit.h>

#import "render/images.h"
#import "text/walk.h"
#import "theme/theme.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SNRenderTargetKind) {
    SNRenderTargetLink,
    SNRenderTargetUser,
    SNRenderTargetChannel,
    SNRenderTargetUsergroup,
    SNRenderTargetBroadcast,
    SNRenderTargetButton,
    SNRenderTargetImage,
    /// A collapsed picture's caret, and an expanded one's: the value is its expandable key.
    SNRenderTargetExpand,
    SNRenderTargetCollapse,
};

/// What a part of the rendered content refers to: the pointer hovers it and a click opens it.
@interface SNRenderTarget : NSObject
+ (instancetype)targetWithKind:(SNRenderTargetKind)kind value:(NSString *)value;
+ (instancetype)targetWithKind:(SNRenderTargetKind)kind value:(NSString *)value detail:(nullable NSString *)detail;
/// A link preview's picture: the expandable key that hides it (its More actions' "Hide image").
@property (nonatomic, readonly, copy, nullable) NSString *detail;
@property (nonatomic, readonly) SNRenderTargetKind kind;
/// The URL for links, buttons with a URL and images; the ID for users, channels, usergroups;
/// "here", "channel" or "everyone" for broadcasts; the action ID for other buttons.
@property (nonatomic, readonly) NSString *value;
@end

/// The text a block lays out, with its font size, line height and colour.
typedef struct {
    CGFloat size, weight, lineHeight;
    SNColorToken color;
} SNTextStyle;

/// Message text (15 on 22, #d1d2d3).
extern const SNTextStyle SNTextStyleBody;

/// Apple Color Emoji at the size that draws an emoji `box` points wide (Slack's emoji images:
/// 22 in text, 16 in reaction pills, 64 in their tooltip).
NSFont *SNEmojiFont(CGFloat box);
/// Draws the emoji `name` (a standard one or an alias of it, with an optional skin tone, or a
/// custom one) `box` points wide, centred in `rect` of the current context, flipped or not: the
/// glyph in Apple Color Emoji sized by SNEmojiFont, or the custom picture fitted in the box, held
/// by `images` (nil: no picture). NO when the name is neither (callers show ":name:").
BOOL SNDrawEmoji(NSString *name, CGFloat box, NSRect rect, SNImageHolder *_Nullable images);

@class SNParagraphBlock;

/// Builds the attributed text of one paragraph from inline elements.
@interface SNInlineText : NSObject
- (instancetype)initWithStyle:(SNTextStyle)style;
@property (nonatomic, readonly) SNTextStyle style;
- (void)appendText:(NSString *)text style:(SNInlineStyle)style;
/// Text that refers to something (a channel name, a date with a link).
- (void)appendText:(NSString *)text style:(SNInlineStyle)style target:(nullable SNRenderTarget *)target;
- (void)appendLink:(NSURL *)url text:(nullable NSString *)text style:(SNInlineStyle)style;
/// "@name" in Slack's mention chip; `own` is the yellow highlight of the user's own mention.
- (void)appendMention:(NSString *)name target:(SNRenderTarget *)target own:(BOOL)own;
/// A standard emoji by name (skin tone suffix included), a custom one by its image, else
/// `unicode` (rich_text's code points, "1f44d-1f3fb") or ":name:" as text.
- (void)appendEmoji:(NSString *)name fallbackUnicode:(nullable NSString *)unicode;
/// A picture inline with the text (context blocks), `size` points square with rounded corners.
- (void)appendImage:(NSURL *)url size:(CGFloat)size radius:(CGFloat)radius;
/// A Slack icon inline with the text, `size` points square, in `color`.
- (void)appendIcon:(NSString *)name size:(CGFloat)size color:(SNColorToken)color target:(nullable SNRenderTarget *)target;
/// A bare link shown as a chip with a link glyph and the URL without its scheme.
- (void)appendLinkChip:(NSURL *)url;
/// Bigger emoji for messages that are only emoji (c-emoji__large).
@property (nonatomic) BOOL jumbo;
/// Every run in Roboto Mono (preformatted blocks).
@property (nonatomic) BOOL monospaced;
@property (nonatomic, readonly) NSUInteger length;
/// The text so far, with any trailing newlines removed.
- (NSAttributedString *)attributedText;
/// The text as a paragraph block (36 pt lines when jumbo).
- (SNParagraphBlock *)paragraph;
@end

/// One block of a document, configured while the parser builds it.
@interface SNRenderBlock : NSObject
/// CSS margins: between two blocks the larger of the first's spaceAfter and the second's
/// spaceBefore; none above the first block or below the last.
@property (nonatomic) CGFloat spaceBefore, spaceAfter;
@end

@interface SNParagraphBlock : SNRenderBlock
+ (instancetype)paragraphWithText:(NSAttributedString *)text style:(SNTextStyle)style;
@property (nonatomic, readonly) NSAttributedString *text;
@property (nonatomic, readonly) SNTextStyle style;
/// Left indent of every line; list items have 28 pt per level.
@property (nonatomic) CGFloat indent;
/// A list item's bullet or number, centred in the 22 pt box left of the indent.
@property (nonatomic, copy, nullable) NSString *marker;
@end

/// rich_text_preformatted and ``` blocks: Roboto Mono 12 on 18 in a bordered box.
@interface SNCodeBlock : SNRenderBlock
+ (instancetype)codeBlockWithText:(NSAttributedString *)text;
@property (nonatomic, readonly) NSAttributedString *text;
@end

/// Blocks behind a 4 pt bar (quotes, legacy attachments) or inside a bordered card (shared
/// messages, file previews).
@interface SNGroupBlock : SNRenderBlock
+ (instancetype)quoteWithBlocks:(NSArray<SNRenderBlock *> *)blocks;
+ (instancetype)attachmentWithBlocks:(NSArray<SNRenderBlock *> *)blocks barColor:(SNColorToken)color;
+ (instancetype)cardWithBlocks:(NSArray<SNRenderBlock *> *)blocks;
/// A Block Kit section with its accessory picture (sideImage) and no frame.
+ (instancetype)sectionWithBlocks:(NSArray<SNRenderBlock *> *)blocks;
@property (nonatomic, readonly) NSArray<SNRenderBlock *> *blocks;
/// A picture right of the blocks (attachment thumb_url, section accessory).
@property (nonatomic, nullable) NSURL *sideImage;
@property (nonatomic) CGFloat sideImageSize;
/// The widest the group may be (attachments and cards stop at 600 pt).
@property (nonatomic) CGFloat maximumWidth;
@end

/// Block Kit section fields and attachment fields: two columns of short paragraphs.
@interface SNColumnsBlock : SNRenderBlock
+ (instancetype)columnsWithCells:(NSArray<SNParagraphBlock *> *)cells;
@property (nonatomic, readonly) NSArray<SNParagraphBlock *> *cells;
@end

@interface SNImageBlock : SNRenderBlock
+ (instancetype)imageWithURL:(NSURL *)url size:(CGSize)size;
@property (nonatomic, readonly) NSURL *url;
/// The picture's own size; it is shown at most 360 pt tall and as wide as the block allows.
@property (nonatomic, readonly) CGSize size;
/// The expandable key of a picture the reader may hide (its target's detail).
@property (nonatomic, copy, nullable) NSString *hideKey;
@end

@interface SNDividerBlock : SNRenderBlock
@end

typedef NS_ENUM(NSInteger, SNButtonStyle) {
    SNButtonStyleDefault,
    SNButtonStylePrimary,
    SNButtonStyleDanger,
};

@interface SNButtonItem : NSObject
+ (instancetype)buttonWithTitle:(NSString *)title style:(SNButtonStyle)style target:(SNRenderTarget *)target;
@property (nonatomic, readonly) NSString *title;
@property (nonatomic, readonly) SNButtonStyle style;
@property (nonatomic, readonly) SNRenderTarget *target;
@end

/// Block Kit actions: a row of buttons that wraps.
@interface SNButtonsBlock : SNRenderBlock
+ (instancetype)buttonsWithItems:(NSArray<SNButtonItem *> *)items;
@property (nonatomic, readonly) NSArray<SNButtonItem *> *items;
@end

/// Block Kit table: rows of cells, the first row bold.
@interface SNTableBlock : SNRenderBlock
+ (instancetype)tableWithRows:(NSArray<NSArray<NSAttributedString *> *> *)rows;
@property (nonatomic, readonly) NSArray<NSArray<NSAttributedString *> *> *rows;
@end

@class SNRenderLayout;

@interface SNRenderDocument : NSObject
+ (instancetype)documentWithBlocks:(NSArray<SNRenderBlock *> *)blocks;
@property (nonatomic, readonly) NSArray<SNRenderBlock *> *blocks;
@property (nonatomic, readonly) BOOL isEmpty;
/// The text as copied: paragraphs separated by newlines.
@property (nonatomic, readonly) NSString *plainText;
/// Lays the blocks out `width` points wide.
- (SNRenderLayout *)layoutForWidth:(CGFloat)width;
@end

/// A document laid out at a width. Points are relative to the layout's top-left, y down.
@interface SNRenderLayout : NSObject
@property (nonatomic, readonly) CGSize size;
/// Draws into the current (flipped) graphics context with the top-left at `origin`. `hovered`
/// gets its hover look (link underline, mention chip colours). Pictures are held by `images`, as
/// for SNDrawEmoji.
- (void)drawAtPoint:(CGPoint)origin hovered:(nullable SNRenderTarget *)hovered images:(nullable SNImageHolder *)images;
- (nullable SNRenderTarget *)targetAtPoint:(CGPoint)point;
/// Where a target was laid out (the union of its pieces); NSZeroRect when it is not in the layout.
- (NSRect)rectForTarget:(SNRenderTarget *)target;
/// The number of text lines, for tests.
@property (nonatomic, readonly) NSUInteger lineCount;
@end

NS_ASSUME_NONNULL_END
