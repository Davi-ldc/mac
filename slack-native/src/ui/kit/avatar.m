// Owns drawing the avatar: picture, rounding, presence notch and presence glyph.
#import "render/images.h"
#import "ui/kit/avatar.h"

/// Proportions of the avatar's side, measured on the 36 pt avatars of the reference captures:
/// the glyph is a 9 pt dot centred on the notch, the away ring is 1.25 pt wide.
static const CGFloat kNotchCentre = 0.889, kNotchRadius = 0.208, kDotRadius = 0.125, kRingWidth = 0.035;

SNAvatarPresence SNAvatarPresenceOfUser(SNUser *user, id<SNSource> source) {
    if (!user || user.isBot) return SNAvatarPresenceNone;
    return [source presenceOfUser:user.userID] == SNPresenceActive ? SNAvatarPresenceActive : SNAvatarPresenceAway;
}

@implementation SNAvatarView

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _awayColor = SNLegacyForegroundMaxSolid;
    _placeholderColor = SNLegacyForegroundLowSolid;
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)setImageURL:(NSURL *)imageURL {
    if (imageURL == _imageURL || [imageURL isEqual:_imageURL]) {
        // Setting the same picture again retries one that failed to load.
        [self.imageHolder removeFailedImages];
        self.needsDisplay = YES;
        return;
    }
    _imageURL = imageURL;
    // A reused view (a list row) must not keep showing the previous person meanwhile.
    [self.imageHolder removeAllImages];
    self.needsDisplay = YES;
}

- (CGImageRef)image {
    CGFloat pixels = self.bounds.size.width * (self.window.backingScaleFactor ?: 2);
    return _imageURL ? [self.imageHolder imageWithURL:_imageURL pixels:pixels] : NULL;
}

- (void)setPresence:(SNAvatarPresence)presence {
    _presence = presence;
    self.needsDisplay = YES;
}

- (void)setDoNotDisturb:(BOOL)doNotDisturb {
    _doNotDisturb = doNotDisturb;
    self.needsDisplay = YES;
}

- (void)setAwayColor:(SNColorToken)awayColor {
    _awayColor = awayColor;
    self.needsDisplay = YES;
}

- (void)setPlaceholderColor:(SNColorToken)placeholderColor {
    _placeholderColor = placeholderColor;
    self.needsDisplay = YES;
}

/// The 'z' of Do Not Disturb, above and right of the ring.
static CGRect SnoozeBox(CGFloat side, CGPoint centre) {
    return CGRectMake(centre.x + side * 0.02, centre.y - side * 0.2, side * 0.14, side * 0.14);
}

- (void)drawRect:(NSRect)dirtyRect {
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    CGFloat side = MIN(self.bounds.size.width, self.bounds.size.height);
    CGRect box = CGRectMake(0, 0, side, side);
    CGPoint centre = CGPointMake(side * kNotchCentre, side * kNotchCentre);
    BOOL presence = self.presence != SNAvatarPresenceNone;

    CGContextSaveGState(context);
    CGFloat radius = SNRadiusIaIcon(side);
    CGPathRef rounded = CGPathCreateWithRoundedRect(box, radius, radius, NULL);
    CGContextAddPath(context, rounded);
    CGPathRelease(rounded);
    if (presence) {
        // The notch: an even-odd hole where the presence glyph sits.
        CGContextAddEllipseInRect(context, CGRectInset(CGRectMake(centre.x, centre.y, 0, 0), -side * kNotchRadius, -side * kNotchRadius));
        if (self.doNotDisturb) CGContextAddEllipseInRect(context, SnoozeBox(side, centre));
        CGContextEOClip(context);
    } else {
        CGContextClip(context);
    }
    CGContextSetFillColorWithColor(context, SNCGColor(self.placeholderColor));
    CGContextFillRect(context, box);
    CGImageRef image = self.image;
    if (image) {
        // Aspect fill, upright in the flipped view.
        CGFloat width = CGImageGetWidth(image), height = CGImageGetHeight(image), scale = side / MIN(width, height);
        CGRect drawn = CGRectMake((side - width * scale) / 2, (side - height * scale) / 2, width * scale, height * scale);
        CGContextTranslateCTM(context, 0, side);
        CGContextScaleCTM(context, 1, -1);
        CGContextDrawImage(context, drawn, image);
    }
    CGContextRestoreGState(context);
    if (!presence) return;

    CGColorRef color = SNCGColor(self.presence == SNAvatarPresenceActive ? SNThemeBaseInvHgl2 : self.awayColor);
    CGFloat dot = side * kDotRadius, ring = MAX(1, side * kRingWidth);
    CGContextSetStrokeColorWithColor(context, color);
    CGContextSetFillColorWithColor(context, color);
    CGContextSetLineWidth(context, ring);
    CGContextSetLineCap(context, kCGLineCapRound);
    CGContextSetLineJoin(context, kCGLineJoinRound);
    if (self.doNotDisturb) {
        // An open ring, broken at the top right where the 'z' sits.
        CGContextAddArc(context, centre.x, centre.y, dot - ring / 2, -M_PI / 6, -M_PI / 2, 0);
        CGContextStrokePath(context);
        CGRect z = CGRectInset(SnoozeBox(side, centre), side * 0.03, side * 0.03);
        CGPoint stroke[] = {{CGRectGetMinX(z), CGRectGetMinY(z)}, {CGRectGetMaxX(z), CGRectGetMinY(z)},
                            {CGRectGetMinX(z), CGRectGetMaxY(z)}, {CGRectGetMaxX(z), CGRectGetMaxY(z)}};
        CGContextAddLines(context, stroke, 4);
        CGContextStrokePath(context);
    } else if (self.presence == SNAvatarPresenceAway) {
        CGContextStrokeEllipseInRect(context, CGRectInset(CGRectMake(centre.x, centre.y, 0, 0), -dot + ring / 2, -dot + ring / 2));
    } else {
        CGContextFillEllipseInRect(context, CGRectInset(CGRectMake(centre.x, centre.y, 0, 0), -dot, -dot));
    }
}

@end
