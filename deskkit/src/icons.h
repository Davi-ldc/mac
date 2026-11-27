// Local icons the launcher draws (files, symbols, commands), made at row size and kept
// in memory once made.
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, DKCommand) {
    DKCommandSearchQuicklinks,
    DKCommandCreateQuicklink,
    DKCommandClipboardHistory,
    DKCommandGoogleSearch,
};

/// Finder's icon for a file, folder or application.
NSImage *DKFileIcon(NSString *path);
/// Makes the icons of `paths` in the background, so that the rows that come to show them
/// do not have to: each takes about a millisecond of the key press that first lists it.
void DKWarmFileIcons(NSArray<NSString *> *paths);
/// Raycast's artwork when the installer copied it for personal use; otherwise an SF Symbol
/// on a coloured rounded square in the same spirit.
NSImage *DKCommandIcon(DKCommand command);
/// Raycast's monochrome logo as a template image, or a magnifying glass.
NSImage *DKLogo(void);
/// An SF Symbol in white.
NSImage *DKSymbolIcon(NSString *name);

/// A row-sized copy of an image, fitted inside the square: system and site icons carry
/// representations up to 1024 pixels that would otherwise stay decoded in memory.
NSImage *DKIconThumbnail(NSImage *image);
/// The thumbnail's single bitmap, with its corners rounded by `cornerRadius` points.
NSBitmapImageRep *DKIconBitmap(NSImage *image, CGFloat cornerRadius);

NS_ASSUME_NONNULL_END
