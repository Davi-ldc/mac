// Owns the facepile, the huddle message's square and the LIVE badge.
#import "render/icon.h"
#import "render/images.h"
#import "render/strings.h"
#import "ui/huddle/huddle.h"
#import "ui/kit/label.h"

/// .p-huddle_msg_status_badge: 11 px bold on a 14 px line with 2 px above and below, 8 px each
/// side, radius 12.
static const CGFloat kBadgeFont = 11, kBadgeHeight = 18, kBadgePadding = 8;

SNHuddle *SNActiveHuddle(id<SNSource> source, NSString *conversationID) {
    SNHuddle *huddle = conversationID ? [source huddleInConversation:conversationID] : nil;
    return huddle.isActive ? huddle : nil;
}

BOOL SNInCallInConversation(id<SNSource> source, NSString *conversationID) {
    SNCall *call = source.call;
    return call && call.state != SNCallLeaving && [call.conversationID isEqualToString:conversationID];
}

NSArray<NSString *> *SNFacepileUserIDs(SNHuddle *huddle, NSUInteger limit) {
    NSArray<NSString *> *people = huddle.participantIDs ?: @[];
    return people.count > limit ? [people subarrayWithRange:NSMakeRange(0, limit)] : people;
}

CGFloat SNFacepileWidth(NSUInteger count, CGFloat size) { return count * size; }

/// huddles-mask (objectBoundingBox): the left edge hollowed where the previous avatar's rounded
/// side comes, the right corners rounded; y grows downwards as in the flipped views.
static CGPathRef CreateMaskPath(CGRect box) {
    CGMutablePathRef path = CGPathCreateMutable();
    CGAffineTransform t = CGAffineTransformMake(box.size.width, 0, 0, box.size.height, box.origin.x, box.origin.y);
    CGPathMoveToPoint(path, &t, 0.03, 1);
    CGPathAddLineToPoint(path, &t, 0.772, 1);
    CGPathAddQuadCurveToPoint(path, &t, 1.03, 1, 1.03, 0.8);
    CGPathAddLineToPoint(path, &t, 1.03, 0.2);
    CGPathAddQuadCurveToPoint(path, &t, 1.03, 0, 0.772, 0);
    CGPathAddLineToPoint(path, &t, 0.03, 0);
    CGPathAddQuadCurveToPoint(path, &t, 0.128, 0.06, 0.128, 0.2);
    CGPathAddLineToPoint(path, &t, 0.128, 0.8);
    CGPathAddQuadCurveToPoint(path, &t, 0.128, 0.94, 0.03, 1);
    CGPathCloseSubpath(path);
    return path;
}

NSArray<SNUser *> *SNFacepileUsers(NSArray<NSString *> *userIDs, id<SNSource> source) {
    NSMutableArray<SNUser *> *users = [NSMutableArray new];
    for (NSString *userID in userIDs) {
        SNUser *user = [source userWithID:userID];
        if (user) [users addObject:user];
    }
    return users;
}

void SNDrawFacepile(NSArray<SNUser *> *users, CGFloat size, NSPoint origin, SNImageHolder *images) {
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    CGFloat pixels = size * 2;
    for (NSUInteger i = 0; i < users.count; i++) {
        CGRect box = CGRectMake(origin.x + i * size, origin.y, size, size);
        NSURL *url = [users[i] avatarURLForPixels:pixels];
        CGImageRef image = url ? [images imageWithURL:url pixels:pixels] : NULL;
        CGContextSaveGState(context);
        CGPathRef rounded = CGPathCreateWithRoundedRect(box, size * 0.25, size * 0.25, NULL);
        CGContextAddPath(context, rounded);
        CGContextClip(context);
        CGPathRelease(rounded);
        if (i > 0) {
            CGPathRef mask = CreateMaskPath(box);
            CGContextAddPath(context, mask);
            CGContextClip(context);
            CGPathRelease(mask);
        }
        CGContextSetFillColorWithColor(context, SNCGColor(SNLegacyForegroundLowSolid));
        CGContextFillRect(context, box);
        if (image) {
            CGFloat width = CGImageGetWidth(image), height = CGImageGetHeight(image), scale = size / MIN(width, height);
            CGContextTranslateCTM(context, box.origin.x, box.origin.y + size);
            CGContextScaleCTM(context, 1, -1);
            CGContextDrawImage(context, CGRectMake((size - width * scale) / 2, (size - height * scale) / 2, width * scale, height * scale), image);
        }
        CGContextRestoreGState(context);
    }
}

