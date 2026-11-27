// Owns the picker's typeface, colours and date format.
#import <CoreText/CoreText.h>
#import <mach-o/getsect.h>
#import <mach-o/ldsyms.h>

#import "theme.h"

/// Inter is linked into the binary (the Makefile's __TEXT,__inter section), so there is no
/// font file to install and nothing is registered system-wide.
static CTFontDescriptorRef InterDescriptor(void) {
    static CTFontDescriptorRef descriptor;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        unsigned long size = 0;
        uint8_t *bytes = getsectiondata(&_mh_execute_header, "__TEXT", "__inter", &size);
        if (!bytes) return;
        NSData *data = [NSData dataWithBytesNoCopy:bytes length:size freeWhenDone:NO];
        CFArrayRef found = CTFontManagerCreateFontDescriptorsFromData((__bridge CFDataRef)data);
        if (found && CFArrayGetCount(found)) descriptor = CFRetain(CFArrayGetValueAtIndex(found, 0));
        if (found) CFRelease(found);
    });
    return descriptor;
}

NSFont *DKFont(CGFloat size, CGFloat weight) {
    static NSCache *cache;
    if (!cache) cache = [NSCache new];
    NSString *key = [NSString stringWithFormat:@"%g/%g", size, weight];
    NSFont *font = [cache objectForKey:key];
    if (font) return font;

    CTFontDescriptorRef base = InterDescriptor();
    if (!base) {
        NSFontWeight system = weight >= 600 ? NSFontWeightSemibold : weight >= 500 ? NSFontWeightMedium : NSFontWeightRegular;
        return [NSFont systemFontOfSize:size weight:system];
    }
    const uint32_t weightAxis = 'wght', opticalSizeAxis = 'opsz';
    NSDictionary *attributes = @{
        // Raycast turns optical sizing off, which leaves Inter at its text design (14) at
        // every size; CoreText would otherwise draw 18 and 24 points in the tighter display
        // design.
        (__bridge id)kCTFontVariationAttribute : @{@(weightAxis) : @(weight), @(opticalSizeAxis) : @14},
        // Raycast turns on Inter's stylistic set 3 (rounded quotes and commas).
        (__bridge id)kCTFontFeatureSettingsAttribute :
            @[ @{(__bridge id)kCTFontOpenTypeFeatureTag : @"ss03", (__bridge id)kCTFontOpenTypeFeatureValue : @1} ],
    };
    CTFontDescriptorRef styled = CTFontDescriptorCreateCopyWithAttributes(base, (__bridge CFDictionaryRef)attributes);
    font = (__bridge_transfer NSFont *)CTFontCreateWithFontDescriptor(styled, size, NULL);
    CFRelease(styled);
    [cache setObject:font forKey:key];
    return font;
}

CGFloat DKTracking(CGFloat size, CGFloat weight) {
    // Its text styles: +0.1 at 11 and 13 points, -0.1 at 18, -0.15 at 24, a hundredth more
    // either way per weight step above regular.
    CGFloat steps = (weight - 400) / 100;
    if (size <= 13) return 0.1 + 0.01 * steps;
    if (size >= 24) return -0.15 - 0.01 * steps;
    if (size >= 18) return -0.1 - 0.01 * steps;
    return 0.01 * steps;
}

NSColor *DKTextPrimary(void) { return NSColor.whiteColor; }
NSColor *DKTextSecondary(void) { return DKWhite(0.6); }
NSColor *DKTextTertiary(void) { return DKWhite(0.4); }
NSColor *DKWhite(CGFloat alpha) { return [NSColor colorWithWhite:1 alpha:alpha]; }

NSTextField *DKLabel(NSString *text, NSFont *font, NSColor *color) {
    NSTextField *label = [NSTextField labelWithString:text];
    label.font = font;
    label.textColor = color;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    return label;
}

NSString *DKFormatDate(NSDate *date) {
    static NSDateFormatter *formatter;
    if (!formatter) {
        formatter = [NSDateFormatter new];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_GB"];
        formatter.dateStyle = NSDateFormatterMediumStyle;
        formatter.timeStyle = NSDateFormatterMediumStyle;
        formatter.doesRelativeDateFormatting = YES;
    }
    return [formatter stringFromDate:date];
}
