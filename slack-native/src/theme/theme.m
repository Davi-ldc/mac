// Owns the bundled fonts, colour conversion, CSS line boxes, shadows and animation timing.
#import <CoreText/CoreText.h>
#import <os/lock.h>

#import "theme/theme.h"

#pragma mark Colours

static CGFloat Channel(SNColorToken token, int shift) { return ((token >> shift) & 0xFF) / 255.0; }

NSColor *SNColor(SNColorToken token) {
    return [NSColor colorWithSRGBRed:Channel(token, 24) green:Channel(token, 16) blue:Channel(token, 8) alpha:Channel(token, 0)];
}

CGColorRef SNCGColor(SNColorToken token) {
    static NSMutableDictionary<NSNumber *, id> *cache;
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    os_unfair_lock_lock(&lock);
    if (!cache) cache = [NSMutableDictionary new];
    id color = cache[@(token)];
    if (!color) {
        color = CFBridgingRelease(CGColorCreateSRGB(Channel(token, 24), Channel(token, 16), Channel(token, 8), Channel(token, 0)));
        cache[@(token)] = color;
    }
    os_unfair_lock_unlock(&lock);
    return (__bridge CGColorRef)color;
}

SNColorToken SNColorWithAlpha(SNColorToken token, CGFloat alpha) {
    return (token & 0xFFFFFF00) | (SNColorToken)lround(MAX(0, MIN(1, alpha)) * 255);
}

SNColorToken SNColorBrightness(SNColorToken token, CGFloat factor) {
    SNColorToken result = token & 0xFF;
    for (int shift = 8; shift <= 24; shift += 8)
        result |= (SNColorToken)MIN(255, lround(((token >> shift) & 0xFF) * factor)) << shift;
    return result;
}

SNColorToken SNColorOver(SNColorToken top, SNColorToken bottom) {
    CGFloat a = Channel(top, 0), b = Channel(bottom, 0), out = a + b * (1 - a);
    if (out == 0) return 0;
    SNColorToken result = (SNColorToken)lround(out * 255);
    for (int shift = 8; shift <= 24; shift += 8) {
        CGFloat value = (Channel(top, shift) * a + Channel(bottom, shift) * b * (1 - a)) / out;
        result |= (SNColorToken)lround(value * 255) << shift;
    }
    return result;
}

#pragma mark Fonts

/// The bundled files are read where they are rather than registered, so nothing is installed
/// for other processes and a missing file shows up as the system font, not a crash.
static CTFontDescriptorRef BundledDescriptor(NSString *file) {
    NSURL *url = [NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:[@"fonts" stringByAppendingPathComponent:file]];
    CFArrayRef found = CTFontManagerCreateFontDescriptorsFromURL((__bridge CFURLRef)url);
    CTFontDescriptorRef descriptor = found && CFArrayGetCount(found) ? CFRetain(CFArrayGetValueAtIndex(found, 0)) : NULL;
    if (found) CFRelease(found);
    return descriptor;
}

/// The face CSS font matching picks among the bundled weights: for 400 and 500 it tries 400-500
/// first, below 400 lighter faces first, above 500 heavier faces first.
static const SNFontFace *LatoFace(CGFloat weight, BOOL italic) {
    const SNFontFace *best = NULL;
    CGFloat bestScore = INFINITY;
    for (NSUInteger i = 0; i < SNLatoFaceCount; i++) {
        const SNFontFace *face = &SNLatoFaces[i];
        if (face->italic != italic) continue;
        CGFloat distance = fabs(face->weight - weight);
        BOOL preferred = weight < 400 ? face->weight <= weight : weight > 500 ? face->weight >= weight : face->weight >= weight && face->weight <= 500;
        CGFloat score = preferred ? distance : 10000 + distance;
        if (score < bestScore) bestScore = score, best = face;
    }
    return best;
}

static NSFont *CachedFont(NSString *key, NSFont * (^make)(void)) {
    static NSCache<NSString *, NSFont *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSCache new]; });
    NSFont *font = [cache objectForKey:key];
    if (!font) {
        font = make();
        [cache setObject:font forKey:key];
    }
    return font;
}

static NSFont *Lato(CGFloat size, CGFloat weight, BOOL italic) {
    const SNFontFace *face = LatoFace(weight, italic);
    return CachedFont([NSString stringWithFormat:@"%s/%g", face->name, size], ^NSFont * {
        static NSMutableDictionary<NSString *, id> *descriptors;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ descriptors = [NSMutableDictionary new]; });
        NSString *name = @(face->name);
        id descriptor;
        @synchronized(descriptors) {
            descriptor = descriptors[name];
            if (!descriptor) {
                descriptor = CFBridgingRelease(BundledDescriptor([name stringByAppendingPathExtension:@"ttf"])) ?: NSNull.null;
                descriptors[name] = descriptor;
            }
        }
        if (descriptor == NSNull.null) return [NSFont systemFontOfSize:size weight:weight >= 600 ? NSFontWeightBold : NSFontWeightRegular];
        return (__bridge_transfer NSFont *)CTFontCreateWithFontDescriptor((__bridge CTFontDescriptorRef)descriptor, size, NULL);
    });
}

