// Zero-CoreSVG pure CoreGraphics vector SF-Symbol-accurate icons, semantic Light/Dark colors,
// Liquid Glass container helper, typography, and artwork rendering.
#import "render/icons.h"

#import <QuartzCore/QuartzCore.h>
#import <math.h>

#pragma mark - Semantic macOS Colors

NSColor *SPAccentColor(void) {
    static NSColor *c = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        c = [NSColor colorWithSRGBRed:0x1D / 255.0 green:0xB9 / 255.0 blue:0x54 / 255.0 alpha:1.0];
    });
    return c;
}

NSColor *SPAccentHoverColor(void) {
    static NSColor *c = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        c = [NSColor colorWithSRGBRed:0x1E / 255.0 green:0xD7 / 255.0 blue:0x60 / 255.0 alpha:1.0];
    });
    return c;
}

NSColor *SPAccentPressedColor(void) {
    static NSColor *c = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        c = [NSColor colorWithSRGBRed:0x16 / 255.0 green:0x9C / 255.0 blue:0x46 / 255.0 alpha:1.0];
    });
    return c;
}

NSColor *SPWindowBackgroundColor(void) { return NSColor.windowBackgroundColor; }
NSColor *SPControlBackgroundColor(void) { return NSColor.controlBackgroundColor; }
NSColor *SPUnderPageBackgroundColor(void) { return NSColor.underPageBackgroundColor; }
NSColor *SPLabelColor(void) { return NSColor.labelColor; }
NSColor *SPSecondaryLabelColor(void) { return NSColor.secondaryLabelColor; }
NSColor *SPTertiaryLabelColor(void) { return NSColor.tertiaryLabelColor; }
NSColor *SPSeparatorColor(void) { return NSColor.separatorColor; }

NSColor *SPQuaternaryFillColor(void) {
    return NSColor.quaternaryLabelColor;
}

NSColor *SPHoverFillColor(void) {
    return [NSColor colorWithName:@"SPHoverFill" dynamicProvider:^NSColor *(NSAppearance *appearance) {
        return SPIsDarkAppearance(appearance)
            ? [NSColor colorWithWhite:1.0 alpha:0.06]
            : [NSColor colorWithWhite:0.0 alpha:0.05];
    }];
}

NSColor *SPSelectedRowFillColor(void) {
    return [SPAccentColor() colorWithAlphaComponent:0.20];
}

NSColor *SPHeartRedColor(void) {
    return NSColor.systemRedColor;
}

NSColor *SPCardSurfaceColor(void) {
    return [NSColor colorWithName:@"SPCardSurface" dynamicProvider:^NSColor *(NSAppearance *appearance) {
        return SPIsDarkAppearance(appearance)
            ? [NSColor colorWithWhite:1.0 alpha:0.05]
            : [NSColor colorWithWhite:1.0 alpha:0.85];
    }];
}

BOOL SPIsDarkAppearance(NSAppearance *appearance) {
    NSAppearance *app = appearance ?: NSAppearance.currentDrawingAppearance ?: NSApp.effectiveAppearance;
    NSAppearanceName match = [app bestMatchFromAppearancesWithNames:@[
        NSAppearanceNameDarkAqua,
        NSAppearanceNameAqua,
    ]];
    return [match isEqualToString:NSAppearanceNameDarkAqua];
}

NSColor *SPNSColor(SPColorToken token) {
    return [NSColor colorWithSRGBRed:token.r green:token.g blue:token.b alpha:token.a];
}

NSFont *SPNSFont(SPTextStyle style) {
    if (style.monospacedDigits) {
        return [NSFont monospacedDigitSystemFontOfSize:style.size weight:style.weight];
    }
    return [NSFont systemFontOfSize:style.size weight:style.weight];
}

static NSParagraphStyle *SPCachedParagraphStyle(NSLineBreakMode lineBreak, NSTextAlignment alignment) {
    static NSMutableDictionary<NSNumber *, NSParagraphStyle *> *cache = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary new]; });
    NSNumber *key = @(((NSInteger)lineBreak << 4) | (NSInteger)alignment);
    NSParagraphStyle *style = cache[key];
    if (!style) {
        NSMutableParagraphStyle *p = [NSMutableParagraphStyle new];
        p.lineBreakMode = lineBreak;
        p.alignment = alignment;
        style = [p copy];
        cache[key] = style;
    }
    return style;
}

NSDictionary<NSAttributedStringKey, id> *SPSemanticTextAttributes(SPTextStyle style,
                                                                  NSColor *color,
                                                                  NSLineBreakMode lineBreak,
                                                                  NSTextAlignment alignment) {
    NSFont *font = SPNSFont(style);
    NSParagraphStyle *para = SPCachedParagraphStyle(lineBreak, alignment);
    if (fabs(style.tracking) > 0.001) {
        return @{
            NSFontAttributeName: font,
            NSForegroundColorAttributeName: color ?: NSColor.labelColor,
            NSParagraphStyleAttributeName: para,
            NSKernAttributeName: @(style.tracking),
        };
    }
    return @{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: color ?: NSColor.labelColor,
        NSParagraphStyleAttributeName: para,
    };
}

NSDictionary<NSAttributedStringKey, id> *SPTextAttributes(SPTextStyle style,
                                                          SPColorToken color,
                                                          NSLineBreakMode lineBreak,
                                                          NSTextAlignment alignment) {
    return SPSemanticTextAttributes(style, SPNSColor(color), lineBreak, alignment);
}

#pragma mark - SF Symbol Name Mapping

