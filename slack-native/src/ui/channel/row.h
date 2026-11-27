// One message in a list: drawn from its SNMessageLayout (avatar, sender, time, body), with its
// files, reaction pills and reply bar as small views. A message being sent is dimmed; one that
// failed offers Retry and Delete under it. Hover is set by the list (one tracking
// area for all rows): #222529 at once, the continuation's time in the gutter, the action bar.
// The parts under the pointer (avatar and name show the profile card and open the full profile on
// a click, the time shows its tooltip and underline, links underline, mentions light up) follow
// -pointerMovedTo:.
#import <AppKit/AppKit.h>

#import "ui/channel/messagelayout.h"

NS_ASSUME_NONNULL_BEGIN

@class SNMessageRowView;

@protocol SNMessageRowDelegate <NSObject>
/// A click on a link, mention, channel, button or picture in the message.
- (void)messageRow:(SNMessageRowView *)row activateTarget:(SNRenderTarget *)target;
- (void)messageRowOpenThread:(SNMessageRowView *)row;
- (void)messageRow:(SNMessageRowView *)row toggleReaction:(NSString *)name;
/// The add-reaction pill was clicked; `view` is the pill.
- (void)messageRow:(SNMessageRowView *)row addReactionFromView:(NSView *)view;
/// The Retry or Delete link of a failed send.
- (void)messageRowRetrySend:(SNMessageRowView *)row;
- (void)messageRowDiscardSend:(SNMessageRowView *)row;
/// A collapse toggle of the message's files or pictures was clicked.
- (void)messageRow:(SNMessageRowView *)row setItems:(NSArray<NSString *> *)keys expanded:(BOOL)expanded;
/// A file changed size (a snippet expanded or collapsed): lay the message out again.
- (void)messageRowNeedsLayout:(SNMessageRowView *)row;
@end

@interface SNMessageRowView : NSView
- (instancetype)initWithSource:(id<SNSource>)source;
/// The message drawn from `layout` (made from this message, or from an unchanged copy of it).
- (void)showMessage:(nullable SNMessage *)message layout:(nullable SNMessageLayout *)layout;
/// Drops retained message, layout, attachments and images when returning to the recycle pool.
- (void)prepareForReuse;
@property (nonatomic, readonly, nullable) SNMessage *message;
@property (nonatomic, readonly, nullable) SNMessageLayout *layout;
@property (nonatomic, getter=isHovered) BOOL hovered;
/// The message whose thread is open beside the list (Slack's active-thread tint).
@property (nonatomic) BOOL highlighted;
@property (nonatomic, weak, nullable) id<SNMessageRowDelegate> delegate;
/// The clock the reply bar's "last reply" is worded against.
@property (nonatomic) NSDate *now;
/// The pointer at `point` (row coordinates) while the row is hovered.
- (void)pointerMovedTo:(NSPoint)point;
- (void)clickAt:(NSPoint)point;
/// The views of the reactions (then the add pill) and the reply bar, for tests and snapshots.
@property (nonatomic, readonly) NSArray<NSView *> *pills;
@property (nonatomic, readonly, nullable) NSView *replyBar;
@end

NS_ASSUME_NONNULL_END
