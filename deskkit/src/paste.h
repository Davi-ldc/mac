// Pasting into another app with the keyboard.
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Sends ⌘V to `app` once it is in front, since the keystroke goes to whatever is; after a
/// second without it coming forward the paste is dropped.
void DKPasteInto(NSRunningApplication *app);

NS_ASSUME_NONNULL_END