NSString *SPSFSymbolNameForIcon(SPIconName icon) {
    switch (icon) {
        case SPIconHome: return @"house.fill";
        case SPIconSearch: return @"magnifyingglass";
        case SPIconHeart: return @"heart";
        case SPIconHeartFilled: return @"heart.fill";
        case SPIconAlbum: return @"opticaldisc";
        case SPIconArtist: return @"mic.fill";
        case SPIconPlaylist: return @"music.note.list";
        case SPIconBack: return @"chevron.left";
        case SPIconForward: return @"chevron.right";
        case SPIconClose: return @"xmark";
        case SPIconPlay: return @"play.fill";
        case SPIconPause: return @"pause.fill";
        case SPIconNext: return @"forward.fill";
        case SPIconPrevious: return @"backward.fill";
        case SPIconShuffle: return @"shuffle";
        case SPIconRepeat: return @"repeat";
        case SPIconRepeatOne: return @"repeat.1";
        case SPIconSpeaker: return @"speaker.wave.3.fill";
        case SPIconSpeakerMed: return @"speaker.wave.2.fill";
        case SPIconSpeakerLow: return @"speaker.wave.1.fill";
        case SPIconSpeakerMute: return @"speaker.fill";
        case SPIconDevices: return @"hifispeaker.2.fill";
        case SPIconDevicesOutline: return @"hifispeaker.2";
        case SPIconQueue: return @"text.line.first.and.arrowtriangle.forward";
        case SPIconSettings: return @"gearshape";
        case SPIconPlus: return @"plus";
        case SPIconMore: return @"ellipsis";
        case SPIconCheck: return @"checkmark";
        case SPIconMusicNote: return @"music.note";
        case SPIconRefresh: return @"arrow.clockwise";
        case SPIconScrollToCurrent: return @"arrow.down.to.line";
        case SPIconInspector: return @"sidebar.right";
        case SPIconSidebarLeft: return @"sidebar.left";
        case SPIconShare: return @"square.and.arrow.up";
        case SPIconProfile: return @"person.circle.fill";
        case SPIconPersonFill: return @"person.fill";
        case SPIconSquareStack: return @"square.stack";
        case SPIconLaptop: return @"laptopcomputer";
        case SPIconPhone: return @"iphone";
        case SPIconTablet: return @"ipad";
        case SPIconTV: return @"tv";
        case SPIconCopy: return @"doc.on.doc";
        case SPIconArrowUpRight: return @"arrow.up.right";
        case SPIconCommand: return @"command";
        case SPIconTrash: return @"trash";
        case SPIconPencil: return @"pencil";
        case SPIconLink: return @"link";
        case SPIconRadio: return @"dot.radiowaves.left.and.right";
        case SPIconExclamation: return @"exclamationmark.triangle";
    }
    return @"music.note";
}

#pragma mark - Pure CoreGraphics Vector SF-Symbol Renderer (Zero CoreSVG Overhead)

static void SPStrokeRoundedRect(CGContextRef ctx, CGRect r, CGFloat rad) {
    CGPathRef p = CGPathCreateWithRoundedRect(r, rad, rad, NULL);
    CGContextAddPath(ctx, p);
    CGContextStrokePath(ctx);
    CGPathRelease(p);
}

static void SPFillRoundedRect(CGContextRef ctx, CGRect r, CGFloat rad) {
    CGPathRef p = CGPathCreateWithRoundedRect(r, rad, rad, NULL);
    CGContextAddPath(ctx, p);
    CGContextFillPath(ctx);
    CGPathRelease(p);
}

