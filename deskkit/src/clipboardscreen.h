// The Clipboard History screen.
#import "picker.h"

NS_ASSUME_NONNULL_BEGIN

/// The history's entries with their details; choosing one pastes it into the app that was
/// in front when the panel opened.
DKPage *DKClipboardPage(DKPicker *picker);

/// An image entry's content as its preview: scaled down to fit `room` points on a screen
/// of `scale` pixels per point, and never up beyond the image's own size in points. Nil
/// when `png` is no image.
NSImage *_Nullable DKClipPreview(NSData *png, NSSize room, CGFloat scale);

NS_ASSUME_NONNULL_END
