// The window's aubergine background (tokens.json window_background, effects.txt [L2]): a conic
// gradient from 45° alternating aubergine-0 and aubergine-10 around the centre, under a radial
// aubergine-10 glow; at brightness 0.9 while the window is in the background ([A1]).
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface SNBackgroundView : NSView
@property (nonatomic) BOOL dimmed;
@end

NS_ASSUME_NONNULL_END
