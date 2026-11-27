// A view that draws itself, for the picker's drawn views that can be large.
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Draws its -drawRect: on the CPU, into a plain layer of its own. On AppKit's own layer,
/// drawing that covers more than about 384 × 384 pixels is replayed by Core Animation's GPU
/// rasterizer, which holds some 150 MB of buffers for a second after every draw. The plain
/// layer covers the whole view at up to eight bytes a pixel, so a hidden view gives it up.
@interface DKDrawnView : NSView
@end

NS_ASSUME_NONNULL_END
