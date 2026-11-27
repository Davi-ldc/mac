// Raycast's keycap chips: an outlined little key per modifier and key of a shortcut.
#import <AppKit/AppKit.h>

#import "items.h"

NS_ASSUME_NONNULL_BEGIN

/// Width the chips need; zero without a shortcut.
CGFloat DKKeycapsWidth(DKShortcut *_Nullable shortcut);
/// Draws the chips into the current (flipped) context, vertically centred on `centerY`.
void DKDrawKeycaps(DKShortcut *_Nullable shortcut, CGFloat x, CGFloat centerY);

/// A view holding one shortcut's chips.
@interface DKKeycaps : NSView
- (instancetype)initWithShortcut:(nullable DKShortcut *)shortcut;
@property(strong, nullable, nonatomic) DKShortcut *shortcut;
@property(readonly) CGFloat width;
@end

NS_ASSUME_NONNULL_END
