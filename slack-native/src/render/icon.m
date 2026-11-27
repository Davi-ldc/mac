// Owns reading Slack's outlines, the SF Symbol stand-ins, rendering icons into tinted images and
// the icon layer.
#import "render/icon.h"

/// Glyphs are drawn for Retina screens; a 1x screen downsamples them.
static const CGFloat kImageScale = 2;
/// Slack's drawings use a 20-unit box.
static const CGFloat kViewBox = 20;

#pragma mark - Slack's outlines

/// Resources/slack-icons.txt, written by src/render/icons.py: one icon per line, "<name>\t"
/// then elements, each a paint ("E" even-odd fill, "F" non-zero fill, "S<width>" round-capped
/// stroke) and a path of absolute M, L, C and Z in the 20-unit box.
@interface SNIconOutline : NSObject {
  @public
    NSArray *_paths;
    NSArray<NSNumber *> *_strokeWidths;  // 0 fills non-zero, -1 fills even-odd
}
@end

@implementation SNIconOutline
@end

static NSData *OutlineData(void) {
    static NSData *data;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *path = [NSBundle.mainBundle pathForResource:@"slack-icons" ofType:@"txt"];
        // Mapped: the 700 icons cost no memory until a line is read.
        data = path ? [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:NULL] : nil;
    });
    return data;
}

/// Name -> range of the line's elements in OutlineData().
static NSDictionary<NSString *, NSValue *> *OutlineIndex(void) {
    static NSDictionary *index;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSData *data = OutlineData();
        if (!data) return;
        NSMutableDictionary *lines = [NSMutableDictionary dictionary];
        const char *bytes = data.bytes, *end = bytes + data.length;
        for (const char *line = bytes; line < end;) {
            const char *stop = memchr(line, '\n', (size_t)(end - line)) ?: end;
            const char *tab = memchr(line, '\t', (size_t)(stop - line));
            if (tab) {
                NSString *name = [[NSString alloc] initWithBytes:line length:(NSUInteger)(tab - line) encoding:NSUTF8StringEncoding];
                lines[name] = [NSValue valueWithRange:NSMakeRange((NSUInteger)(tab + 1 - bytes), (NSUInteger)(stop - tab - 1))];
            }
            line = stop + 1;
        }
        index = lines;
    });
    return index;
}

BOOL SNHasSlackIcons(void) {
    return OutlineIndex().count > 0;
}

static SNIconOutline *Outline(NSString *name) {
    static NSMutableDictionary *outlines;
    if (!outlines) outlines = [NSMutableDictionary dictionary];
    SNIconOutline *outline = outlines[name];
    if (outline) return outline;
    NSValue *range = OutlineIndex()[name];
    if (!range) return nil;
    NSData *line = [OutlineData() subdataWithRange:range.rangeValue];
    char *text = calloc(line.length + 1, 1);
    memcpy(text, line.bytes, line.length);
    NSMutableArray *paths = [NSMutableArray array], *widths = [NSMutableArray array];
    CGMutablePathRef path = NULL;
    for (char *p = text; *p;) {
        char c = *p++;
        if (c == '\t') continue;
        if (c == 'E' || c == 'F' || c == 'S') {
            path = CGPathCreateMutable();
            [paths addObject:(__bridge_transfer id)path];
            [widths addObject:@(c == 'S' ? strtod(p, &p) : c == 'E' ? -1 : 0)];
            continue;
        }
        if (!path || c == ' ') continue;
        double v[6];
        int count = c == 'C' ? 6 : c == 'Z' ? 0 : 2;
        for (int i = 0; i < count; i++) v[i] = strtod(p, &p);
        if (c == 'M') CGPathMoveToPoint(path, NULL, v[0], v[1]);
        else if (c == 'L') CGPathAddLineToPoint(path, NULL, v[0], v[1]);
        else if (c == 'C') CGPathAddCurveToPoint(path, NULL, v[0], v[1], v[2], v[3], v[4], v[5]);
        else if (c == 'Z') CGPathCloseSubpath(path);
    }
    free(text);
    outline = [SNIconOutline new];
    outline->_paths = paths;
    outline->_strokeWidths = widths;
    outlines[name] = outline;
    return outline;
}