NSFont *SNFont(CGFloat size, CGFloat weight) { return Lato(size, weight, NO); }
NSFont *SNItalicFont(CGFloat size, CGFloat weight) { return Lato(size, weight, YES); }

NSFont *SNMonoFont(CGFloat size, CGFloat weight) {
    weight = MAX(SNMonoWeightMin, MIN(SNMonoWeightMax, weight));
    return CachedFont([NSString stringWithFormat:@"mono/%g/%g", size, weight], ^NSFont * {
        static CTFontDescriptorRef base;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ base = BundledDescriptor(@"RobotoMono-VariableFont_wght.ttf"); });
        if (!base) return [NSFont monospacedSystemFontOfSize:size weight:NSFontWeightRegular];
        const uint32_t weightAxis = 'wght';
        NSDictionary *attributes = @{(__bridge id)kCTFontVariationAttribute : @{@(weightAxis) : @(weight)}};
        CTFontDescriptorRef styled = CTFontDescriptorCreateCopyWithAttributes(base, (__bridge CFDictionaryRef)attributes);
        NSFont *font = (__bridge_transfer NSFont *)CTFontCreateWithFontDescriptor(styled, size, NULL);
        CFRelease(styled);
        return font;
    });
}

CGFloat SNBaselineOffset(NSFont *font, CGFloat lineHeight) {
    CGFloat ascent = round(font.ascender), descent = round(-font.descender);
    return (lineHeight - ascent - descent) / 2 + ascent;
}

#pragma mark Shadows and motion

void SNApplyShadow(CALayer *layer, SNShadowStack stack) {
    const SNShadow *drop = NULL;
    CALayer *ring = nil;
    for (CALayer *sublayer in layer.sublayers)
        if ([sublayer.name isEqualToString:@"SNRing"]) ring = sublayer;
    for (NSUInteger i = 0; i < stack.count; i++) {
        const SNShadow *shadow = &stack.shadows[i];
        if (shadow->inset) continue;
        if (shadow->blur == 0 && shadow->x == 0 && shadow->y == 0 && shadow->spread > 0) {
            if (!ring) {
                ring = [CALayer layer];
                ring.name = @"SNRing";
                [layer addSublayer:ring];
            }
            ring.frame = CGRectInset(layer.bounds, -shadow->spread, -shadow->spread);
            ring.cornerRadius = layer.cornerRadius + shadow->spread;
            ring.borderWidth = shadow->spread;
            ring.borderColor = SNCGColor(shadow->color);
        } else if (!drop || shadow->blur > drop->blur) {
            drop = shadow;
        }
    }
    if (!drop) {
        layer.shadowOpacity = 0;
        return;
    }
    layer.shadowColor = SNCGColor(drop->color | 0xFF);
    layer.shadowOpacity = (float)Channel(drop->color, 0);
    // CSS blur is twice the Gaussian's standard deviation; Core Animation's radius is the blur.
    layer.shadowRadius = drop->blur / 2;
    // Layers of views are flipped or not depending on the view; CSS offsets point down.
    layer.shadowOffset = CGSizeMake(drop->x, layer.geometryFlipped || layer.superlayer.geometryFlipped ? drop->y : -drop->y);
    CGRect box = CGRectInset(layer.bounds, -drop->spread, -drop->spread);
    CGFloat radius = MAX(0, layer.cornerRadius + drop->spread);
    layer.shadowPath = CFAutorelease(CGPathCreateWithRoundedRect(box, MIN(radius, box.size.width / 2), MIN(radius, box.size.height / 2), NULL));
}

static CFTimeInterval animationDuration;
static CAMediaTimingFunction *animationTiming;

void SNAnimate(CFTimeInterval duration, CAMediaTimingFunction *timing, void (^changes)(void)) {
    CFTimeInterval outerDuration = animationDuration;
    CAMediaTimingFunction *outerTiming = animationTiming;
    animationDuration = MAX(0, duration);
    animationTiming = timing;
    [NSAnimationContext beginGrouping];
    NSAnimationContext *context = NSAnimationContext.currentContext;
    context.duration = duration;
    context.timingFunction = timing;
    context.allowsImplicitAnimation = duration > 0;
    changes();
    [NSAnimationContext endGrouping];
    animationDuration = outerDuration;
    animationTiming = outerTiming;
}

@implementation SNLayer

- (id<CAAction>)actionForKey:(NSString *)event {
    if (animationDuration <= 0 || [event hasPrefix:@"on"] || [event isEqualToString:kCATransition]) return (id)NSNull.null;
    CABasicAnimation *animation = [CABasicAnimation animationWithKeyPath:event];
    // Called before the property changes: an interrupted animation continues from where it is.
    animation.fromValue = [(self.presentationLayer ?: self) valueForKey:event];
    animation.duration = animationDuration;
    animation.timingFunction = animationTiming;
    return animation;
}

@end
