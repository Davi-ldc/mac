// What covers a conversation or thread while files are dragged over it (client-boot-styles
// .p-message_pane_drag_overlay, .p-thread_drag_overlay): the pane's background at 95% and,
// centred, a 28 pt black title over a 15 pt line naming Shift in a key chip. The conversation's
// fades in over 120 ms. Slack's illustration above the title is not in the cached client.
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface SNComposerDropOverlay : NSView
/// "Upload to Northwind" over "Hold [Shift] to share immediately to #general": `hint` holds %@
/// where the chip goes; `thread` uses the thread pane's padding and colours.
- (instancetype)initWithTitle:(NSString *)title hint:(NSString *)hint thread:(BOOL)thread;
@property (nonatomic, readonly) NSString *title, *hint;
@end

NS_ASSUME_NONNULL_END