static void SPDrawVectorSymbolInContext(CGContextRef ctx,
                                        NSString *sym,
                                        CGRect rect,
                                        CGFloat pointSize,
                                        NSFontWeight weight,
                                        NSColor *color) {
    if (!ctx || !sym.length || CGRectIsEmpty(rect)) return;
    CGFloat box = MIN(rect.size.width, rect.size.height);
    if (box <= 0.5) return;
    CGFloat s = (pointSize > 1.0) ? MIN(box, pointSize * 1.12) : box;

    CGContextSaveGState(ctx);
    CGFloat ox = CGRectGetMidX(rect) - s * 0.5;
    CGFloat oy = CGRectGetMidY(rect) - s * 0.5;
    CGContextTranslateCTM(ctx, ox, oy);
    CGContextScaleCTM(ctx, s / 24.0, s / 24.0);

    NSColor *fg = color ?: NSColor.labelColor;
    CGColorRef cg = fg.CGColor;
    CGContextSetStrokeColorWithColor(ctx, cg);
    CGContextSetFillColorWithColor(ctx, cg);
    CGFloat lw = (weight >= NSFontWeightSemibold) ? 2.15 : ((weight >= NSFontWeightMedium) ? 1.95 : 1.80);
    CGContextSetLineWidth(ctx, lw);
    CGContextSetLineCap(ctx, kCGLineCapRound);
    CGContextSetLineJoin(ctx, kCGLineJoinRound);

    if ([sym isEqualToString:@"house.fill"]) {
        // Filled SF Symbol house with crisp roof overhang and clean door cutout
        CGContextMoveToPoint(ctx, 12.0, 3.0);
        CGContextAddLineToPoint(ctx, 21.5, 11.2);
        CGContextAddLineToPoint(ctx, 19.0, 11.2);
        CGContextAddLineToPoint(ctx, 19.0, 20.0);
        CGContextAddQuadCurveToPoint(ctx, 19.0, 21.0, 18.0, 21.0);
        CGContextAddLineToPoint(ctx, 14.2, 21.0);
        CGContextAddLineToPoint(ctx, 14.2, 15.0);
        CGContextAddQuadCurveToPoint(ctx, 14.2, 14.0, 13.2, 14.0);
        CGContextAddLineToPoint(ctx, 10.8, 14.0);
        CGContextAddQuadCurveToPoint(ctx, 9.8, 14.0, 9.8, 15.0);
        CGContextAddLineToPoint(ctx, 9.8, 21.0);
        CGContextAddLineToPoint(ctx, 6.0, 21.0);
        CGContextAddQuadCurveToPoint(ctx, 5.0, 21.0, 5.0, 20.0);
        CGContextAddLineToPoint(ctx, 5.0, 11.2);
        CGContextAddLineToPoint(ctx, 2.5, 11.2);
        CGContextClosePath(ctx);
        CGContextFillPath(ctx);
    } else if ([sym isEqualToString:@"magnifyingglass"]) {
        CGContextAddEllipseInRect(ctx, CGRectMake(3.5, 3.5, 13.0, 13.0));
        CGContextMoveToPoint(ctx, 14.8, 14.8);
        CGContextAddLineToPoint(ctx, 20.5, 20.5);
        CGContextStrokePath(ctx);
    } else if ([sym isEqualToString:@"text.line.first.and.arrowtriangle.forward"]) {
        // Queue SF Symbol: small play triangle top-left + 3 horizontal lines
        CGContextMoveToPoint(ctx, 3.2, 4.2);
        CGContextAddLineToPoint(ctx, 8.2, 7.0);
        CGContextAddLineToPoint(ctx, 3.2, 9.8);
        CGContextClosePath(ctx);
        CGContextFillPath(ctx);
        CGContextMoveToPoint(ctx, 11.0, 7.0);
        CGContextAddLineToPoint(ctx, 20.8, 7.0);
        CGContextMoveToPoint(ctx, 3.5, 13.0);
        CGContextAddLineToPoint(ctx, 20.8, 13.0);
        CGContextMoveToPoint(ctx, 3.5, 18.5);
        CGContextAddLineToPoint(ctx, 20.8, 18.5);
        CGContextStrokePath(ctx);
    } else if ([sym isEqualToString:@"hifispeaker.2.fill"] || [sym isEqualToString:@"hifispeaker.2"]) {
        BOOL filled = [sym isEqualToString:@"hifispeaker.2.fill"];
        // Back speaker (right-rear)
        CGContextSetLineWidth(ctx, 1.5);
        SPStrokeRoundedRect(ctx, CGRectMake(12.2, 2.8, 8.4, 14.8), 1.8);
        // Front speaker (left-front)
        if (filled) {
            SPFillRoundedRect(ctx, CGRectMake(3.4, 5.2, 9.4, 16.0), 2.0);
            CGContextSetBlendMode(ctx, kCGBlendModeClear);
            CGContextFillEllipseInRect(ctx, CGRectMake(6.8, 7.5, 2.6, 2.6));
            CGContextFillEllipseInRect(ctx, CGRectMake(5.6, 13.0, 5.0, 5.0));
            CGContextSetBlendMode(ctx, kCGBlendModeNormal);
            CGContextFillEllipseInRect(ctx, CGRectMake(7.2, 14.6, 1.8, 1.8));
        } else {
            SPStrokeRoundedRect(ctx, CGRectMake(3.4, 5.2, 9.4, 16.0), 2.0);
            CGContextFillEllipseInRect(ctx, CGRectMake(7.0, 7.8, 2.2, 2.2));
            CGContextAddEllipseInRect(ctx, CGRectMake(5.8, 13.2, 4.6, 4.6));
            CGContextStrokePath(ctx);
        }
    } else if ([sym isEqualToString:@"hifispeaker.fill"] || [sym isEqualToString:@"hifispeaker.slash"]) {
        SPStrokeRoundedRect(ctx, CGRectMake(6.2, 2.8, 11.6, 18.4), 2.2);
        CGContextFillEllipseInRect(ctx, CGRectMake(10.6, 5.8, 2.8, 2.8));
        CGContextAddEllipseInRect(ctx, CGRectMake(8.8, 11.8, 6.4, 6.4));
        CGContextStrokePath(ctx);
        if ([sym isEqualToString:@"hifispeaker.slash"]) {
            CGContextMoveToPoint(ctx, 3.5, 3.5);
            CGContextAddLineToPoint(ctx, 20.5, 20.5);
            CGContextStrokePath(ctx);
        }
    } else if ([sym isEqualToString:@"heart.fill"] || [sym isEqualToString:@"heart"] || [sym isEqualToString:@"heart.slash"]) {
        CGContextMoveToPoint(ctx, 12.0, 20.4);
        CGContextAddCurveToPoint(ctx, 4.2, 15.0, 2.8, 10.0, 5.0, 6.6);
        CGContextAddCurveToPoint(ctx, 6.8, 3.9, 10.4, 4.4, 12.0, 7.0);
        CGContextAddCurveToPoint(ctx, 13.6, 4.4, 17.2, 3.9, 19.0, 6.6);
        CGContextAddCurveToPoint(ctx, 21.2, 10.0, 19.8, 15.0, 12.0, 20.4);
        CGContextClosePath(ctx);
        if ([sym isEqualToString:@"heart.fill"]) {
            CGContextFillPath(ctx);
        } else {
            CGContextStrokePath(ctx);
            if ([sym isEqualToString:@"heart.slash"]) {
                CGContextMoveToPoint(ctx, 3.5, 3.5);
                CGContextAddLineToPoint(ctx, 20.5, 20.5);
                CGContextStrokePath(ctx);
            }
        }
    } else if ([sym isEqualToString:@"music.note.list"]) {
        // 3 horizontal playlist lines on left + beamed eighth note on right
        CGContextMoveToPoint(ctx, 3.0, 6.5);
        CGContextAddLineToPoint(ctx, 13.0, 6.5);
        CGContextMoveToPoint(ctx, 3.0, 11.5);
        CGContextAddLineToPoint(ctx, 11.5, 11.5);
        CGContextMoveToPoint(ctx, 3.0, 16.5);
        CGContextAddLineToPoint(ctx, 10.0, 16.5);
        CGContextMoveToPoint(ctx, 16.0, 16.5);
        CGContextAddLineToPoint(ctx, 16.0, 6.5);
        CGContextAddLineToPoint(ctx, 21.0, 5.2);
        CGContextAddLineToPoint(ctx, 21.0, 9.0);
        CGContextStrokePath(ctx);
        CGContextFillEllipseInRect(ctx, CGRectMake(12.2, 14.8, 4.8, 3.8));
    } else if ([sym isEqualToString:@"opticaldisc"]) {
        CGContextAddEllipseInRect(ctx, CGRectMake(3.0, 3.0, 18.0, 18.0));
        CGContextAddEllipseInRect(ctx, CGRectMake(9.2, 9.2, 5.6, 5.6));
        CGContextStrokePath(ctx);
        CGContextFillEllipseInRect(ctx, CGRectMake(11.0, 11.0, 2.0, 2.0));
    } else if ([sym isEqualToString:@"mic.fill"]) {
        SPFillRoundedRect(ctx, CGRectMake(8.6, 3.0, 6.8, 10.8), 3.4);
        CGContextAddArc(ctx, 12.0, 10.6, 6.0, 0.0, M_PI, 0);
        CGContextMoveToPoint(ctx, 12.0, 16.6);
        CGContextAddLineToPoint(ctx, 12.0, 20.8);
        CGContextMoveToPoint(ctx, 8.2, 20.8);
        CGContextAddLineToPoint(ctx, 15.8, 20.8);
        CGContextStrokePath(ctx);
    } else if ([sym isEqualToString:@"chevron.left"]) {
        CGContextMoveToPoint(ctx, 15.0, 5.0);
        CGContextAddLineToPoint(ctx, 8.2, 12.0);
        CGContextAddLineToPoint(ctx, 15.0, 19.0);
        CGContextStrokePath(ctx);
    } else if ([sym isEqualToString:@"chevron.right"]) {
        CGContextMoveToPoint(ctx, 9.0, 5.0);
        CGContextAddLineToPoint(ctx, 15.8, 12.0);
        CGContextAddLineToPoint(ctx, 9.0, 19.0);
        CGContextStrokePath(ctx);
    } else if ([sym isEqualToString:@"xmark"]) {
        CGContextMoveToPoint(ctx, 6.0, 6.0);
        CGContextAddLineToPoint(ctx, 18.0, 18.0);
        CGContextMoveToPoint(ctx, 18.0, 6.0);
        CGContextAddLineToPoint(ctx, 6.0, 18.0);
        CGContextStrokePath(ctx);
    } else if ([sym isEqualToString:@"play.fill"]) {
        CGContextMoveToPoint(ctx, 6.5, 4.4);
        CGContextAddLineToPoint(ctx, 19.6, 12.0);
        CGContextAddLineToPoint(ctx, 6.5, 19.6);
        CGContextClosePath(ctx);
        CGContextFillPath(ctx);
    } else if ([sym isEqualToString:@"pause.fill"]) {
        SPFillRoundedRect(ctx, CGRectMake(5.8, 4.5, 4.4, 15.0), 1.3);
        SPFillRoundedRect(ctx, CGRectMake(13.8, 4.5, 4.4, 15.0), 1.3);
    } else if ([sym isEqualToString:@"forward.fill"]) {
        CGContextMoveToPoint(ctx, 3.0, 5.8);
        CGContextAddLineToPoint(ctx, 12.2, 12.0);
        CGContextAddLineToPoint(ctx, 3.0, 18.2);
        CGContextClosePath(ctx);
        CGContextMoveToPoint(ctx, 12.2, 5.8);
        CGContextAddLineToPoint(ctx, 21.4, 12.0);
        CGContextAddLineToPoint(ctx, 12.2, 18.2);
        CGContextClosePath(ctx);
        CGContextFillPath(ctx);
    } else if ([sym isEqualToString:@"backward.fill"]) {
        CGContextMoveToPoint(ctx, 21.0, 5.8);
        CGContextAddLineToPoint(ctx, 11.8, 12.0);
        CGContextAddLineToPoint(ctx, 21.0, 18.2);
        CGContextClosePath(ctx);
        CGContextMoveToPoint(ctx, 11.8, 5.8);
        CGContextAddLineToPoint(ctx, 2.6, 12.0);
        CGContextAddLineToPoint(ctx, 11.8, 18.2);
        CGContextClosePath(ctx);
        CGContextFillPath(ctx);
    } else if ([sym isEqualToString:@"shuffle"]) {
        CGContextMoveToPoint(ctx, 3.0, 7.2);
        CGContextAddCurveToPoint(ctx, 9.5, 7.2, 11.5, 16.8, 18.5, 16.8);
        CGContextMoveToPoint(ctx, 3.0, 16.8);
        CGContextAddCurveToPoint(ctx, 9.5, 16.8, 11.5, 7.2, 18.5, 7.2);
        CGContextMoveToPoint(ctx, 16.5, 4.6);
        CGContextAddLineToPoint(ctx, 20.5, 7.2);
        CGContextAddLineToPoint(ctx, 16.5, 9.8);
        CGContextMoveToPoint(ctx, 16.5, 14.2);
        CGContextAddLineToPoint(ctx, 20.5, 16.8);
        CGContextAddLineToPoint(ctx, 16.5, 19.4);
        CGContextStrokePath(ctx);
    } else if ([sym isEqualToString:@"repeat"] || [sym isEqualToString:@"repeat.1"]) {
        CGContextMoveToPoint(ctx, 4.0, 10.5);
        CGContextAddLineToPoint(ctx, 4.0, 8.2);
        CGContextAddQuadCurveToPoint(ctx, 4.0, 6.5, 6.2, 6.5);
        CGContextAddLineToPoint(ctx, 19.2, 6.5);
        CGContextMoveToPoint(ctx, 16.6, 4.0);
        CGContextAddLineToPoint(ctx, 19.8, 6.5);
        CGContextAddLineToPoint(ctx, 16.6, 9.0);

        CGContextMoveToPoint(ctx, 20.0, 13.5);
        CGContextAddLineToPoint(ctx, 20.0, 15.8);
        CGContextAddQuadCurveToPoint(ctx, 20.0, 17.5, 17.8, 17.5);
        CGContextAddLineToPoint(ctx, 4.8, 17.5);
        CGContextMoveToPoint(ctx, 7.4, 15.0);
        CGContextAddLineToPoint(ctx, 4.2, 17.5);
        CGContextAddLineToPoint(ctx, 7.4, 20.0);
        CGContextStrokePath(ctx);
        if ([sym isEqualToString:@"repeat.1"]) {
            CGContextSetLineWidth(ctx, 1.8);
            CGContextMoveToPoint(ctx, 12.2, 9.5);
            CGContextAddLineToPoint(ctx, 12.2, 14.8);
            CGContextMoveToPoint(ctx, 10.8, 10.7);
            CGContextAddLineToPoint(ctx, 12.2, 9.5);
            CGContextStrokePath(ctx);
        }
    } else if ([sym isEqualToString:@"speaker.fill"] ||
               [sym isEqualToString:@"speaker.wave.1.fill"] ||
               [sym isEqualToString:@"speaker.wave.2.fill"] ||
               [sym isEqualToString:@"speaker.wave.3.fill"]) {
        // Filled speaker horn
        CGContextMoveToPoint(ctx, 3.0, 9.2);
        CGContextAddLineToPoint(ctx, 6.8, 9.2);
        CGContextAddLineToPoint(ctx, 11.4, 5.2);
        CGContextAddLineToPoint(ctx, 11.4, 18.8);
        CGContextAddLineToPoint(ctx, 6.8, 14.8);
        CGContextAddLineToPoint(ctx, 3.0, 14.8);
        CGContextClosePath(ctx);
        CGContextFillPath(ctx);

        int waves = 0;
        if ([sym isEqualToString:@"speaker.wave.1.fill"]) waves = 1;
        else if ([sym isEqualToString:@"speaker.wave.2.fill"]) waves = 2;
        else if ([sym isEqualToString:@"speaker.wave.3.fill"]) waves = 3;
        CGContextSetLineWidth(ctx, 1.7);
        if (waves >= 1) {
            CGContextAddArc(ctx, 12.2, 12.0, 3.2, -0.72, 0.72, 0);
            CGContextStrokePath(ctx);
        }
        if (waves >= 2) {
            CGContextAddArc(ctx, 12.2, 12.0, 6.2, -0.78, 0.78, 0);
            CGContextStrokePath(ctx);
        }
        if (waves >= 3) {
            CGContextAddArc(ctx, 12.2, 12.0, 9.0, -0.82, 0.82, 0);
            CGContextStrokePath(ctx);
        }
    } else if ([sym isEqualToString:@"gearshape"]) {
        CGContextSetLineWidth(ctx, 1.8);
        CGContextAddEllipseInRect(ctx, CGRectMake(8.6, 8.6, 6.8, 6.8));
        CGContextStrokePath(ctx);
        for (int i = 0; i < 8; i++) {
            double a = (double)i * M_PI_4;
            CGContextMoveToPoint(ctx, 12.0 + cos(a) * 6.5, 12.0 + sin(a) * 6.5);
            CGContextAddLineToPoint(ctx, 12.0 + cos(a) * 9.5, 12.0 + sin(a) * 9.5);
        }
        CGContextStrokePath(ctx);
    } else if ([sym isEqualToString:@"plus"]) {
        CGContextMoveToPoint(ctx, 12.0, 4.8);
        CGContextAddLineToPoint(ctx, 12.0, 19.2);
        CGContextMoveToPoint(ctx, 4.8, 12.0);
        CGContextAddLineToPoint(ctx, 19.2, 12.0);
        CGContextStrokePath(ctx);
    } else if ([sym isEqualToString:@"ellipsis"]) {
        CGContextFillEllipseInRect(ctx, CGRectMake(4.0, 10.4, 3.2, 3.2));
        CGContextFillEllipseInRect(ctx, CGRectMake(10.4, 10.4, 3.2, 3.2));
        CGContextFillEllipseInRect(ctx, CGRectMake(16.8, 10.4, 3.2, 3.2));
    } else if ([sym isEqualToString:@"checkmark"]) {
        CGContextMoveToPoint(ctx, 4.8, 12.6);
        CGContextAddLineToPoint(ctx, 9.8, 17.6);
        CGContextAddLineToPoint(ctx, 19.4, 6.8);
        CGContextStrokePath(ctx);
    } else if ([sym isEqualToString:@"arrow.clockwise"]) {
        CGContextAddArc(ctx, 12.0, 12.4, 7.2, -M_PI * 0.42, M_PI * 1.15, 0);
        CGContextStrokePath(ctx);
        // Arrowhead at top-right of circle
        CGContextMoveToPoint(ctx, 12.5, 2.4);
        CGContextAddLineToPoint(ctx, 16.0, 5.6);
        CGContextAddLineToPoint(ctx, 11.8, 7.6);
        CGContextStrokePath(ctx);
    } else if ([sym isEqualToString:@"arrow.down.to.line"]) {
        CGContextMoveToPoint(ctx, 12.0, 4.0);
        CGContextAddLineToPoint(ctx, 12.0, 15.8);
        CGContextMoveToPoint(ctx, 7.5, 11.6);
        CGContextAddLineToPoint(ctx, 12.0, 16.2);
        CGContextAddLineToPoint(ctx, 16.5, 11.6);
        CGContextMoveToPoint(ctx, 5.0, 19.8);
        CGContextAddLineToPoint(ctx, 19.0, 19.8);
        CGContextStrokePath(ctx);
    } else if ([sym isEqualToString:@"sidebar.right"] || [sym isEqualToString:@"sidebar.left"]) {
        CGContextSetLineWidth(ctx, 1.65);
        SPStrokeRoundedRect(ctx, CGRectMake(2.8, 4.4, 18.4, 15.2), 2.8);
        BOOL right = [sym isEqualToString:@"sidebar.right"];
        CGFloat divX = right ? 15.2 : 8.8;
        CGContextMoveToPoint(ctx, divX, 4.6);
        CGContextAddLineToPoint(ctx, divX, 19.4);
        CGFloat lx0 = right ? 17.0 : 4.8;
        CGFloat lx1 = right ? 19.2 : 7.0;
        CGContextMoveToPoint(ctx, lx0, 8.2);
        CGContextAddLineToPoint(ctx, lx1, 8.2);
        CGContextMoveToPoint(ctx, lx0, 11.4);
        CGContextAddLineToPoint(ctx, lx1, 11.4);
        CGContextStrokePath(ctx);
    } else if ([sym isEqualToString:@"person.fill"] || [sym isEqualToString:@"person.circle.fill"]) {
        if ([sym isEqualToString:@"person.circle.fill"]) {
            CGContextAddEllipseInRect(ctx, CGRectMake(2.5, 2.5, 19.0, 19.0));
            CGContextStrokePath(ctx);
        }
        CGContextFillEllipseInRect(ctx, CGRectMake(8.2, 5.0, 7.6, 7.6));
        CGContextMoveToPoint(ctx, 5.0, 19.5);
        CGContextAddQuadCurveToPoint(ctx, 12.0, 13.0, 19.0, 19.5);
        CGContextClosePath(ctx);
        CGContextFillPath(ctx);
    } else if ([sym isEqualToString:@"square.stack"]) {
        CGContextSetLineWidth(ctx, 1.65);
        SPStrokeRoundedRect(ctx, CGRectMake(6.2, 6.2, 13.6, 13.6), 2.4);
        CGContextMoveToPoint(ctx, 4.2, 15.5);
        CGContextAddLineToPoint(ctx, 4.2, 5.6);
        CGContextAddQuadCurveToPoint(ctx, 4.2, 4.2, 5.6, 4.2);
        CGContextAddLineToPoint(ctx, 15.5, 4.2);
        CGContextStrokePath(ctx);
    } else if ([sym isEqualToString:@"laptopcomputer"]) {
        CGContextSetLineWidth(ctx, 1.6);
        SPStrokeRoundedRect(ctx, CGRectMake(4.5, 5.0, 15.0, 10.5), 1.6);
        CGContextMoveToPoint(ctx, 2.2, 18.0);
        CGContextAddLineToPoint(ctx, 21.8, 18.0);
        CGContextStrokePath(ctx);
    } else if ([sym isEqualToString:@"iphone"]) {
        CGContextSetLineWidth(ctx, 1.6);
        SPStrokeRoundedRect(ctx, CGRectMake(7.0, 3.0, 10.0, 18.0), 2.2);
        CGContextMoveToPoint(ctx, 10.5, 18.5);
        CGContextAddLineToPoint(ctx, 13.5, 18.5);
        CGContextStrokePath(ctx);
    } else if ([sym isEqualToString:@"ipad"]) {
        CGContextSetLineWidth(ctx, 1.6);
        SPStrokeRoundedRect(ctx, CGRectMake(5.0, 3.2, 14.0, 17.6), 2.0);
        CGContextMoveToPoint(ctx, 10.2, 18.4);
        CGContextAddLineToPoint(ctx, 13.8, 18.4);
        CGContextStrokePath(ctx);
    } else if ([sym isEqualToString:@"tv"]) {
        CGContextSetLineWidth(ctx, 1.6);
        SPStrokeRoundedRect(ctx, CGRectMake(3.0, 4.8, 18.0, 12.2), 2.0);
        CGContextMoveToPoint(ctx, 8.2, 19.6);
        CGContextAddLineToPoint(ctx, 15.8, 19.6);
        CGContextStrokePath(ctx);
    } else if ([sym isEqualToString:@"command"]) {
        CGContextSetLineWidth(ctx, 1.7);
        CGContextAddEllipseInRect(ctx, CGRectMake(4.2, 4.2, 4.8, 4.8));
        CGContextAddEllipseInRect(ctx, CGRectMake(15.0, 4.2, 4.8, 4.8));
        CGContextAddEllipseInRect(ctx, CGRectMake(4.2, 15.0, 4.8, 4.8));
        CGContextAddEllipseInRect(ctx, CGRectMake(15.0, 15.0, 4.8, 4.8));
        CGContextStrokeRect(ctx, CGRectMake(9.0, 9.0, 6.0, 6.0));
        CGContextStrokePath(ctx);
    } else if ([sym isEqualToString:@"trash"]) {
        CGContextSetLineWidth(ctx, 1.65);
        CGContextMoveToPoint(ctx, 4.5, 6.5);
        CGContextAddLineToPoint(ctx, 19.5, 6.5);
        CGContextMoveToPoint(ctx, 9.0, 6.5);
        CGContextAddLineToPoint(ctx, 9.0, 4.2);
        CGContextAddLineToPoint(ctx, 15.0, 4.2);
        CGContextAddLineToPoint(ctx, 15.0, 6.5);
        CGContextMoveToPoint(ctx, 6.5, 6.5);
        CGContextAddLineToPoint(ctx, 7.4, 19.6);
        CGContextAddLineToPoint(ctx, 16.6, 19.6);
        CGContextAddLineToPoint(ctx, 17.5, 6.5);
        CGContextStrokePath(ctx);
    } else if ([sym isEqualToString:@"pencil"]) {
        CGContextSetLineWidth(ctx, 1.7);
        CGContextMoveToPoint(ctx, 5.0, 19.0);
        CGContextAddLineToPoint(ctx, 7.2, 13.8);
        CGContextAddLineToPoint(ctx, 16.8, 4.2);
        CGContextAddLineToPoint(ctx, 19.8, 7.2);
        CGContextAddLineToPoint(ctx, 10.2, 16.8);
        CGContextClosePath(ctx);
        CGContextStrokePath(ctx);
    } else if ([sym isEqualToString:@"link"]) {
        CGContextSetLineWidth(ctx, 1.75);
        CGContextMoveToPoint(ctx, 9.2, 14.8);
        CGContextAddLineToPoint(ctx, 14.8, 9.2);
        CGContextStrokePath(ctx);
        SPStrokeRoundedRect(ctx, CGRectMake(4.0, 10.5, 8.2, 8.2), 3.6);
        SPStrokeRoundedRect(ctx, CGRectMake(11.8, 5.3, 8.2, 8.2), 3.6);
    } else if ([sym isEqualToString:@"dot.radiowaves.left.and.right"]) {
        CGContextFillEllipseInRect(ctx, CGRectMake(10.0, 10.0, 4.0, 4.0));
        CGContextSetLineWidth(ctx, 1.65);
        CGContextAddArc(ctx, 12.0, 12.0, 5.4, -0.75, 0.75, 0);
        CGContextStrokePath(ctx);
        CGContextAddArc(ctx, 12.0, 12.0, 8.6, -0.82, 0.82, 0);
        CGContextStrokePath(ctx);
        CGContextAddArc(ctx, 12.0, 12.0, 5.4, M_PI - 0.75, M_PI + 0.75, 0);
        CGContextStrokePath(ctx);
        CGContextAddArc(ctx, 12.0, 12.0, 8.6, M_PI - 0.82, M_PI + 0.82, 0);
        CGContextStrokePath(ctx);
    } else if ([sym isEqualToString:@"exclamationmark.triangle"]) {
        CGContextSetLineWidth(ctx, 1.7);
        CGContextMoveToPoint(ctx, 12.0, 4.0);
        CGContextAddLineToPoint(ctx, 20.5, 19.2);
        CGContextAddLineToPoint(ctx, 3.5, 19.2);
        CGContextClosePath(ctx);
        CGContextMoveToPoint(ctx, 12.0, 9.5);
        CGContextAddLineToPoint(ctx, 12.0, 14.2);
        CGContextStrokePath(ctx);
        CGContextFillEllipseInRect(ctx, CGRectMake(10.9, 15.8, 2.2, 2.2));
    } else if ([sym isEqualToString:@"arrow.up.right"]) {
        CGContextMoveToPoint(ctx, 6.5, 17.5);
        CGContextAddLineToPoint(ctx, 17.5, 6.5);
        CGContextMoveToPoint(ctx, 9.2, 6.5);
        CGContextAddLineToPoint(ctx, 17.5, 6.5);
        CGContextAddLineToPoint(ctx, 17.5, 14.8);
        CGContextStrokePath(ctx);
    } else if ([sym isEqualToString:@"square.and.arrow.up"]) {
        CGContextSetLineWidth(ctx, 1.65);
        CGContextMoveToPoint(ctx, 12.0, 14.5);
        CGContextAddLineToPoint(ctx, 12.0, 4.0);
        CGContextMoveToPoint(ctx, 8.2, 7.6);
        CGContextAddLineToPoint(ctx, 12.0, 3.8);
        CGContextAddLineToPoint(ctx, 15.8, 7.6);
        CGContextMoveToPoint(ctx, 8.0, 9.8);
        CGContextAddLineToPoint(ctx, 5.2, 9.8);
        CGContextAddLineToPoint(ctx, 5.2, 19.6);
        CGContextAddLineToPoint(ctx, 18.8, 19.6);
        CGContextAddLineToPoint(ctx, 18.8, 9.8);
        CGContextAddLineToPoint(ctx, 16.0, 9.8);
        CGContextStrokePath(ctx);
    } else if ([sym isEqualToString:@"doc.on.doc"]) {
        CGContextSetLineWidth(ctx, 1.6);
        SPStrokeRoundedRect(ctx, CGRectMake(8.0, 7.5, 10.5, 13.0), 1.8);
        CGContextMoveToPoint(ctx, 6.0, 16.5);
        CGContextAddLineToPoint(ctx, 5.2, 16.5);
        CGContextAddLineToPoint(ctx, 5.2, 4.5);
        CGContextAddLineToPoint(ctx, 14.5, 4.5);
        CGContextAddLineToPoint(ctx, 14.5, 5.8);
        CGContextStrokePath(ctx);
    } else {
        // Default / music.note
        CGContextMoveToPoint(ctx, 9.2, 16.8);
        CGContextAddLineToPoint(ctx, 9.2, 6.0);
        CGContextAddLineToPoint(ctx, 18.6, 4.4);
        CGContextAddLineToPoint(ctx, 18.6, 14.6);
        CGContextStrokePath(ctx);
        CGContextFillEllipseInRect(ctx, CGRectMake(5.2, 14.8, 5.0, 4.0));
        CGContextFillEllipseInRect(ctx, CGRectMake(14.6, 12.8, 5.0, 4.0));
    }

    CGContextRestoreGState(ctx);
}