static void DrawOutline(SNIconOutline *outline, CGContextRef context, CGFloat side, SNColorToken color) {
    // SVG's y axis points down.
    CGContextTranslateCTM(context, 0, side);
    CGContextScaleCTM(context, side / kViewBox, -side / kViewBox);
    CGContextSetFillColorWithColor(context, SNCGColor(color));
    CGContextSetStrokeColorWithColor(context, SNCGColor(color));
    CGContextSetLineCap(context, kCGLineCapRound);
    for (NSUInteger i = 0; i < outline->_paths.count; i++) {
        CGContextAddPath(context, (__bridge CGPathRef)outline->_paths[i]);
        CGFloat width = outline->_strokeWidths[i].doubleValue;
        if (width > 0) {
            CGContextSetLineWidth(context, width);
            CGContextStrokePath(context);
        } else if (width < 0) {
            CGContextEOFillPath(context);
        } else {
            CGContextFillPath(context);
        }
    }
}

#pragma mark - SF Symbol stand-ins

/// Every icon the app draws, with the SF Symbol that stands in for it without Slack's outlines:
/// `fit` is the share of the box Slack's glyph covers on its longer side, and `turn` (degrees,
/// clockwise) points the symbol the way Slack's glyph points (SF has no vertical ellipsis).
typedef struct {
    const char *name, *symbol;
    CGFloat fit;
    BOOL bold;
    CGFloat turn;
} SNIconStandIn;

