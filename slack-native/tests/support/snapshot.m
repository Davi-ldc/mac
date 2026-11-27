// Owns offscreen rendering, PNG reading and writing, alignment and the per-region report.
#import <ImageIO/ImageIO.h>
#import <QuartzCore/QuartzCore.h>

#import "render/images.h"
#import "snapshot.h"
#import "test.h"

/// A pixel differs when one of its channels is off by more than this (of 255): beyond the
/// rounding of colour conversion and gradient dithering, within a visible change.
static const int kDifferent = 24;
static NSURL *output;

void SNSetSnapshotOutput(NSURL *folder) { output = folder; }

@implementation SNPixels {
    NSMutableData *_data;
}

- (instancetype)initWithWidth:(size_t)width height:(size_t)height {
    if (!(self = [super init])) return nil;
    _width = width;
    _height = height;
    _data = [NSMutableData dataWithLength:width * height * 4];
    return self;
}

- (uint8_t *)bytes { return _data.mutableBytes; }

- (CGContextRef)newContext {
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(self.bytes, self.width, self.height, 8, self.width * 4, space,
                                                 (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    return context;
}

+ (instancetype)pixelsWithPNG:(NSURL *)url {
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    CGImageRef image = source ? CGImageSourceCreateImageAtIndex(source, 0, NULL) : NULL;
    if (source) CFRelease(source);
    if (!image) return nil;
    SNPixels *pixels = [[self alloc] initWithWidth:CGImageGetWidth(image) height:CGImageGetHeight(image)];
    CGContextRef context = [pixels newContext];
    CGContextDrawImage(context, CGRectMake(0, 0, pixels.width, pixels.height), image);
    CGContextRelease(context);
    CGImageRelease(image);
    return pixels;
}

- (BOOL)writePNG:(NSURL *)url {
    [NSFileManager.defaultManager createDirectoryAtURL:url.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    CGContextRef context = [self newContext];
    CGImageRef image = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL((__bridge CFURLRef)url, CFSTR("public.png"), 1, NULL);
    CGImageDestinationAddImage(destination, image, NULL);
    BOOL written = CGImageDestinationFinalize(destination);
    CFRelease(destination);
    CGImageRelease(image);
    return written;
}

- (uint32_t)colorAtPoint:(NSPoint)point {
    size_t x = (size_t)MIN(self.width - 1, MAX(0, point.x * SNSnapshotScale));
    size_t y = (size_t)MIN(self.height - 1, MAX(0, point.y * SNSnapshotScale));
    const uint8_t *p = self.bytes + (y * self.width + x) * 4;
    return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}

@end

#pragma mark Rendering

static SNPixels *Render(CALayer *layer, NSSize size) {
    SNPixels *pixels = [[SNPixels alloc] initWithWidth:(size_t)ceil(size.width * SNSnapshotScale) height:(size_t)ceil(size.height * SNSnapshotScale)];
    CGContextRef context = [pixels newContext];
    CGContextScaleCTM(context, SNSnapshotScale, SNSnapshotScale);
    [layer renderInContext:context];
    CGContextRelease(context);
    return pixels;
}

/// Lays out and draws everything AppKit would before a frame, and lets the pictures the drawing
/// asked for land (an offscreen window's views draw when rendered, so it renders once first).
static void Prepare(NSWindow *window, CALayer *layer, NSSize size) {
    for (int pass = 0; pass < 2; pass++) {
        [window.contentView layoutSubtreeIfNeeded];
        [window displayIfNeeded];
        [CATransaction flush];
        Render(layer, size);
        NSDate *patience = [NSDate dateWithTimeIntervalSinceNow:3];
        while (SNImageLoadsInFlight() && patience.timeIntervalSinceNow > 0) SNSettle(0.01);
    }
}

SNPixels *SNRenderWindow(NSWindow *window) {
    SNFlushChanges();
    // The frame view holds the content and the titlebar with the traffic lights.
    NSView *frame = window.contentView.superview ?: window.contentView;
    Prepare(window, frame.layer, frame.bounds.size);
    return Render(frame.layer, frame.bounds.size);
}

SNPixels *SNRenderView(NSView *view, NSSize size) {
    SNFlushChanges();
    NSWindow *window = view.window;
    if (!window) {
        // The view goes inside a content view: AppKit flips a window's root layer itself, which
        // rendering from that layer would miss.
        window = [[NSWindow alloc] initWithContentRect:(NSRect){NSZeroPoint, size} styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:YES];
        window.releasedWhenClosed = NO;
        window.opaque = NO;
        window.backgroundColor = NSColor.clearColor;
        NSView *content = [[NSView alloc] initWithFrame:(NSRect){NSZeroPoint, size}];
        content.wantsLayer = YES;
        window.contentView = content;
        [content addSubview:view];
        [view setFrameOrigin:NSZeroPoint];
    }
    [view setFrameSize:size];
    CALayer *root = window.contentView.superview.layer ?: window.contentView.layer;
    Prepare(window, root, window.frame.size);
    SNPixels *whole = Render(root, window.frame.size);
    NSRect rect = [view convertRect:view.bounds toView:nil];
    rect.origin.y = window.frame.size.height - NSMaxY(rect);
    SNPixels *pixels = [[SNPixels alloc] initWithWidth:(size_t)(rect.size.width * SNSnapshotScale) height:(size_t)(rect.size.height * SNSnapshotScale)];
    for (size_t row = 0; row < pixels.height; row++) {
        size_t sourceRow = (size_t)(rect.origin.y * SNSnapshotScale) + row, sourceColumn = (size_t)(rect.origin.x * SNSnapshotScale);
        if (sourceRow >= whole.height) break;
        memcpy(pixels.bytes + row * pixels.width * 4, whole.bytes + (sourceRow * whole.width + sourceColumn) * 4,
               MIN(pixels.width, whole.width - sourceColumn) * 4);
    }
    return pixels;
}

void SNSaveSnapshot(NSString *name, SNPixels *pixels) {
    NSURL *url = [output URLByAppendingPathComponent:[name stringByAppendingPathExtension:@"png"]];
    SNExpect([pixels writePNG:url], [NSString stringWithFormat:@"%@ saved", name].UTF8String);
}

#pragma mark Comparison

@interface SNRegion ()
@property (nonatomic, copy) NSString *name;
@property (nonatomic) NSRect rect;
@property (nonatomic) double budget;
@property (nonatomic) BOOL ignored;
@end

@implementation SNRegion

+ (instancetype)region:(NSString *)name rect:(NSRect)rect budget:(double)budget {
    SNRegion *region = [self new];
    region.name = name;
    region.rect = rect;
    region.budget = budget;
    return region;
}

+ (instancetype)ignored:(NSString *)name rect:(NSRect)rect {
    SNRegion *region = [self region:name rect:rect budget:100];
    region.ignored = YES;
    return region;
}

@end

static int Difference(const uint8_t *a, const uint8_t *b) {
    int r = abs(a[0] - b[0]), g = abs(a[1] - b[1]), bl = abs(a[2] - b[2]);
    return MAX(r, MAX(g, bl));
}

/// The mean difference of the reference against the render at pixel offset (x, y), skipping the
/// pixels `skip` marks (the ignored regions).
static double Score(SNPixels *render, SNPixels *reference, const uint8_t *skip, long x, long y) {
    uint64_t total = 0, count = 0;
    for (size_t row = 0; row < reference.height; row++) {
        long renderRow = y + (long)row;
        if (renderRow < 0 || renderRow >= (long)render.height) continue;
        for (size_t column = 0; column < reference.width; column++) {
            long renderColumn = x + (long)column;
            if (renderColumn < 0 || renderColumn >= (long)render.width || skip[row * reference.width + column]) continue;
            total += (uint64_t)Difference(reference.bytes + (row * reference.width + column) * 4,
                                          render.bytes + ((size_t)renderRow * render.width + (size_t)renderColumn) * 4);
            count++;
        }
    }
    return count ? (double)total / count : INFINITY;
}

void SNCompareWithReference(NSString *name, SNPixels *pixels, NSString *referenceName, NSPoint origin, CGFloat slack,
                            NSArray<SNRegion *> *regions) {
    NSURL *referenceURL = [SNRepository() URLByAppendingPathComponent:[NSString stringWithFormat:@"design/ref/%@.png", referenceName]];
    SNPixels *reference = [SNPixels pixelsWithPNG:referenceURL];
    if (!reference) {
        printf("skip %s: no design/ref/%s.png\n", name.UTF8String, referenceName.UTF8String);
        SNSaveSnapshot(name, pixels);
        return;
    }
    // Ignored regions hold content that is meant to differ; they would only pull the alignment.
    NSMutableData *skip = [NSMutableData dataWithLength:reference.width * reference.height];
    for (SNRegion *region in regions) {
        if (!region.ignored) continue;
        size_t x0 = (size_t)MAX(0, region.rect.origin.x * SNSnapshotScale), y0 = (size_t)MAX(0, region.rect.origin.y * SNSnapshotScale);
        size_t x1 = (size_t)MIN((CGFloat)reference.width, NSMaxX(region.rect) * SNSnapshotScale);
        size_t y1 = (size_t)MIN((CGFloat)reference.height, NSMaxY(region.rect) * SNSnapshotScale);
        for (size_t row = y0; row < y1; row++) memset((uint8_t *)skip.mutableBytes + row * reference.width + x0, 1, x1 > x0 ? x1 - x0 : 0);
    }
    long baseX = lround(origin.x * SNSnapshotScale), baseY = lround(origin.y * SNSnapshotScale), reach = lround(slack * SNSnapshotScale);
    long bestX = baseX, bestY = baseY, bestDistance = LONG_MAX;
    double best = INFINITY;
    for (long dy = -reach; dy <= reach; dy++)
        for (long dx = -reach; dx <= reach; dx++) {
            double score = Score(pixels, reference, skip.bytes, baseX + dx, baseY + dy);
            // Ties go to the offset nearest the expected origin.
            long distance = labs(dx) + labs(dy);
            if (score < best - 1e-9 || (score < best + 1e-9 && distance < bestDistance))
                best = score, bestX = baseX + dx, bestY = baseY + dy, bestDistance = distance;
        }

    // The render's part under the reference, then the stacked comparison for design/_diff.
    SNPixels *crop = [[SNPixels alloc] initWithWidth:reference.width height:reference.height];
    SNPixels *stack = [[SNPixels alloc] initWithWidth:reference.width height:reference.height * 3];
    size_t rowBytes = reference.width * 4;
    for (size_t row = 0; row < reference.height; row++) {
        long renderRow = bestY + (long)row;
        for (size_t column = 0; column < reference.width; column++) {
            long renderColumn = bestX + (long)column;
            uint8_t *mine = crop.bytes + (row * reference.width + column) * 4;
            if (renderRow >= 0 && renderRow < (long)pixels.height && renderColumn >= 0 && renderColumn < (long)pixels.width)
                memcpy(mine, pixels.bytes + ((size_t)renderRow * pixels.width + (size_t)renderColumn) * 4, 4);
            const uint8_t *theirs = reference.bytes + (row * reference.width + column) * 4;
            int difference = Difference(mine, theirs);
            uint8_t *heat = stack.bytes + ((2 * reference.height + row) * reference.width + column) * 4;
            heat[0] = difference > kDifferent ? 255 : (uint8_t)MIN(255, difference * 4);
            heat[1] = heat[2] = difference > kDifferent ? 0 : (uint8_t)MIN(255, difference * 4);
            heat[3] = 255;
        }
        memcpy(stack.bytes + row * rowBytes, reference.bytes + row * rowBytes, rowBytes);
        memcpy(stack.bytes + (reference.height + row) * rowBytes, crop.bytes + row * rowBytes, rowBytes);
    }
    SNSaveSnapshot(name, crop);
    [stack writePNG:[SNRepository() URLByAppendingPathComponent:[NSString stringWithFormat:@"design/_diff/%@.png", name]]];

    printf("%s vs %s: aligned at %+.1f,%+.1f pt from the expected origin\n", name.UTF8String, referenceName.UTF8String,
           (bestX - baseX) / SNSnapshotScale, (bestY - baseY) / SNSnapshotScale);
    NSMutableArray *all = [regions mutableCopy];
    [all addObject:[SNRegion ignored:@"(whole crop)" rect:NSMakeRect(0, 0, reference.width / SNSnapshotScale, reference.height / SNSnapshotScale)]];
    for (SNRegion *region in all) {
        NSRect rect = region.rect;
        size_t x0 = (size_t)MAX(0, rect.origin.x * SNSnapshotScale), y0 = (size_t)MAX(0, rect.origin.y * SNSnapshotScale);
        size_t x1 = (size_t)MIN((CGFloat)reference.width, NSMaxX(rect) * SNSnapshotScale);
        size_t y1 = (size_t)MIN((CGFloat)reference.height, NSMaxY(rect) * SNSnapshotScale);
        uint64_t differing = 0, total = 0, sum = 0;
        for (size_t row = y0; row < y1; row++)
            for (size_t column = x0; column < x1; column++) {
                size_t index = (row * reference.width + column) * 4;
                int difference = Difference(crop.bytes + index, reference.bytes + index);
                sum += (uint64_t)difference;
                differing += difference > kDifferent;
                total++;
            }
        double share = total ? 100.0 * differing / total : 0, mean = total ? (double)sum / total : 0;
        NSString *line = [NSString stringWithFormat:@"%@ / %@: %.1f%% differ, mean %.1f%@", name, region.name, share, mean,
                                                    region.ignored ? @"" : [NSString stringWithFormat:@" (budget %.0f%%)", region.budget]];
        if (region.ignored) printf("     %s\n", line.UTF8String);
        else SNExpect(share <= region.budget, line.UTF8String);
    }
}
