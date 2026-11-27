// Offscreen rendering and pixel comparison with the official app's captures (design/ref).
//
// Everything renders through Core Animation into a bitmap at 2 pixels per point, the captures'
// scale, without ordering a window in, activating the app or touching the pointer. Hover and
// pressed states are set on the views (SNHoverView.hovered/pressed) before rendering.
//
// Renders go to $(BUILD)/snapshots. Images made from a reference (the stacked reference, render
// and difference) contain company content, so they go to design/_diff, which stays private.
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

static const CGFloat SNSnapshotScale = 2;

/// An sRGB RGBA8 bitmap, premultiplied, rows top to bottom.
@interface SNPixels : NSObject
@property (nonatomic, readonly) size_t width, height;
@property (nonatomic, readonly) uint8_t *bytes;
- (instancetype)initWithWidth:(size_t)width height:(size_t)height;
/// Converted to sRGB from the file's colour space (the captures are Display P3).
+ (nullable instancetype)pixelsWithPNG:(NSURL *)url;
- (BOOL)writePNG:(NSURL *)url;
/// The colour at a point (in points), as 0xRRGGBBAA.
- (uint32_t)colorAtPoint:(NSPoint)point;
@end

/// The window as the screen would show it: content, frame and traffic lights. Delivers the
/// changes made so far, lays the window out and waits for its images first. The window is never
/// shown.
SNPixels *SNRenderWindow(NSWindow *window);
/// A view on its own at `size` (after the changes made so far), in an offscreen window of its own
/// if it has none.
SNPixels *SNRenderView(NSView *view, NSSize size);

/// A named part of a reference crop, in points from the crop's top-left. `budget` is the most
/// differing pixels it may have, in percent; an ignored region is reported but never fails.
@interface SNRegion : NSObject
+ (instancetype)region:(NSString *)name rect:(NSRect)rect budget:(double)budget;
+ (instancetype)ignored:(NSString *)name rect:(NSRect)rect;
@end

/// Compares `pixels` with design/ref/<reference>.png placed at `origin` (points), trying offsets
/// up to `slack` points away for the best alignment, and prints each region's share of
/// differing pixels (a channel off by more than 24) and mean difference. Fails a check for each
/// region over budget. Saves <name>.png and, privately, the stacked comparison. Without
/// design/ it only saves the render.
void SNCompareWithReference(NSString *name, SNPixels *pixels, NSString *reference, NSPoint origin, CGFloat slack,
                            NSArray<SNRegion *> *regions);
/// Writes <output>/<name>.png.
void SNSaveSnapshot(NSString *name, SNPixels *pixels);
void SNSetSnapshotOutput(NSURL *folder);

NS_ASSUME_NONNULL_END
