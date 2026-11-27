// What a paste or a drop attaches, as a browser hands it to Slack's client: the files of a
// Finder copy or drag, else a picture alone on the pasteboard (a screenshot) as "image.png".
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Pasteboard types a drop of files or a picture comes as (for registerForDraggedTypes:).
NSArray<NSPasteboardType> *SNComposerFileTypes(void);
/// Local file URLs to attach; a picture is written to a file of its own in the temporary folder.
/// Empty when the pasteboard holds no files, or text besides a picture (that pastes as text).
NSArray<NSURL *> *SNComposerFilesFromPasteboard(NSPasteboard *pasteboard);

NS_ASSUME_NONNULL_END
