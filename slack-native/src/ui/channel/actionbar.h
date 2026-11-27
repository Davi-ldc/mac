// The floating actions bar of the hovered message (components.json message_actions_bar,
// effects.txt [B2], measured live): a #1a1d21 group with a 1 pt #3a3d42 border and radius 12,
// 40 pt tall, its top 16 pt above the row and its right edge 21 pt from the pane's. 32 pt
// buttons: three quick reactions, add reaction, reply, forward, add task, summarize (threads
// only) and more. Hover: rgba(232,232,232,0.04), icon #ababad -> #d1d2d3 scaled 1.2 over 80 ms
// (add reaction also turns 4°), a tooltip above after 60 ms; pressing changes nothing.
#import <AppKit/AppKit.h>

#import "model/message.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SNMessageAction) {
    SNMessageActionQuickReaction,
    SNMessageActionAddReaction,
    SNMessageActionReply,
    SNMessageActionForward,
    SNMessageActionTask,
    SNMessageActionSummarize,
    SNMessageActionMore,
};

static const CGFloat SNActionBarHeight = 40, SNActionBarTopOffset = -16, SNActionBarRightInset = 21;

@interface SNMessageActionBar : NSView
/// Sets the buttons for `message`; `inThread` drops the reply button (replies in the thread pane).
- (void)showForMessage:(SNMessage *)message inThread:(BOOL)inThread;
@property (nonatomic, readonly, nullable) SNMessage *message;
/// The bar's width for its current buttons.
@property (nonatomic, readonly) CGFloat width;
/// `reaction` is the quick reaction's emoji name; `rect` the button in the bar's coordinates.
@property (nonatomic, copy, nullable) void (^action)(SNMessageAction action, NSString *_Nullable reaction, NSRect rect);
/// The bar's buttons, for tests and snapshots.
@property (nonatomic, readonly) NSArray<NSView *> *buttons;
@end

NS_ASSUME_NONNULL_END
