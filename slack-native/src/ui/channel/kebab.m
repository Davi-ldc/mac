// Owns the kebab's fills.
#import "ui/channel/kebab.h"

/// #434548 over #2c2e31: the 18% press overlay as measured.
static const SNColorToken kPressed = 0xf8f8f81d;

@implementation SNKebabButton

+ (instancetype)kebabWithSize:(CGFloat)size iconSize:(CGFloat)iconSize {
    SNKebabButton *button = [self iconButtonNamed:@"ellipsis-vertical-filled" size:size iconSize:iconSize];
    button.hoverFillColor = SNMeasuredHeaderKebabHover;
    button.pressedColor = kPressed;
    button.transitionDuration = 0;
    return button;
}

@end
