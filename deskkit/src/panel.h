// The floating window the picker draws in.
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// A view laid out from the top left, which is how every picker view measures.
@interface DKFlippedView : NSView
@end

/// A patch of the panel's own material, lightened by white at `lighten` opacity, with
/// Raycast's glass edge. It shows what is behind the window rather than the views under
/// it, so rows scrolling beneath a pill or menu disappear the way they do under Raycast's
/// glass. A corner radius of half the height or more makes a pill.
NSView *DKGlass(CGFloat lighten, CGFloat cornerRadius);

/// Borderless, key-capable panel with Raycast's rounded dark material. Key presses go to
/// `keyHandler` first, so shortcuts work whichever subview has focus. The ones it leaves
/// that an Edit menu would take (⌘X, ⌘C, ⌘V, ⌘A, ⌘Z, ⇧⌘Z) edit the field with the keyboard.
@interface DKPanel : NSPanel
- (instancetype)init;
/// Where the picker's views go; same size as the panel, origin at the top left.
@property(readonly) DKFlippedView *canvas;
/// Returns YES when it handled the key press.
@property(copy, nullable) BOOL (^keyHandler)(NSEvent *event);
/// Told of every key release, which then goes on as usual.
@property(copy, nullable) void (^keyUpHandler)(NSEvent *event);
@end

NS_ASSUME_NONNULL_END