static const SNIconStandIn kStandIns[] = {
    {"add-channel-canvas", "doc.badge.plus", 0.88, NO, 0},
    {"add-reaction", "face.smiling", 0.93, NO, 0},
    {"ai-agents", "square.grid.2x2", 0.85, NO, 0},
    {"ai-agents-filled", "square.grid.2x2.fill", 0.85, NO, 0},
    {"ai-search", "sparkle.magnifyingglass", 0.90, NO, 0},
    {"ai-sparkle", "sparkles", 0.85, NO, 0},
    {"ai-summary", "sparkles", 0.88, NO, 0},
    {"apps", "square.grid.2x2", 0.70, NO, 0},
    {"arrow-collapse", "arrow.down.right.and.arrow.up.left", 0.85, NO, 0},
    {"arrow-down", "arrow.down", 0.70, NO, 0},
    {"arrow-left", "arrow.left", 0.70, NO, 0},
    {"arrow-right", "arrow.right", 0.70, NO, 0},
    {"binary", "01.square", 0.85, NO, 0},
    {"bold", "bold", 0.80, NO, 0},
    {"bookmark", "bookmark", 0.86, NO, 0},
    {"bookmark-filled", "bookmark.fill", 0.86, NO, 0},
    {"buildings", "building.2", 0.90, NO, 0},
    {"bulleted-list", "list.bullet", 0.82, NO, 0},
    {"calendar", "calendar", 0.90, NO, 0},
    {"call", "phone", 0.85, NO, 0},
    {"canvas", "doc.richtext", 0.85, NO, 0},
    {"canvas-browser", "doc.on.doc", 0.85, NO, 0},
    {"canvas-browser-filled", "doc.on.doc.fill", 0.85, NO, 0},
    {"canvas-content", "doc.richtext", 0.85, NO, 0},
    {"caret-down", "chevron.down", 0.46, YES, 0},
    {"caret-down-filled", "arrowtriangle.down.fill", 0.46, NO, 0},
    {"caret-left", "chevron.left", 0.46, YES, 0},
    {"caret-left-double-full", "chevron.left.2", 0.60, YES, 0},
    {"caret-left-full", "chevron.left", 0.50, YES, 0},
    {"caret-right", "chevron.right", 0.46, YES, 0},
    {"caret-right-double-full", "chevron.right.2", 0.60, YES, 0},
    {"caret-right-filled", "arrowtriangle.right.fill", 0.46, NO, 0},
    {"caret-right-full", "chevron.right", 0.50, YES, 0},
    {"caret-up-filled", "arrowtriangle.up.fill", 0.46, NO, 0},
    {"channel", "number", 0.81, NO, 0},
    {"channel-filled", "number", 0.81, YES, 0},
    {"channel-section", "number.square", 0.82, NO, 0},
    {"check", "checkmark", 0.70, YES, 0},
    {"check-add", "checkmark.circle.badge.plus", 0.93, NO, 0},
    {"check-circle", "checkmark.circle", 0.90, NO, 0},
    {"clock", "clock", 0.90, NO, 0},
    {"close", "xmark", 0.68, NO, 0},
    {"close-circle-filled", "xmark.circle.fill", 0.90, NO, 0},
    {"close-filled", "xmark", 0.74, YES, 0},
    {"closed-caption", "captions.bubble", 0.90, NO, 0},
    {"cloud-offline-filled", "icloud.slash.fill", 0.90, NO, 0},
    {"code", "chevron.left.forwardslash.chevron.right", 0.91, NO, 0},
    {"code-block", "curlybraces.square", 0.92, NO, 0},
    {"comment", "bubble.left", 0.93, NO, 0},
    {"copy", "doc.on.doc", 0.88, NO, 0},
    {"compose", "square.and.pencil", 0.86, NO, 0},
    {"direct-messages", "bubble.left.and.bubble.right", 0.89, NO, 0},
    {"direct-messages-filled", "bubble.left.and.bubble.right.fill", 0.89, NO, 0},
    {"divider", "rectangle.split.1x2", 0.85, NO, 0},
    {"document", "doc.text", 0.81, NO, 0},
    {"download", "arrow.down.to.line", 0.94, NO, 0},
    {"edit", "pencil", 0.86, NO, 0},
    {"ellipsis-vertical-filled", "ellipsis", 0.80, NO, 90},
    {"email", "envelope", 0.86, NO, 0},
    {"emoji", "face.smiling.inverse", 0.90, NO, 0},
    {"emoji-activities", "football", 0.98, NO, 0},
    {"emoji-filled", "face.smiling.inverse", 0.90, NO, 0},
    {"emoji-flag", "flag", 0.85, NO, 0},
    {"emoji-food", "fork.knife", 0.90, NO, 0},
    {"emoji-nature", "leaf", 0.87, NO, 0},
    {"emoji-objects", "lightbulb", 0.90, NO, 0},
    {"emoji-symbols", "peacesign", 0.90, NO, 0},
    {"emoji-travel", "airplane", 0.87, NO, 0},
    {"eraser", "eraser", 0.85, NO, 0},
    {"expand-diagonal", "arrow.up.left.and.arrow.down.right", 0.85, NO, 0},
    {"eye-open-filled", "eye.fill", 0.90, NO, 0},
    {"file", "doc", 0.81, NO, 0},
    {"files", "doc.on.doc", 0.85, NO, 0},
    {"filters", "line.3.horizontal.decrease", 0.80, NO, 0},
    {"formatting", "textformat", 1.00, NO, 0},
    {"gif", "photo", 0.85, NO, 0},
    {"globe", "globe", 0.90, NO, 0},
    {"headphones", "headphones", 0.88, NO, 0},
    {"help", "questionmark.circle", 0.90, NO, 0},
    {"home", "house", 0.86, NO, 0},
    {"home-filled", "house.fill", 0.86, NO, 0},
    {"image", "photo", 0.90, NO, 0},
    {"info", "info.circle", 0.90, NO, 0},
    {"italic", "italic", 0.80, NO, 0},
    {"laptop", "laptopcomputer", 0.93, NO, 0},
    {"link", "link", 0.90, NO, 0},
    {"lists", "checklist", 0.85, NO, 0},
    {"lock", "lock", 0.82, NO, 0},
    {"lock-filled", "lock.fill", 0.82, NO, 0},
    {"mark-as-read", "envelope.open", 0.75, NO, 0},
    {"mark-as-unread", "envelope.badge", 0.75, NO, 0},
    {"mentions", "at", 0.97, NO, 0},
    {"message", "bubble.left", 0.93, NO, 0},
    {"message-filled", "bubble.left.fill", 0.91, NO, 0},
    {"microphone", "mic", 0.80, NO, 0},
    {"microphone-off", "mic.slash", 0.80, NO, 0},
    {"mobile", "iphone", 0.90, NO, 0},
    {"moon", "moon", 0.80, NO, 0},
    {"move-to-split-view", "rectangle.split.2x1", 0.90, NO, 0},
    {"new-window", "arrow.up.forward.square", 0.88, NO, 0},
    {"notifications", "bell", 0.87, NO, 0},
    {"notifications-dnd-filled", "bell.slash.fill", 0.87, NO, 0},
    {"notifications-filled", "bell.fill", 0.87, NO, 0},
    {"numbered-list", "list.number", 0.85, NO, 0},
    {"open-in-window", "macwindow.badge.plus", 0.90, NO, 0},
    {"paintbrush", "paintbrush", 0.88, NO, 0},
    {"paragraph", "paragraphsign", 0.85, NO, 0},
    {"pause", "pause.fill", 0.80, NO, 0},
    {"pdf-file", "doc.richtext", 0.81, NO, 0},
    {"play", "play", 0.90, NO, 0},
    {"play-filled", "play.fill", 0.80, NO, 0},
    {"plus", "plus", 0.75, NO, 0},
    {"plus-filled", "plus", 0.75, NO, 0},
    {"presentation", "rectangle.on.rectangle", 0.85, NO, 0},
    {"quick-switch", "text.magnifyingglass", 0.87, NO, 0},
    {"quote", "text.alignleft", 0.80, NO, 0},
    {"reaction-add", "face.smiling", 0.93, NO, 0},
    {"reduce-diagonal", "arrow.down.right.and.arrow.up.left", 0.85, NO, 0},
    {"refine", "line.3.horizontal.decrease", 0.70, NO, 0},
    {"reminder", "clock", 0.96, NO, 0},
    {"rocket", "paperplane", 0.86, NO, 0},
    {"search", "magnifyingglass", 0.89, NO, 0},
    {"section", "folder", 0.75, NO, 0},
    {"send", "paperplane", 0.85, NO, 0},
    {"send-filled", "paperplane.fill", 0.86, NO, 45},
    {"settings", "gearshape", 0.91, NO, 0},
    {"share-message", "arrowshape.turn.up.right", 0.85, NO, 0},
    {"sidebar-left", "sidebar.left", 0.85, NO, 0},
    {"slack-logo", "square.grid.2x2", 0.90, NO, 0},
    {"slash-box", "square.slash", 0.85, NO, 0},
    {"sound", "waveform", 0.85, NO, 0},
    {"sound-off", "speaker.slash", 0.90, NO, 0},
    {"sound-up", "speaker.wave.3", 0.90, NO, 0},
    {"spreadsheet", "tablecells", 0.85, NO, 0},
    {"star", "star", 0.86, NO, 0},
    {"status-member", "circle", 0.45, NO, 0},
    {"status-member-dnd", "moon.circle", 0.60, NO, 0},
    {"status-member-dnd-filled", "moon.circle.fill", 0.60, NO, 0},
    {"status-member-filled", "circle.fill", 0.45, NO, 0},
    {"strikethrough", "strikethrough", 0.81, NO, 0},
    {"text", "textformat", 0.57, NO, 0},
    {"text-snippet", "text.badge.plus", 0.85, NO, 0},
    {"threads", "text.bubble", 0.93, NO, 0},
    {"trash", "trash", 0.88, NO, 0},
    {"underline", "underline", 0.85, NO, 0},
    {"user", "person", 0.82, NO, 0},
    {"user-add", "person.badge.plus", 0.91, NO, 0},
    {"user-hide", "person.badge.minus", 0.91, NO, 0},
    {"vip", "star.circle", 0.90, NO, 0},
    {"vip-filled", "star.circle.fill", 0.90, NO, 0},
    {"user-directory", "person.crop.square", 0.85, NO, 0},
    {"user-groups", "person.2", 0.92, NO, 0},
    {"video", "video", 0.88, NO, 0},
    {"warning", "exclamationmark.triangle", 0.94, NO, 0},
    {"warning-filled", "exclamationmark.triangle.fill", 0.94, NO, 0},
    {"zip", "doc.zipper", 0.81, NO, 0},
};

