// Owns making local icons (files, symbols, commands) at row size and keeping them in memory.
#import "icons.h"
#import "support.h"
#import "theme.h"

/// Asked from the main thread and from DKWarmFileIcons' queue.
static NSImage *Cached(NSString *key, NSImage *_Nullable (^make)(void)) {
    static NSCache<NSString *, NSImage *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSCache new]; });
    NSImage *image = [cache objectForKey:key];
    if (!image && (image = make())) [cache setObject:image forKey:key];
    return image;
}

#pragma mark Thumbnails

NSBitmapImageRep *DKIconBitmap(NSImage *image, CGFloat cornerRadius) {
    // Two pixels per point, for Retina screens.
    const NSInteger side = 2 * DKIconSize;
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:side pixelsHigh:side
                                                                    bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
                                                                   colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    bitmap.size = NSMakeSize(DKIconSize, DKIconSize);
    NSSize size = image.size;
    CGFloat scale = MIN(DKIconSize / MAX(size.width, 1), DKIconSize / MAX(size.height, 1));
    NSSize fitted = NSMakeSize(size.width * scale, size.height * scale);
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
    NSGraphicsContext.currentContext.imageInterpolation = NSImageInterpolationHigh;
    if (cornerRadius > 0)
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(0, 0, DKIconSize, DKIconSize) xRadius:cornerRadius
                                         yRadius:cornerRadius] addClip];
    [image drawInRect:NSMakeRect((DKIconSize - fitted.width) / 2, (DKIconSize - fitted.height) / 2, fitted.width, fitted.height)];
    [NSGraphicsContext restoreGraphicsState];
    return bitmap;
}

NSImage *DKIconThumbnail(NSImage *image) {
    NSImage *thumbnail = [[NSImage alloc] initWithSize:NSMakeSize(DKIconSize, DKIconSize)];
    [thumbnail addRepresentation:DKIconBitmap(image, 0)];
    return thumbnail;
}

#pragma mark Local icons

NSImage *DKFileIcon(NSString *path) {
    return Cached([@"file:" stringByAppendingString:path],
                  ^{ return DKIconThumbnail([NSWorkspace.sharedWorkspace iconForFile:path]); });
}

void DKWarmFileIcons(NSArray<NSString *> *paths) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        for (NSString *path in paths) DKFileIcon(path);
    });
}

NSImage *DKSymbolIcon(NSString *name) {
    return Cached([@"symbol:" stringByAppendingString:name], ^{
        return [[NSImage imageWithSystemSymbolName:name accessibilityDescription:nil]
            imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithHierarchicalColor:NSColor.whiteColor]];
    });
}

static NSURL *IconFile(NSString *name) { return [DKSupportSubdirectory(@"icons") URLByAppendingPathComponent:name]; }

static NSImage *MakeCommandIcon(NSString *file, NSString *symbol, NSColor *color) {
    NSImage *artwork = [[NSImage alloc] initWithContentsOfURL:IconFile(file)];
    if (artwork) return DKIconThumbnail(artwork);
    NSImageSymbolConfiguration *style = [[NSImageSymbolConfiguration configurationWithPointSize:12 weight:NSFontWeightSemibold]
        configurationByApplyingConfiguration:[NSImageSymbolConfiguration configurationWithHierarchicalColor:NSColor.whiteColor]];
    NSImage *glyph = [[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil] imageWithSymbolConfiguration:style];
    return [NSImage imageWithSize:NSMakeSize(DKIconSize, DKIconSize) flipped:NO drawingHandler:^BOOL(NSRect rect) {
        [color setFill];
        [[NSBezierPath bezierPathWithRoundedRect:rect xRadius:5 yRadius:5] fill];
        NSSize size = glyph.size;
        [glyph drawInRect:NSMakeRect((rect.size.width - size.width) / 2, (rect.size.height - size.height) / 2, size.width,
                                     size.height)];
        return YES;
    }];
}

NSImage *DKCommandIcon(DKCommand command) {
    // Indexed by DKCommand.
    NSArray<NSString *> *files = @[ @"quicklink.png", @"create-quicklink.png", @"clipboard.png", @"google.png" ];
    NSArray<NSString *> *symbols = @[ @"bolt.fill", @"plus", @"doc.on.clipboard", @"magnifyingglass" ];
    NSArray<NSColor *> *colors =
        @[ NSColor.systemPurpleColor, NSColor.systemPurpleColor, NSColor.systemRedColor, NSColor.systemBlueColor ];
    return Cached(files[command], ^{ return MakeCommandIcon(files[command], symbols[command], colors[command]); });
}

NSImage *DKLogo(void) {
    return Cached(@"logo", ^{
        NSImage *logo = [[NSImage alloc] initWithContentsOfURL:IconFile(@"logo.png")]
                            ?: [NSImage imageWithSystemSymbolName:@"magnifyingglass" accessibilityDescription:nil];
        logo.template = YES;
        return logo;
    });
}