@implementation SNFacepileView {
    id<SNSource> _source;
}

- (instancetype)initWithSource:(id<SNSource>)source {
    if (!(self = [super initWithFrame:NSZeroRect])) return nil;
    _source = source;
    _userIDs = @[];
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)setUserIDs:(NSArray<NSString *> *)userIDs {
    if ([userIDs isEqualToArray:_userIDs]) return;
    _userIDs = [userIDs copy];
    [self.imageHolder removeAllImages];
    self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    SNDrawFacepile(SNFacepileUsers(_userIDs, _source), self.bounds.size.height, NSZeroPoint, self.imageHolder);
}

@end

/// c-button medium: 12 pt each side; the faces keep 8 pt after them.
static const CGFloat kJoinPadding = 12, kJoinFacesGap = 8;

@implementation SNHuddleJoinButton {
    SNFacepileView *_facepile;
}

- (instancetype)initWithSource:(id<SNSource>)source {
    if (!(self = [super initWithFrame:NSZeroRect])) return nil;
    _facepile = [[SNFacepileView alloc] initWithSource:source];
    [self addSubview:_facepile];
    self.fillColor = self.hoverFillColor = SNColorBasePry;
    self.borderColor = SNPaletteJade20;
    self.cornerRadius = SNRadiusLarge;
    self.hoverColor = self.pressedColor = 0;
    self.transitionDuration = SNDuration160;
    return self;
}

+ (CGFloat)widthForTitle:(NSString *)title faces:(NSUInteger)count {
    CGFloat text = ceil([title sizeWithAttributes:@{NSFontAttributeName : SNFont(SNFontSizeBase, SNFontWeightBold)}].width);
    return kJoinPadding + (count ? SNFacepileWidth(count, SNHuddleFacepileAvatar) + kJoinFacesGap : 0) + text + kJoinPadding;
}

- (void)setUserIDs:(NSArray<NSString *> *)userIDs {
    _userIDs = [userIDs copy];
    _facepile.userIDs = userIDs;
    self.needsLayout = YES;
}

- (void)layout {
    [super layout];
    CGFloat faces = SNFacepileWidth(_userIDs.count, SNHuddleFacepileAvatar), middle = NSHeight(self.bounds) / 2;
    _facepile.frame = NSMakeRect(kJoinPadding, middle - SNHuddleFacepileAvatar / 2, faces, SNHuddleFacepileAvatar);
    // SNButton keeps its label to itself: it is the subview that is not the facepile.
    for (NSView *view in self.subviews) {
        if (view == _facepile) continue;
        NSRect frame = view.frame;
        frame.origin.x = kJoinPadding + (faces ? faces + kJoinFacesGap : 0);
        view.frame = frame;
    }
}

- (void)stateDidChange {
    [super stateDidChange];
    // opacity .8 on hover, .16 s ease-in-out.
    self.alphaValue = self.hovered || self.pressed ? 0.8 : 1;
}

@end

void SNDrawHuddleAvatar(NSRect rect, BOOL live) {
    CGFloat radius = SNRadiusIaIcon(rect.size.width);
    // Ended: rgba(foreground_low, .13) under rgba(foreground_max, .7); live: jade-60 under white.
    [SNColor(live ? SNPaletteJade60 : SNLegacyHairline) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:rect xRadius:radius yRadius:radius] fill];
    SNDrawIcon(@"headphones", 20, live ? 0xffffffff : 0xe8e8e8b3, rect);
}

CGFloat SNLiveBadgeWidth(void) {
    NSFont *font = SNFont(kBadgeFont, SNFontWeightBold);
    return ceil([SNLocalized(@"huddle.live") sizeWithAttributes:@{NSFontAttributeName : font}].width) + 2 * kBadgePadding;
}

CGFloat SNDrawLiveBadge(CGFloat x, CGFloat middle) {
    CGFloat width = SNLiveBadgeWidth();
    NSRect pill = NSMakeRect(x, round(middle - kBadgeHeight / 2), width, kBadgeHeight);
    [SNColor(SNPaletteJade80) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:pill xRadius:kBadgeHeight / 2 yRadius:kBadgeHeight / 2] fill];
    SNDrawText(SNLocalized(@"huddle.live"), SNFont(kBadgeFont, SNFontWeightBold), SNPaletteJade0, kBadgeHeight, NSTextAlignmentCenter, 1, pill);
    return width;
}
