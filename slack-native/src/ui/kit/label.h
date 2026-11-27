// Text laid out the way the web client lays it out: CSS line boxes (the baseline sits where a
// browser puts it for the line-height), grayscale antialiasing without font smoothing (Slack sets
// -webkit-font-smoothing: antialiased), soft hyphens shown as hyphens at line ends, and an
// ellipsis on the last line that does not fit.
#import <AppKit/AppKit.h>

#import "theme/theme.h"

NS_ASSUME_NONNULL_BEGIN

@interface SNLabel : NSView
@property (nonatomic, copy) NSString *text;
@property (nonatomic) NSFont *font;
@property (nonatomic) SNColorToken color;
/// The CSS line-height in points; 0 uses the font's ascent plus descent.
@property (nonatomic) CGFloat lineHeight;
@property (nonatomic) NSTextAlignment alignment;
/// 1 by default; 0 for as many as the text needs.
@property (nonatomic) NSUInteger maximumLines;
/// CSS text-wrap: balance, lines of similar length (the rail's labels).
@property (nonatomic) BOOL balanced;

+ (instancetype)labelWithText:(NSString *)text font:(NSFont *)font color:(SNColorToken)color;
/// Height of the text wrapped at `width`, in whole lines.
- (CGFloat)heightForWidth:(CGFloat)width;
/// Width of the text on one line.
@property (nonatomic, readonly) CGFloat textWidth;
@end

/// Draws `text` into the current context the way SNLabel does, lines top-down from the top of
/// `rect` (in a flipped context), for views that draw several texts in one -drawRect:.
void SNDrawText(NSString *text, NSFont *font, SNColorToken color, CGFloat lineHeight, NSTextAlignment alignment,
                NSUInteger maximumLines, NSRect rect);
/// Width of `text` on one line in `font` (without allocating a label view).
CGFloat SNTextWidth(NSString *text, NSFont *font);
/// The lines `text` breaks into at `width`.
NSUInteger SNLineCount(NSString *text, NSFont *font, CGFloat width, NSUInteger maximumLines);
/// The narrowest width at which `text` still takes as few lines as at `width`.
CGFloat SNBalancedWidth(NSString *text, NSFont *font, CGFloat width);

NS_ASSUME_NONNULL_END
