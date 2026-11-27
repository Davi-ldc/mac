// The hover actions of an Activity row (the web client's ActivityRowContentActions, CSS
// activity_row_content__actions): a base-pry group with radius 12, 4 pt padding and a 1 pt
// rgba(232,232,232,.13) ring over a 0 1px 3px shadow, holding 32 pt buttons with 18 pt glyphs in
// content-pry. Hovered, a button takes the 4% fill and its glyph scales 1.2 over 80 ms; its tooltip
// shows above.
#import "ui/kit/hoverview.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SNActivityAction) {
    /// Unread entries.
    SNActivityActionMarkRead,
    /// Read entries other than reactions.
    SNActivityActionMarkUnread,
    SNActivityActionClear,
    /// The overflow menu.
    SNActivityActionMore,
};

/// The bar's height: the buttons and the padding around them.
static const CGFloat SNActivityActionsHeight = 40;

@interface SNActivityActionBar : NSView
/// The buttons, in Slack's order: read or unread, Clear, More actions.
- (void)showActions:(NSArray<NSNumber *> *)actions;
@property (nonatomic, readonly) NSArray<NSNumber *> *actions;
@property (nonatomic, readonly) CGFloat width;
/// `rect` is the button pressed, in the bar's coordinates.
@property (nonatomic, copy, nullable) void (^chosen)(SNActivityAction action, NSRect rect);
/// The buttons, for tests and snapshots.
@property (nonatomic, readonly) NSArray<SNHoverView *> *buttons;
@end

NS_ASSUME_NONNULL_END
