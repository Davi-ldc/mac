// A message's file as the official client draws it (render/file.h picks the component): a
// picture under its name line; a video that plays in place and the audio player (mediaview.h);
// the card (radius 12, 1 pt border that darkens on hover over 80 ms) with the type icon, name
// and kind, a document's first page under it; a snippet's code under its name line, collapsed
// to 200 pt and expanded in place. The file actions (download, open in the browser, more) fade
// in at the top right on hover.
#import "model/message.h"
#import "render/file.h"
#import "ui/kit/hoverview.h"

NS_ASSUME_NONNULL_BEGIN

@interface SNFileView : SNHoverView
/// `context` keeps a snippet's expansion apart per message and column, as Slack does.
- (instancetype)initWithFile:(SNFile *)file style:(SNFileStyle)style context:(NSString *)context;
@property (nonatomic, readonly) SNFile *file;
@property (nonatomic, readonly) SNFileStyle style;
/// The view needs another size (a snippet expanded or collapsed): its row lays out again.
@property (nonatomic, copy, nullable) void (^sizeChanged)(void);
/// The hover actions' buttons, for tests and snapshots.
@property (nonatomic, readonly) NSArray<NSView *> *actionButtons;
/// Expands a snippet with its whole text, as the click does once the text is read (for tests).
- (void)expandWithContent:(NSString *)content;
/// The meta line's caret (pictures, snippets and the collapsed line): the message's files collapse
/// or expand. `metaTitle` is what the collapsed line says.
@property (nonatomic, copy, nullable) void (^toggleFiles)(void);
@property (nonatomic, copy, nullable) NSString *metaTitle;
/// The caret's box, for tests.
@property (nonatomic, readonly) NSRect caretRect;
/// Collapses or expands a snippet (the click, the pill and Collapse).
- (void)toggleExpansion;
@property (nonatomic, readonly, getter=isExpanded) BOOL expanded;
@end

/// Draws the picture at `url` filling `rect` (flipped context) in a rounded frame with Slack's
/// inset ring, base-ter until it loads; `view` holds it (render/images.h).
void SNDrawFilePicture(NSURL *_Nullable url, NSRect rect, CGFloat radius, NSView *view);
/// The file's type icon filling `rect` (36 pt on cards).
void SNDrawFileTypeIcon(SNFile *file, NSRect rect);
/// The glyph on that icon ("pdf-file", "canvas", "lists"), for lists that show it alone.
NSString *SNFileTypeGlyph(SNFile *file);
/// The size of the file's view in a text column `width` wide (a grid cell's width when it shares
/// the message with other files).
NSSize SNFileViewSize(SNFile *file, SNFileStyle style, CGFloat width, NSString *context);
/// The collapsed files' line: `title` and the caret, at most `width`.
NSSize SNCollapsedFilesSize(NSString *title, CGFloat width);
/// The view that draws `style`.
SNFileView *SNMakeFileView(SNFile *file, SNFileStyle style, NSString *context);
/// Releases cached expanded snippet texts (called on sign-out).
void SNResetExpandedSnippets(void);

NS_ASSUME_NONNULL_END