NSImage *SPSFSymbolImage(NSString *symbolName, CGFloat pointSize, NSFontWeight weight, NSColor *tintColor) {
    if (!symbolName.length) return nil;
    CGFloat sz = MAX(12.0, pointSize + 2.0);
    NSString *sym = [symbolName copy];
    NSColor *col = tintColor;
    NSImage *img = [NSImage imageWithSize:NSMakeSize(sz, sz)
                                  flipped:YES
                           drawingHandler:^BOOL(NSRect dstRect) {
        CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
        if (!ctx) return NO;
        SPDrawVectorSymbolInContext(ctx, sym, dstRect, pointSize, weight, col ?: NSColor.labelColor);
        return YES;
    }];
    img.template = (tintColor == nil);
    return img;
}

void SPDrawSFSymbol(NSString *symbolName, CGRect rect, CGFloat pointSize, NSFontWeight weight, NSColor *color) {
    if (!symbolName.length || CGRectIsEmpty(rect)) return;
    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    if (!ctx) return;
    SPDrawVectorSymbolInContext(ctx, symbolName, rect, pointSize, weight, color ?: NSColor.labelColor);
}

void SPDrawIconSemantic(SPIconName icon, CGRect rect, CGFloat pointSize, NSFontWeight weight, NSColor *color) {
    SPDrawSFSymbol(SPSFSymbolNameForIcon(icon), rect, pointSize, weight, color);
}