NSArray<NSString *> *SNIconNames(void) {
    NSMutableArray *names = [NSMutableArray array];
    for (size_t i = 0; i < sizeof kStandIns / sizeof *kStandIns; i++) [names addObject:@(kStandIns[i].name)];
    return names;
}

static const SNIconStandIn *StandIn(NSString *name) {
    const char *key = name.UTF8String;
    for (size_t i = 0; i < sizeof kStandIns / sizeof *kStandIns; i++)
        if (!strcmp(kStandIns[i].name, key)) return &kStandIns[i];
    return NULL;
}

static void DrawStandIn(const SNIconStandIn *standIn, CGContextRef context, CGFloat side, SNColorToken color) {
    CGFloat glyph = side * standIn->fit;
    NSImageSymbolConfiguration *configuration = [NSImageSymbolConfiguration configurationWithPointSize:glyph
                                                                                                weight:standIn->bold ? NSFontWeightBold : NSFontWeightRegular];
    NSImage *image = [[NSImage imageWithSystemSymbolName:@(standIn->symbol) accessibilityDescription:nil] imageWithSymbolConfiguration:configuration];
    if (!image) return;
    CGFloat fit = glyph / MAX(image.size.width, image.size.height);
    CGSize size = CGSizeMake(image.size.width * fit, image.size.height * fit);
    CGContextTranslateCTM(context, side / 2, side / 2);
    CGContextRotateCTM(context, -standIn->turn * M_PI / 180);
    CGContextTranslateCTM(context, -side / 2, -side / 2);
    NSGraphicsContext *previous = NSGraphicsContext.currentContext;
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithCGContext:context flipped:NO];
    [image drawInRect:NSMakeRect((side - size.width) / 2, (side - size.height) / 2, size.width, size.height)];
    NSGraphicsContext.currentContext = previous;
    // Symbols are templates: their alpha is the shape, so the colour fills what they cover.
    CGContextSetBlendMode(context, kCGBlendModeSourceIn);
    CGContextSetFillColorWithColor(context, SNCGColor(color));
    CGContextFillRect(context, CGRectMake(0, 0, side, side));
}

