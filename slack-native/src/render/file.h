// How the official client shows a message's file (its message file components, read from the
// client's static JS and CSS): which component draws it, the words on its card, a video's or
// clip's length and a snippet's preview lines with Slack's highlighting.
#import <AppKit/AppKit.h>

#import "model/message.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SNFileStyle) {
    /// The card: the type icon, the name and the kind.
    SNFileStyleCard,
    /// The picture under its name line.
    SNFileStyleImage,
    /// The poster with a play button and the length; plays in place.
    SNFileStyleVideo,
    /// The audio player: play button, waveform or progress bar, length.
    SNFileStyleAudio,
    /// The card with the first page under it (thumb_pdf).
    SNFileStyleDocument,
    /// The card with the first lines of text or code under it.
    SNFileStyleSnippet,
    /// The message's files collapsed: only their meta line (the name, or how many), with the
    /// caret that expands them.
    SNFileStyleCollapsed,
};

SNFileStyle SNFileStyleOf(SNFile *file);
/// Recorded in Slack (slack_audio...): the flat player with a waveform instead of the card.
BOOL SNFileIsAudioClip(SNFile *file);

/// The card's second line: the kind ("PDF", "Word Document", "Google Doc").
NSString *SNFileDescription(SNFile *file);

/// "0:08", "12:04", "1:02:03".
NSString *SNFormatDuration(NSTimeInterval seconds);

/// A snippet's first lines as the server highlighted them (preview_highlight), else its plain
/// preview; CSV and TSV come as rows of cells.
@interface SNSnippetPreview : NSObject
+ (nullable instancetype)previewOfFile:(SNFile *)file;
/// One attributed line per source line: Roboto Mono 13 in Slack's dark code colours.
@property (nonatomic, readonly) NSArray<NSAttributedString *> *lines;
/// Rows of cells for CSV/TSV (nil otherwise); `numericCells` marks the right-aligned ones.
@property (nonatomic, readonly, nullable) NSArray<NSArray<NSString *> *> *rows;
@property (nonatomic, readonly, nullable) NSArray<NSIndexSet *> *numericCells;
/// The whole file's text (read when the reader expands the snippet): the preview's highlighted
/// lines where they match, the rest plain; at most `maximum` lines or rows, `truncated` beyond.
- (instancetype)previewWithContent:(NSString *)content maximumLines:(NSUInteger)maximum;
@property (nonatomic, readonly) BOOL truncated;
@end

NS_ASSUME_NONNULL_END