void SPDrawIcon(CGContextRef ctx, SPIconName icon, CGRect rect, SPColorToken color) {
    if (!ctx || CGRectIsEmpty(rect)) return;
    CGFloat pt = MAX(9.0, MIN(rect.size.width, rect.size.height) * 0.85);
    SPDrawVectorSymbolInContext(ctx, SPSFSymbolNameForIcon(icon), rect, pt, NSFontWeightRegular, SPNSColor(color));
}

NSImage *SPIconImage(SPIconName icon, CGFloat pointSize, SPColorToken color) {
    return SPSFSymbolImage(SPSFSymbolNameForIcon(icon), pointSize, NSFontWeightRegular, SPNSColor(color));
}

#pragma mark - Duration Formatting

NSString *SPFormatDurationMs(int64_t ms) {
    if (ms < 0) ms = 0;
    int64_t totalSec = ms / 1000;
    int64_t hours = totalSec / 3600;
    int64_t mins = (totalSec % 3600) / 60;
    int64_t secs = totalSec % 60;
    if (hours > 0) {
        return [NSString stringWithFormat:@"%lld:%02lld:%02lld", hours, mins, secs];
    }
    return [NSString stringWithFormat:@"%lld:%02lld", mins, secs];
}

NSString *SPFormatTotalDurationMs(int64_t totalMs) {
    if (totalMs <= 0) return @"0 min";
    int64_t totalMin = (totalMs + 30000) / 60000;
    if (totalMin < 1) totalMin = 1;
    int64_t hrs = totalMin / 60;
    int64_t mins = totalMin % 60;
    if (hrs > 0) {
        return mins > 0
            ? [NSString stringWithFormat:@"%lld hr %lld min", hrs, mins]
            : [NSString stringWithFormat:@"%lld hr", hrs];
    }
    return [NSString stringWithFormat:@"%lld min", mins];
}

