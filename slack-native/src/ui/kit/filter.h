// Slack's c-filter_input--small--themed, the "Encontrar uma MD..." field over the DMs list and
// the "Encontrar uma conversa..." one atop the Home sidebar (components.json
// sidebar_filter_input): 28 pt tall, radius 8, a 1 pt rgba(239,225,245,0.22) border on
// rgba(16,18,20,0.6), the filter glyph and 13 pt text. Hovering changes nothing (live); while it
// has the caret the border gives way to the focus ring, and while it has text the clear button
// shows at its right.
#import <AppKit/AppKit.h>

#import "theme/theme.h"

NS_ASSUME_NONNULL_BEGIN

@interface SNFilterField : NSView
- (instancetype)initWithPlaceholder:(NSString *)placeholder;
@property (nonatomic, readonly) NSTextField *textField;
/// What is typed; setting it calls no block.
@property (nonatomic, copy) NSString *text;
/// The glyph's centre and the text's start from the left edge, and the glyph's colour (the DMs
/// field's by default).
@property (nonatomic) CGFloat glyphCentre, textX;
@property (nonatomic) SNColorToken glyphColor;
/// Each edit, and the clear button or Escape emptying the field.
@property (nonatomic, copy, nullable) void (^textChanged)(NSString *text);
/// After textChanged, when the clear button or Escape emptied the field.
@property (nonatomic, copy, nullable) void (^cleared)(void);
/// Down arrow while typing (the Home sidebar moves the keyboard to its list).
@property (nonatomic, copy, nullable) void (^downPressed)(void);
/// The field has the caret.
@property (nonatomic, readonly, getter=isFocused) BOOL focused;
/// The clear button, shown while there is text.
@property (nonatomic, readonly) NSView *clearButton;
/// Gives the field the caret.
- (void)focus;
@end

/// How far the focus ring reaches out of what it surrounds.
static const CGFloat SNFocusRingReach = 5;

/// Slack's keyboard focus ring (box-shadow 0 0 0 1px otl-hgl-1, 0 0 0 5px otl-hgl-1 at 30%):
/// a 1 pt line and a 30% band out to 5 pt around a rounded rect. Hide it with opacity.
@interface SNFocusRingLayer : SNLayer
/// Places the ring around `rect` (its superlayer's coordinates); the layer reaches 5 pt out.
- (void)setRingAroundRect:(CGRect)rect radius:(CGFloat)radius;
@end

NS_ASSUME_NONNULL_END