#pragma mark - Images

CGImageRef SNIconImage(NSString *name, CGFloat size, SNColorToken color, CGFloat scale) {
    static NSCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSCache new]; });
    NSString *key = [NSString stringWithFormat:@"%@/%g/%08x/%g", name, size, color, scale];
    id cached = [cache objectForKey:key];
    if (cached) return (__bridge CGImageRef)cached;

    // A name missing from the stand-ins draws nothing even with Slack's outlines, so a public
    // checkout never lacks an icon the private build shows.
    const SNIconStandIn *standIn = StandIn(name);
    SNIconOutline *outline = standIn && SNHasSlackIcons() ? Outline(name) : nil;
    if (!standIn || (SNHasSlackIcons() && !outline)) return NULL;
    size_t side = (size_t)ceil(size * scale);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(NULL, side, side, 8, 0, space, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    if (!context) return NULL;
    if (outline) DrawOutline(outline, context, side, color);
    else DrawStandIn(standIn, context, side, color);
    CGImageRef image = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    if (!image) return NULL;
    [cache setObject:(__bridge_transfer id)image forKey:key];
    return image;
}

void SNDrawIcon(NSString *name, CGFloat size, SNColorToken color, NSRect rect) {
    CGImageRef image = SNIconImage(name, size, color, kImageScale);
    if (!image) return;
    CGRect box = CGRectMake(NSMidX(rect) - size / 2, NSMidY(rect) - size / 2, size, size);
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    CGContextSaveGState(context);
    // Images draw upright only in an unflipped space.
    if (NSGraphicsContext.currentContext.isFlipped) {
        CGContextTranslateCTM(context, 0, CGRectGetMaxY(box) + CGRectGetMinY(box));
        CGContextScaleCTM(context, 1, -1);
    }
    CGContextDrawImage(context, box, image);
    CGContextRestoreGState(context);
}

@implementation SNIconLayer

+ (instancetype)iconNamed:(NSString *)name size:(CGFloat)size color:(SNColorToken)color {
    SNIconLayer *icon = [self layer];
    icon.iconSize = size;
    icon.color = color;
    icon.iconName = name;
    return icon;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    self.contentsGravity = kCAGravityCenter;
    self.contentsScale = kImageScale;
    return self;
}

- (void)setIconName:(NSString *)iconName {
    _iconName = [iconName copy];
    [self updateImage];
}

- (void)setIconSize:(CGFloat)iconSize {
    _iconSize = iconSize;
    [self updateImage];
}

- (void)setColor:(SNColorToken)color {
    _color = color;
    [self updateImage];
}

- (void)updateImage {
    BOOL drawable = self.iconName && self.iconSize > 0;
    self.contents = drawable ? (__bridge id)SNIconImage(self.iconName, self.iconSize, self.color, kImageScale) : nil;
}

@end