#pragma mark - Artwork & Liked Songs Drawing

void SPDrawArtworkSemantic(CGContextRef ctx,
                           CGImageRef image,
                           CGRect rect,
                           CGFloat radius,
                           BOOL circular,
                           NSString *placeholderSymbol,
                           CGFloat symbolSize,
                           CGFloat shadowRadius) {
    if (!ctx || CGRectIsEmpty(rect)) return;

    CGFloat r = circular ? MIN(rect.size.width, rect.size.height) * 0.5 : radius;
    CGPathRef clipPath = CGPathCreateWithRoundedRect(rect, r, r, NULL);
    BOOL drawRim = (image != NULL && shadowRadius > 0.0);

    CGContextSaveGState(ctx);
    CGContextAddPath(ctx, clipPath);
    CGContextClip(ctx);

    if (image) {
        NSGraphicsContext *nsCtx = NSGraphicsContext.currentContext;
        BOOL flipped = nsCtx ? nsCtx.isFlipped : (CGContextGetCTM(ctx).d < 0);
        CGFloat iw = (CGFloat)CGImageGetWidth(image);
        CGFloat ih = (CGFloat)CGImageGetHeight(image);
        CGRect drawRect = rect;
        if (iw > 0 && ih > 0) {
            CGFloat scale = MAX(rect.size.width / iw, rect.size.height / ih);
            CGFloat dw = iw * scale;
            CGFloat dh = ih * scale;
            drawRect = CGRectMake(CGRectGetMidX(rect) - dw * 0.5,
                                  CGRectGetMidY(rect) - dh * 0.5,
                                  dw,
                                  dh);
        }
        if (flipped) {
            CGContextTranslateCTM(ctx, 0, CGRectGetMinY(rect) + CGRectGetMaxY(rect));
            CGContextScaleCTM(ctx, 1.0, -1.0);
        }
        CGContextSetInterpolationQuality(ctx, kCGInterpolationMedium);
        CGContextDrawImage(ctx, drawRect, image);
    } else {
        CGContextSetFillColorWithColor(ctx, SPQuaternaryFillColor().CGColor);
        CGContextFillRect(ctx, rect);
        if (placeholderSymbol.length) {
            CGFloat sym = symbolSize > 0.0 ? symbolSize : MAX(12.0, MIN(rect.size.width, rect.size.height) * 0.34);
            SPDrawVectorSymbolInContext(ctx, placeholderSymbol, rect, sym, NSFontWeightRegular, SPSecondaryLabelColor());
        }
    }

    CGContextRestoreGState(ctx);
    if (drawRim) {
        NSColor *rim = SPIsDarkAppearance(nil)
            ? [NSColor colorWithWhite:1.0 alpha:0.08]
            : [NSColor colorWithWhite:0.0 alpha:0.08];
        CGContextSetStrokeColorWithColor(ctx, rim.CGColor);
        CGContextSetLineWidth(ctx, 0.5);
        CGContextAddPath(ctx, clipPath);
        CGContextStrokePath(ctx);
    }
    CGPathRelease(clipPath);
}

