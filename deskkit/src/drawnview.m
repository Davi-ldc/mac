// Owns keeping a drawn view's picture off the GPU rasterizer, and out of memory while hidden.
#import <QuartzCore/QuartzCore.h>

#import "drawnview.h"

/// Core Animation draws a layer that asks for it whether or not anyone can see it.
@interface DKDrawnLayer : CALayer
@end

@implementation DKDrawnLayer
- (void)display {
    if (!((NSView *)self.delegate).hiddenOrHasHiddenAncestor) [super display];
}
@end

@implementation DKDrawnView

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.wantsLayer = YES;
    // AppKit leaves a layer that is not its own alone unless told otherwise.
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawDuringViewResize;
    return self;
}

- (CALayer *)makeBackingLayer { return [DKDrawnLayer layer]; }

// Nor does AppKit match such a layer to the screen's pixels.
- (void)viewDidChangeBackingProperties {
    [super viewDidChangeBackingProperties];
    if (!self.window) return;
    self.layer.contentsScale = self.window.backingScaleFactor;
    self.needsDisplay = YES;
}

- (void)viewDidHide {
    [super viewDidHide];
    self.layer.contents = nil;
}

- (void)viewDidUnhide {
    [super viewDidUnhide];
    self.needsDisplay = YES;
}

@end