void SPDrawRoundedArtwork(CGContextRef ctx,
                          CGImageRef image,
                          CGRect rect,
                          CGFloat radius,
                          BOOL circular,
                          SPColorToken placeholderBg,
                          SPColorToken placeholderIcon) {
    (void)placeholderBg;
    (void)placeholderIcon;
    SPDrawArtworkSemantic(ctx, image, rect, radius, circular, circular ? @"person.fill" : @"music.note", 0.0, 0.0);
}

void SPDrawLikedSongsTile(CGContextRef ctx, CGRect rect, CGFloat radius, BOOL purpleStyle) {
    if (!ctx || CGRectIsEmpty(rect)) return;
    CGContextSaveGState(ctx);
    CGFloat r = MIN(radius, MIN(rect.size.width, rect.size.height) * 0.5);
    CGPathRef path = CGPathCreateWithRoundedRect(rect, r, r, NULL);
    CGContextAddPath(ctx, path);
    CGContextClip(ctx);

    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGFloat comps[8];
    if (purpleStyle) {
        // Spotify Liked Songs tile gradient (#450AF5 -> #8D9DF6)
        comps[0] = 0.27; comps[1] = 0.07; comps[2] = 0.92; comps[3] = 1.0;
        comps[4] = 0.62; comps[5] = 0.72; comps[6] = 0.94; comps[7] = 1.0;
    } else {
        // Spotifly Favorites DetailHeader gradient: (1, 0.56, 0.64) -> (0.88, 0.14, 0.37)
        comps[0] = 1.00; comps[1] = 0.56; comps[2] = 0.64; comps[3] = 1.0;
        comps[4] = 0.88; comps[5] = 0.14; comps[6] = 0.37; comps[7] = 1.0;
    }
    CGFloat locs[2] = {0.0, 1.0};
    CGGradientRef grad = CGGradientCreateWithColorComponents(cs, comps, locs, 2);
    CGContextDrawLinearGradient(ctx, grad,
                                CGPointMake(CGRectGetMinX(rect), CGRectGetMinY(rect)),
                                CGPointMake(CGRectGetMaxX(rect), CGRectGetMaxY(rect)),
                                0);
    CGGradientRelease(grad);
    CGColorSpaceRelease(cs);
    CGPathRelease(path);

    CGFloat heartPt = MIN(rect.size.width, rect.size.height) * 0.42;
    SPDrawVectorSymbolInContext(ctx, @"heart.fill", rect, heartPt, NSFontWeightSemibold, NSColor.whiteColor);
    CGContextRestoreGState(ctx);
}

void SPDrawProfileAvatar(CGContextRef ctx,
                         CGImageRef image,
                         NSString *displayName,
                         CGRect rect) {
    if (!ctx || CGRectIsEmpty(rect)) return;
    if (image) {
        SPDrawArtworkSemantic(ctx, image, rect, rect.size.width * 0.5, YES, @"person.fill", 0.0, 0.0);
        return;
    }

    CGContextSaveGState(ctx);
    CGPathRef circle = CGPathCreateWithEllipseInRect(rect, NULL);
    CGContextAddPath(ctx, circle);
    CGContextClip(ctx);

    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGFloat comps[8] = {
        0x22 / 255.0, 0xCC / 255.0, 0x5E / 255.0, 1.0,
        0x17 / 255.0, 0x9E / 255.0, 0x47 / 255.0, 1.0,
    };
    CGFloat locs[2] = {0.0, 1.0};
    CGGradientRef grad = CGGradientCreateWithColorComponents(cs, comps, locs, 2);
    CGContextDrawLinearGradient(ctx, grad,
                                CGPointMake(CGRectGetMidX(rect), CGRectGetMinY(rect)),
                                CGPointMake(CGRectGetMidX(rect), CGRectGetMaxY(rect)),
                                0);
    CGGradientRelease(grad);
    CGColorSpaceRelease(cs);
    CGPathRelease(circle);

    NSString *trimmed = [displayName stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *initials = trimmed.length >= 2
        ? [[trimmed substringToIndex:2] uppercaseString]
        : (trimmed.length == 1 ? [trimmed uppercaseString] : @"?");
    CGFloat fontSize = MAX(9.0, round(rect.size.width * 0.40));
    SPTextStyle ts = {fontSize, NSFontWeightSemibold, fontSize + 2.0, 0.0, NO};
    NSDictionary *attrs = SPSemanticTextAttributes(ts, NSColor.whiteColor, NSLineBreakByClipping, NSTextAlignmentCenter);
    NSSize sz = [initials sizeWithAttributes:attrs];
    [initials drawInRect:NSMakeRect(rect.origin.x,
                                    floor(CGRectGetMidY(rect) - sz.height * 0.5),
                                    rect.size.width,
                                    ceil(sz.height))
          withAttributes:attrs];
    CGContextRestoreGState(ctx);
}

#pragma mark - Liquid Glass Container

NSView *SPCreateGlassContainerView(NSRect frame, CGFloat cornerRadius, NSView *contentView) {
    if (@available(macOS 26.0, *)) {
        NSGlassEffectView *glass = [[NSGlassEffectView alloc] initWithFrame:frame];
        glass.style = NSGlassEffectViewStyleRegular;
        glass.cornerRadius = cornerRadius;
        glass.contentView = contentView;
        return glass;
    }

    NSVisualEffectView *vev = [[NSVisualEffectView alloc] initWithFrame:frame];
    vev.material = NSVisualEffectMaterialHUDWindow;
    vev.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    vev.state = NSVisualEffectStateActive;
    vev.wantsLayer = YES;
    vev.layer.cornerRadius = cornerRadius;
    vev.layer.masksToBounds = YES;
    vev.layer.borderWidth = 1.0;
    vev.layer.borderColor = [NSColor colorWithWhite:1.0 alpha:0.14].CGColor;
    contentView.frame = vev.bounds;
    contentView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [vev addSubview:contentView];
    return vev;
}

void SPUpdateGlassContainerCornerRadius(NSView *glassContainer, CGFloat cornerRadius) {
    if (@available(macOS 26.0, *)) {
        if ([glassContainer isKindOfClass:NSGlassEffectView.class]) {
            ((NSGlassEffectView *)glassContainer).cornerRadius = cornerRadius;
            return;
        }
    }
    glassContainer.layer.cornerRadius = cornerRadius;
}
