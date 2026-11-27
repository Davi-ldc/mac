// Owns inline text building, block layout, drawing and hit testing of rendered content.
#import <CoreText/CoreText.h>

#import "render/document.h"
#import "render/emoji.h"
#import "render/icon.h"
#import "render/images.h"

const SNTextStyle SNTextStyleBody = {SNFontSizeBase, SNFontWeightRegular, 22, SNLegacyPrimaryForeground};

/// components.json mrkdwn: inline code is Roboto Mono 12 #e8912d with padding 2 3 1 and a 1 pt
/// border; mention chips have padding 1 2; emoji are 22 pt (32 in emoji-only messages).
static const CGFloat kCodePadX = 3 + 1, kCodePadTop = 2 + 1, kCodePadBottom = 1 + 1, kChipPadX = 2, kChipPad = 1;
static const CGFloat kEmojiSize = 22, kJumboEmojiSize = 32, kJumboLineHeight = 36;
static const SNColorToken kCodeFill = 0xe8e8e80a, kCodeBorder = 0xe8e8e821, kCodeText = 0xe8912dff;
static const SNColorToken kMentionHoverFill = 0x1d9bd133;
/// An empty line between paragraphs of a message is an 8 pt block (c-mrkdwn__br).
static const CGFloat kParagraphBreak = 8;
/// List items: 28 pt per level, the marker centred in a 22 pt box 28 pt left of the text.
static const CGFloat kListIndent = 28, kMarkerBox = 22;

static NSString *const kTargetKey = @"SNTarget", *const kChipKey = @"SNChip", *const kLineKey = @"SNLine";
static NSString *const kImageKey = @"SNImage", *const kIconKey = @"SNIcon";
/// What a custom emoji's picture reads as in plain text (":name:").
static NSString *const kAltKey = @"SNAlt";
static const NSUInteger kUnderline = 1, kStrike = 2;

@implementation SNRenderTarget

+ (instancetype)targetWithKind:(SNRenderTargetKind)kind value:(NSString *)value { return [self targetWithKind:kind value:value detail:nil]; }

+ (instancetype)targetWithKind:(SNRenderTargetKind)kind value:(NSString *)value detail:(NSString *)detail {
    SNRenderTarget *target = [self new];
    target->_kind = kind;
    target->_value = [value copy];
    target->_detail = [detail copy];
    return target;
}

- (BOOL)isEqual:(SNRenderTarget *)other {
    return [other isKindOfClass:SNRenderTarget.class] && other.kind == self.kind && [other.value isEqualToString:self.value];
}

- (NSUInteger)hash { return self.value.hash ^ (NSUInteger)self.kind; }

@end

#pragma mark Inline pieces

/// The background behind a run of text: mention chips, code spans, link chips.
@interface SNChip : NSObject
@property (nonatomic) SNColorToken fill, hoverFill, border, color, hoverColor;
@property (nonatomic) CGFloat radius, ascent, descent, padTop, padBottom;
@end

@implementation SNChip
@end

@interface SNInlineImage : NSObject
@property (nonatomic) NSURL *url;
@property (nonatomic) CGFloat size, radius;
@end

@implementation SNInlineImage
@end

@interface SNInlineIcon : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic) CGFloat size, inset;
@property (nonatomic) SNColorToken color;
@end

@implementation SNInlineIcon
@end

typedef struct {
    CGFloat width, ascent, descent;
} SNRunMetrics;

static void DelegateDealloc(void *ref) { free(ref); }
static CGFloat DelegateAscent(void *ref) { return ((SNRunMetrics *)ref)->ascent; }
static CGFloat DelegateDescent(void *ref) { return ((SNRunMetrics *)ref)->descent; }
static CGFloat DelegateWidth(void *ref) { return ((SNRunMetrics *)ref)->width; }

/// An object replacement character that takes `width` in the line: inline padding, pictures.
static NSAttributedString *Placeholder(CGFloat width, CGFloat ascent, CGFloat descent, NSDictionary *attributes) {
    static const CTRunDelegateCallbacks callbacks = {kCTRunDelegateVersion1, DelegateDealloc, DelegateAscent, DelegateDescent, DelegateWidth};
    SNRunMetrics *metrics = malloc(sizeof *metrics);
    *metrics = (SNRunMetrics){width, ascent, descent};
    CTRunDelegateRef delegate = CTRunDelegateCreate(&callbacks, metrics);
    NSMutableDictionary *all = [attributes mutableCopy];
    all[(__bridge NSString *)kCTRunDelegateAttributeName] = (__bridge_transfer id)delegate;
    return [[NSAttributedString alloc] initWithString:@"￼" attributes:all];
}

/// Apple Color Emoji draws its glyphs 1.25 em wide (more at some sizes); the size that makes
/// them `box` points wide is measured once.
NSFont *SNEmojiFont(CGFloat box) {
    static CGFloat perPoint;
    static NSMutableDictionary<NSNumber *, NSFont *> *fonts;
    if (!perPoint) {
        CTFontRef probe = CTFontCreateWithName(CFSTR("AppleColorEmoji"), 100, NULL);
        UniChar characters[2];
        [@"😀" getCharacters:characters range:NSMakeRange(0, 2)];
        CGGlyph glyphs[2] = {0};
        CTFontGetGlyphsForCharacters(probe, characters, glyphs, 2);
        CGSize advance;
        CTFontGetAdvancesForGlyphs(probe, kCTFontOrientationHorizontal, glyphs, &advance, 1);
        perPoint = advance.width > 0 ? advance.width / 100 : 1.25;
        CFRelease(probe);
        fonts = [NSMutableDictionary new];
    }
    CGFloat size = round(box / perPoint * 2) / 2;
    NSNumber *key = @(size);
    NSFont *font = fonts[key];
    if (!font) {
        font = (__bridge_transfer NSFont *)CTFontCreateWithName(CFSTR("AppleColorEmoji"), size, NULL);
        if (font) fonts[key] = font;
    }
    return font;
}

/// Pickers and pills draw the same few hundred emoji over and over: one line per emoji and box.
static CTLineRef EmojiLine(NSString *text, CGFloat box) {
    static NSMutableDictionary<NSNumber *, NSCache *> *caches;
    if (!caches) caches = [NSMutableDictionary new];
    NSCache *cache = caches[@(box)];
    if (!cache) {
        cache = caches[@(box)] = [NSCache new];
        cache.countLimit = 600;
    }
    id line = [cache objectForKey:text];
    if (!line) {
        NSAttributedString *string = [[NSAttributedString alloc] initWithString:text attributes:@{NSFontAttributeName : SNEmojiFont(box)}];
        line = CFBridgingRelease(CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)string));
        [cache setObject:line forKey:text];
    }
    return (__bridge CTLineRef)line;
}

BOOL SNDrawEmoji(NSString *name, CGFloat box, NSRect rect, SNImageHolder *images) {
    NSGraphicsContext *graphics = NSGraphicsContext.currentContext;
    CGContextRef context = graphics.CGContext;
    BOOL flipped = graphics.isFlipped;
    NSString *unicode = SNEmojiUnicode(name);
    if (unicode) {
        if (!context) return YES;
        CTLineRef line = EmojiLine(unicode, box);
        CGFloat ascent = 0, descent = 0, width = CTLineGetTypographicBounds(line, &ascent, &descent, NULL), middle = (ascent - descent) / 2;
        CGContextSaveGState(context);
        CGContextSetTextMatrix(context, flipped ? CGAffineTransformMakeScale(1, -1) : CGAffineTransformIdentity);
        CGContextSetTextPosition(context, NSMidX(rect) - width / 2, flipped ? NSMidY(rect) + middle : NSMidY(rect) - middle);
        CTLineDraw(line, context);
        CGContextRestoreGState(context);
        return YES;
    }
    NSURL *url = SNCustomEmojiURL(name);
    if (!url) return NO;
    if (!context) return YES;
    CGFloat pixels = box * (fabs(CGContextConvertSizeToDeviceSpace(context, CGSizeMake(1, 1)).width) ?: 2);
    CGImageRef image = [images imageWithURL:url pixels:pixels];
    if (!image) return YES;
    // Contained in the box, like Slack's object-fit on custom emoji.
    CGFloat width = CGImageGetWidth(image), height = CGImageGetHeight(image), scale = box / MAX(1, MAX(width, height));
    NSRect target = NSMakeRect(NSMidX(rect) - width * scale / 2, NSMidY(rect) - height * scale / 2, width * scale, height * scale);
    CGContextSaveGState(context);
    if (flipped) {
        CGContextTranslateCTM(context, 0, NSMaxY(target) + NSMinY(target));
        CGContextScaleCTM(context, 1, -1);
    }
    CGContextDrawImage(context, target, image);
    CGContextRestoreGState(context);
    return YES;
}

@implementation SNInlineText {
    NSMutableAttributedString *_text;
}

- (instancetype)initWithStyle:(SNTextStyle)style {
    if (!(self = [super init])) return nil;
    _style = style;
    _text = [NSMutableAttributedString new];
    return self;
}

- (NSUInteger)length { return _text.length; }

- (NSFont *)fontFor:(SNInlineStyle)style {
    if (self.monospaced) return SNMonoFont(self.style.size, style & SNInlineBold ? SNFontWeightBold : SNFontWeightRegular);
    if (style & SNInlineCode) return SNMonoFont(round(self.style.size * 0.8), SNFontWeightRegular);
    CGFloat weight = style & SNInlineBold ? MAX(SNFontWeightBold, self.style.weight) : self.style.weight;
    return style & SNInlineItalic ? SNItalicFont(self.style.size, weight) : SNFont(self.style.size, weight);
}

- (NSMutableDictionary *)attributesFor:(SNInlineStyle)style color:(SNColorToken)color {
    NSMutableDictionary *attributes = [NSMutableDictionary new];
    attributes[NSFontAttributeName] = [self fontFor:style];
    attributes[(__bridge NSString *)kCTForegroundColorAttributeName] = (__bridge id)SNCGColor(color);
    NSUInteger lines = (style & SNInlineUnderline ? kUnderline : 0) | (style & SNInlineStrike ? kStrike : 0);
    if (lines) attributes[kLineKey] = @(lines);
    return attributes;
}

- (void)appendText:(NSString *)text style:(SNInlineStyle)style {
    [self appendText:text style:style target:nil];
}

- (void)appendText:(NSString *)text style:(SNInlineStyle)style target:(SNRenderTarget *)target {
    if (!text.length) return;
    if (style & SNInlineCode && !self.monospaced) {
        [self appendCode:text style:style];
        return;
    }
    SNColorToken color = target ? SNColorContentHgl1 : self.style.color;
    NSMutableDictionary *attributes = [self attributesFor:style color:color];
    if (target) attributes[kTargetKey] = target;
    [_text appendAttributedString:[[NSAttributedString alloc] initWithString:text attributes:attributes]];
}

/// A code span: its own chip, with the padding and border as space either side.
- (void)appendCode:(NSString *)text style:(SNInlineStyle)style {
    NSMutableDictionary *attributes = [self attributesFor:style color:kCodeText];
    NSFont *font = attributes[NSFontAttributeName];
    SNChip *chip = [SNChip new];
    chip.fill = kCodeFill, chip.border = kCodeBorder, chip.radius = 3;
    chip.ascent = font.ascender, chip.descent = -font.descender, chip.padTop = kCodePadTop, chip.padBottom = kCodePadBottom;
    attributes[kChipKey] = chip;
    [_text appendAttributedString:Placeholder(kCodePadX, 0, 0, @{kChipKey : chip})];
    [_text appendAttributedString:[[NSAttributedString alloc] initWithString:text attributes:attributes]];
    [_text appendAttributedString:Placeholder(kCodePadX, 0, 0, @{kChipKey : chip})];
}

- (void)appendLink:(NSURL *)url text:(NSString *)text style:(SNInlineStyle)style {
    [self appendText:text.length ? text : url.absoluteString style:style target:[SNRenderTarget targetWithKind:SNRenderTargetLink value:url.absoluteString]];
}

- (SNChip *)mentionChipOwn:(BOOL)own font:(NSFont *)font {
    SNChip *chip = [SNChip new];
    chip.fill = own ? SNColorSurfHgl3 : SNColorSurfHgl1;
    chip.color = own ? SNColorContentHgl3 : SNColorContentHgl1;
    // Mentions of the user, @here and @channel stay as they are under the pointer.
    chip.hoverFill = own ? 0 : kMentionHoverFill;
    chip.hoverColor = own ? 0 : SNLegacyHighlightHover;
    chip.radius = 3;
    chip.ascent = font.ascender, chip.descent = -font.descender, chip.padTop = chip.padBottom = kChipPad;
    return chip;
}

- (void)appendMention:(NSString *)name target:(SNRenderTarget *)target own:(BOOL)own {
    SNInlineStyle style = target.kind == SNRenderTargetBroadcast ? SNInlineBold : 0;
    NSMutableDictionary *attributes = [self attributesFor:style color:0];
    SNChip *chip = [self mentionChipOwn:own font:attributes[NSFontAttributeName]];
    // Drawn in the chip's colour, which changes under the pointer without laying out again.
    [attributes removeObjectForKey:(__bridge NSString *)kCTForegroundColorAttributeName];
    attributes[(__bridge NSString *)kCTForegroundColorFromContextAttributeName] = @YES;
    attributes[kChipKey] = chip;
    attributes[kTargetKey] = target;
    [_text appendAttributedString:Placeholder(kChipPadX, 0, 0, @{kChipKey : chip, kTargetKey : target})];
    [_text appendAttributedString:[[NSAttributedString alloc] initWithString:name attributes:attributes]];
    [_text appendAttributedString:Placeholder(kChipPadX, 0, 0, @{kChipKey : chip, kTargetKey : target})];
}

- (void)appendLinkChip:(NSURL *)url {
    SNRenderTarget *target = [SNRenderTarget targetWithKind:SNRenderTargetLink value:url.absoluteString];
    NSMutableDictionary *attributes = [self attributesFor:0 color:SNColorContentHgl1];
    SNChip *chip = [self mentionChipOwn:NO font:attributes[NSFontAttributeName]];
    chip.hoverFill = chip.hoverColor = 0;
    attributes[kChipKey] = chip;
    attributes[kTargetKey] = target;
    SNInlineIcon *icon = [SNInlineIcon new];
    // The icon has no size of its own: it takes the message's 15 px.
    icon.name = @"link", icon.size = 15, icon.inset = 0, icon.color = SNColorContentHgl1;
    [_text appendAttributedString:Placeholder(kChipPadX, 0, 0, @{kChipKey : chip, kTargetKey : target})];
    [_text appendAttributedString:Placeholder(19.5, 0, 0, @{kChipKey : chip, kTargetKey : target, kIconKey : icon})];
    NSString *shown = url.absoluteString;
    for (NSString *scheme in @[ @"https://", @"http://" ])
        if ([shown hasPrefix:scheme]) shown = [shown substringFromIndex:scheme.length];
    [_text appendAttributedString:[[NSAttributedString alloc] initWithString:shown attributes:attributes]];
    [_text appendAttributedString:Placeholder(kChipPadX, 0, 0, @{kChipKey : chip, kTargetKey : target})];
}

- (void)appendEmoji:(NSString *)name fallbackUnicode:(NSString *)unicode {
    CGFloat box = self.jumbo ? kJumboEmojiSize : kEmojiSize;
    NSString *text = SNEmojiUnicode(name);
    NSURL *image = text ? nil : SNCustomEmojiURL(name);
    if (image) {
        SNInlineImage *picture = [SNInlineImage new];
        picture.url = image, picture.size = box;
        [_text appendAttributedString:Placeholder(box, 0, 0, @{kImageKey : picture, kAltKey : [NSString stringWithFormat:@":%@:", name]})];
        return;
    }
    text = text ?: (unicode ? SNTextFromCodePoints(unicode) : nil);
    if (!text) {
        [self appendText:[NSString stringWithFormat:@":%@:", name] style:0];
        return;
    }
    NSDictionary *attributes = @{NSFontAttributeName : SNEmojiFont(box)};
    [_text appendAttributedString:[[NSAttributedString alloc] initWithString:text attributes:attributes]];
}

- (void)appendIcon:(NSString *)name size:(CGFloat)size color:(SNColorToken)color target:(SNRenderTarget *)target {
    SNInlineIcon *icon = [SNInlineIcon new];
    icon.name = name, icon.size = size, icon.inset = 0, icon.color = color;
    NSMutableDictionary *attributes = [@{kIconKey : icon} mutableCopy];
    if (target) attributes[kTargetKey] = target;
    [_text appendAttributedString:Placeholder(size, 0, 0, attributes)];
}

- (void)appendImage:(NSURL *)url size:(CGFloat)size radius:(CGFloat)radius {
    SNInlineImage *image = [SNInlineImage new];
    image.url = url, image.size = size, image.radius = radius;
    [_text appendAttributedString:Placeholder(size, 0, 0, @{kImageKey : image})];
}

- (NSAttributedString *)attributedText {
    NSMutableAttributedString *text = [_text mutableCopy];
    while (text.length && [text.string characterAtIndex:text.length - 1] == '\n') [text deleteCharactersInRange:NSMakeRange(text.length - 1, 1)];
    return text;
}

- (SNParagraphBlock *)paragraph {
    SNTextStyle style = self.style;
    if (self.jumbo) style.lineHeight = kJumboLineHeight;
    return [SNParagraphBlock paragraphWithText:self.attributedText style:style];
}

@end

#pragma mark Layout

@interface SNLaidLine : NSObject {
  @public
    id line;
    CGPoint origin;
}
@end

@implementation SNLaidLine
@end

/// A rectangle drawn under the text: code block boxes, quote and attachment bars, card
/// borders, dividers, buttons, image placeholders.
@interface SNLaidBox : NSObject {
  @public
    CGRect rect;
    SNColorToken fill, border;
    CGFloat radius;
}
@end

@implementation SNLaidBox
@end

/// A piece of the layout: a chip, a picture, a glyph or a stretch of text with a target.
@interface SNLaidPiece : NSObject {
  @public
    CGRect rect;
    CGFloat baseline;
    SNRenderTarget *target;
    SNChip *chip;
    SNInlineImage *image;
    SNInlineIcon *icon;
    NSUInteger lines;
    SNColorToken color;
}
@end

@implementation SNLaidPiece
@end

@interface SNRenderLayout () {
  @public
    NSMutableArray<SNLaidLine *> *_lines;
    NSMutableArray<SNLaidBox *> *_boxes;
    NSMutableArray<SNLaidPiece *> *_pieces;
    CGSize _size;
}
@end

@interface SNRenderBlock ()
/// Adds the block's pieces at (x, y) in `width` and returns its height.
- (CGFloat)layoutIn:(SNRenderLayout *)layout x:(CGFloat)x y:(CGFloat)y width:(CGFloat)width;
- (void)appendPlainText:(NSMutableString *)text;
@end

static SNLaidBox *AddBox(SNRenderLayout *layout, CGRect rect, SNColorToken fill, SNColorToken border, CGFloat radius) {
    SNLaidBox *box = [SNLaidBox new];
    box->rect = rect, box->fill = fill, box->border = border, box->radius = radius;
    [layout->_boxes addObject:box];
    return box;
}

static SNColorToken TokenOf(CGColorRef color) {
    if (!color) return 0;
    const CGFloat *c = CGColorGetComponents(color);
    if (CGColorGetNumberOfComponents(color) < 4) return 0;
    return (SNColorToken)lround(c[0] * 255) << 24 | (SNColorToken)lround(c[1] * 255) << 16 | (SNColorToken)lround(c[2] * 255) << 8 |
           (SNColorToken)lround(c[3] * 255);
}

/// Records what the line's runs carry: targets, chips, pictures, glyphs, underlines. Neighbouring
/// runs of the same target or chip become one piece.
static void CollectPieces(SNRenderLayout *layout, CTLineRef line, CGPoint origin, CGFloat lineTop, CGFloat lineHeight) {
    SNLaidPiece *previous = nil;
    for (id object in (__bridge NSArray *)CTLineGetGlyphRuns(line)) {
        CTRunRef run = (__bridge CTRunRef)object;
        NSDictionary *attributes = (__bridge NSDictionary *)CTRunGetAttributes(run);
        SNRenderTarget *target = attributes[kTargetKey];
        SNChip *chip = attributes[kChipKey];
        SNInlineImage *image = attributes[kImageKey];
        SNInlineIcon *icon = attributes[kIconKey];
        NSUInteger lines = [attributes[kLineKey] unsignedIntegerValue];
        if (!target && !chip && !image && !icon && !lines) {
            previous = nil;
            continue;
        }
        CGPoint position = CGPointZero;
        CTRunGetPositions(run, CFRangeMake(0, 1), &position);
        CGFloat width = CTRunGetTypographicBounds(run, CFRangeMake(0, 0), NULL, NULL, NULL);
        CGRect rect = CGRectMake(origin.x + position.x, lineTop, width, lineHeight);
        if (image || icon) {
            CGFloat size = image ? image.size : lineHeight;
            rect = CGRectMake(rect.origin.x, lineTop + (lineHeight - size) / 2, width, size);
        }
        if (previous && !image && !icon && !previous->image && !previous->icon && previous->target == target && previous->chip == chip &&
            previous->lines == lines) {
            previous->rect = CGRectUnion(previous->rect, rect);
            continue;
        }
        SNLaidPiece *piece = [SNLaidPiece new];
        piece->rect = rect, piece->baseline = origin.y, piece->target = target, piece->chip = chip, piece->image = image;
        piece->icon = icon, piece->lines = lines;
        piece->color = TokenOf((__bridge CGColorRef)attributes[(__bridge NSString *)kCTForegroundColorAttributeName]);
        [layout->_pieces addObject:piece];
        previous = image || icon ? nil : piece;
    }
}

/// Breaks `text` into lines `width` wide from (x, y) and returns the height used.
static CGFloat LayoutText(SNRenderLayout *layout, NSAttributedString *text, SNTextStyle style, CGFloat x, CGFloat y, CGFloat width) {
    if (!text.length) return 0;
    CTTypesetterRef typesetter = CTTypesetterCreateWithAttributedString((__bridge CFAttributedStringRef)text);
    NSFont *font = SNFont(style.size, style.weight);
    CGFloat baseline = SNBaselineOffset(font, style.lineHeight), top = y;
    NSString *string = text.string;
    CFIndex start = 0, length = (CFIndex)text.length;
    while (start < length) {
        CFIndex count = MAX(1, CTTypesetterSuggestLineBreak(typesetter, start, MAX(1, width)));
        if ([string characterAtIndex:(NSUInteger)start] == '\n' && start > 0) {
            // A line holding only the break: the empty line between paragraphs.
            top += kParagraphBreak;
            start += 1;
            continue;
        }
        CTLineRef line = CTTypesetterCreateLine(typesetter, CFRangeMake(start, count));
        SNLaidLine *laid = [SNLaidLine new];
        laid->line = CFBridgingRelease(line);
        laid->origin = CGPointMake(x, top + baseline);
        [layout->_lines addObject:laid];
        CollectPieces(layout, line, laid->origin, top, style.lineHeight);
        top += style.lineHeight;
        start += count;
    }
    CFRelease(typesetter);
    return top - y;
}

static CGFloat LayoutBlocks(NSArray<SNRenderBlock *> *blocks, SNRenderLayout *layout, CGFloat x, CGFloat y, CGFloat width) {
    CGFloat top = y, after = -1;
    for (SNRenderBlock *block in blocks) {
        if (after >= 0) top += MAX(after, block.spaceBefore);
        top += [block layoutIn:layout x:x y:top width:width];
        after = block.spaceAfter;
    }
    return top - y;
}

static void AppendPlain(NSArray<SNRenderBlock *> *blocks, NSMutableString *text) {
    for (SNRenderBlock *block in blocks) {
        if (text.length && ![text hasSuffix:@"\n"]) [text appendString:@"\n"];
        [block appendPlainText:text];
    }
}

@implementation SNRenderBlock
- (CGFloat)layoutIn:(SNRenderLayout *)layout x:(CGFloat)x y:(CGFloat)y width:(CGFloat)width { return 0; }
- (void)appendPlainText:(NSMutableString *)text {}
@end

@implementation SNParagraphBlock

+ (instancetype)paragraphWithText:(NSAttributedString *)text style:(SNTextStyle)style {
    SNParagraphBlock *block = [self new];
    block->_text = [text copy];
    block->_style = style;
    return block;
}

- (CGFloat)layoutIn:(SNRenderLayout *)layout x:(CGFloat)x y:(CGFloat)y width:(CGFloat)width {
    CGFloat height = LayoutText(layout, self.text, self.style, x + self.indent, y, width - self.indent);
    if (self.marker.length) {
        NSDictionary *attributes = @{NSFontAttributeName : SNFont(self.style.size, self.style.weight),
                                     (__bridge NSString *)kCTForegroundColorAttributeName : (__bridge id)SNCGColor(self.style.color)};
        CTLineRef marker = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)[[NSAttributedString alloc] initWithString:self.marker attributes:attributes]);
        CGFloat markerWidth = CTLineGetTypographicBounds(marker, NULL, NULL, NULL);
        SNLaidLine *laid = [SNLaidLine new];
        laid->line = CFBridgingRelease(marker);
        CGFloat box = x + self.indent - kListIndent;
        laid->origin = CGPointMake(box + (kMarkerBox - markerWidth) / 2, y + SNBaselineOffset(attributes[NSFontAttributeName], self.style.lineHeight));
        [layout->_lines addObject:laid];
        height = MAX(height, self.style.lineHeight);
    }
    return height;
}

- (void)appendPlainText:(NSMutableString *)text {
    if (self.marker) [text appendFormat:@"%@ ", self.marker];
    // Chips' padding and inline pictures hold their place with U+FFFC, which is no text; a custom
    // emoji's reads as its name, one per character.
    NSString *string = self.text.string;
    [self.text enumerateAttribute:kAltKey inRange:NSMakeRange(0, string.length) options:0 usingBlock:^(NSString *alt, NSRange range, BOOL *stop) {
        if (alt) [text appendString:[@"" stringByPaddingToLength:alt.length * range.length withString:alt startingAtIndex:0]];
        else [text appendString:[[string substringWithRange:range] stringByReplacingOccurrencesOfString:@"\uFFFC" withString:@""]];
    }];
}

@end

@implementation SNCodeBlock

+ (instancetype)codeBlockWithText:(NSAttributedString *)text {
    SNCodeBlock *block = [self new];
    block->_text = [text copy];
    block.spaceBefore = block.spaceAfter = 4;
    return block;
}

- (CGFloat)layoutIn:(SNRenderLayout *)layout x:(CGFloat)x y:(CGFloat)y width:(CGFloat)width {
    static const CGFloat padding = 8;
    SNTextStyle style = {12, SNFontWeightRegular, 18, SNLegacyPrimaryForeground};
    SNLaidBox *box = AddBox(layout, CGRectZero, kCodeFill, kCodeBorder, SNRadiusBase);
    // The code's own font sets the baseline; SNFont would place it for Lato.
    NSUInteger first = layout->_lines.count;
    CGFloat height = LayoutText(layout, self.text, style, x + padding + 1, y + padding + 1, width - 2 * padding - 2);
    NSFont *mono = SNMonoFont(12, SNFontWeightRegular);
    CGFloat shift = SNBaselineOffset(mono, 18) - SNBaselineOffset(SNFont(12, SNFontWeightRegular), 18);
    for (NSUInteger i = first; i < layout->_lines.count; i++) layout->_lines[i]->origin.y += shift;
    height = MAX(height, 18) + 2 * padding + 2;
    box->rect = CGRectMake(x, y, width, height);
    return height;
}

- (void)appendPlainText:(NSMutableString *)text { [text appendFormat:@"```%@```", self.text.string]; }

@end

typedef NS_ENUM(NSInteger, SNGroupKind) { SNGroupQuote, SNGroupAttachment, SNGroupCard, SNGroupSection };

@implementation SNGroupBlock {
    SNGroupKind _kind;
    SNColorToken _barColor;
}

+ (instancetype)groupWithBlocks:(NSArray *)blocks kind:(SNGroupKind)kind {
    SNGroupBlock *block = [self new];
    block->_blocks = [blocks copy];
    block->_kind = kind;
    block->_sideImageSize = 75;
    return block;
}

+ (instancetype)quoteWithBlocks:(NSArray<SNRenderBlock *> *)blocks {
    SNGroupBlock *block = [self groupWithBlocks:blocks kind:SNGroupQuote];
    block.spaceBefore = block.spaceAfter = 4;
    return block;
}

+ (instancetype)attachmentWithBlocks:(NSArray<SNRenderBlock *> *)blocks barColor:(SNColorToken)color {
    SNGroupBlock *block = [self groupWithBlocks:blocks kind:SNGroupAttachment];
    block->_barColor = color;
    block.maximumWidth = 600;
    block.spaceBefore = 8;
    return block;
}

+ (instancetype)cardWithBlocks:(NSArray<SNRenderBlock *> *)blocks {
    SNGroupBlock *block = [self groupWithBlocks:blocks kind:SNGroupCard];
    block.maximumWidth = 716;
    block.spaceBefore = 8;
    return block;
}

+ (instancetype)sectionWithBlocks:(NSArray<SNRenderBlock *> *)blocks { return [self groupWithBlocks:blocks kind:SNGroupSection]; }

- (CGFloat)layoutIn:(SNRenderLayout *)layout x:(CGFloat)x y:(CGFloat)y width:(CGFloat)width {
    if (self.maximumWidth > 0) width = MIN(width, self.maximumWidth);
    // Quotes: 4 pt bar, text 16 pt in. Attachments: 4 pt bar, body padded 12. Cards: 1 pt
    // border, 12 pt padding, radius 12. Sections: no frame.
    CGFloat inset = _kind == SNGroupCard ? 13 : _kind == SNGroupSection ? 0 : 16;
    CGFloat trailing = _kind == SNGroupCard ? 13 : 0, pad = _kind == SNGroupCard ? 13 : 0;
    CGFloat side = self.sideImage ? self.sideImageSize + 12 : 0;
    SNLaidBox *frame = _kind == SNGroupCard      ? AddBox(layout, CGRectZero, 0, SNColorOtlTer, SNRadiusXlarge)
                       : _kind == SNGroupSection ? nil
                                                 : AddBox(layout, CGRectZero, _kind == SNGroupQuote ? SNColorContentSec : _barColor, 0, 2);
    CGFloat inner = width - inset - trailing - side;
    CGFloat height = LayoutBlocks(self.blocks, layout, x + inset, y + pad, inner);
    if (self.sideImage) {
        SNLaidPiece *piece = [SNLaidPiece new];
        SNInlineImage *image = [SNInlineImage new];
        image.url = self.sideImage, image.size = self.sideImageSize, image.radius = SNRadiusLarge;
        piece->image = image;
        piece->rect = CGRectMake(x + width - trailing - self.sideImageSize, y + pad + 5, self.sideImageSize, self.sideImageSize);
        [layout->_pieces addObject:piece];
        height = MAX(height, self.sideImageSize + 5);
    }
    height += 2 * pad;
    if (frame) frame->rect = _kind == SNGroupCard ? CGRectMake(x, y, width, height) : CGRectMake(x, y, 4, height);
    return height;
}

- (void)appendPlainText:(NSMutableString *)text { AppendPlain(self.blocks, text); }

@end

@implementation SNColumnsBlock

+ (instancetype)columnsWithCells:(NSArray<SNParagraphBlock *> *)cells {
    SNColumnsBlock *block = [self new];
    block->_cells = [cells copy];
    block.spaceBefore = 8;
    return block;
}

- (CGFloat)layoutIn:(SNRenderLayout *)layout x:(CGFloat)x y:(CGFloat)y width:(CGFloat)width {
    static const CGFloat gap = 16, rowGap = 8;
    CGFloat column = floor((width - gap) / 2), top = y;
    for (NSUInteger i = 0; i < self.cells.count; i += 2) {
        CGFloat left = [self.cells[i] layoutIn:layout x:x y:top width:column];
        CGFloat right = i + 1 < self.cells.count ? [self.cells[i + 1] layoutIn:layout x:x + column + gap y:top width:column] : 0;
        top += MAX(left, right) + (i + 2 < self.cells.count ? rowGap : 0);
    }
    return top - y;
}

- (void)appendPlainText:(NSMutableString *)text { AppendPlain(self.cells, text); }

@end

@implementation SNImageBlock

+ (instancetype)imageWithURL:(NSURL *)url size:(CGSize)size {
    SNImageBlock *block = [self new];
    block->_url = url;
    block->_size = size;
    block.spaceBefore = 8;
    return block;
}

- (CGFloat)layoutIn:(SNRenderLayout *)layout x:(CGFloat)x y:(CGFloat)y width:(CGFloat)width {
    CGSize size = self.size.width > 0 && self.size.height > 0 ? self.size : CGSizeMake(360, 240);
    CGFloat scale = MIN(1, MIN(MIN(width, 480) / size.width, 360 / size.height));
    CGRect rect = CGRectMake(x, y, round(size.width * scale), round(size.height * scale));
    SNLaidPiece *piece = [SNLaidPiece new];
    SNInlineImage *image = [SNInlineImage new];
    image.url = self.url, image.size = rect.size.width, image.radius = SNRadiusLarge;
    piece->image = image;
    piece->rect = rect;
    piece->target = [SNRenderTarget targetWithKind:SNRenderTargetImage value:self.url.absoluteString detail:self.hideKey];
    AddBox(layout, rect, SNColorBaseTer, 0, SNRadiusLarge);
    [layout->_pieces addObject:piece];
    return rect.size.height;
}

@end

@implementation SNDividerBlock

- (instancetype)init {
    if (!(self = [super init])) return nil;
    self.spaceBefore = self.spaceAfter = 8;
    return self;
}

- (CGFloat)layoutIn:(SNRenderLayout *)layout x:(CGFloat)x y:(CGFloat)y width:(CGFloat)width {
    AddBox(layout, CGRectMake(x, y, width, 1), SNLegacyForegroundLowSolid, 0, 0);
    return 1;
}

@end

@implementation SNButtonItem

+ (instancetype)buttonWithTitle:(NSString *)title style:(SNButtonStyle)style target:(SNRenderTarget *)target {
    SNButtonItem *item = [self new];
    item->_title = [title copy];
    item->_style = style;
    item->_target = target;
    return item;
}

@end

@implementation SNButtonsBlock

+ (instancetype)buttonsWithItems:(NSArray<SNButtonItem *> *)items {
    SNButtonsBlock *block = [self new];
    block->_items = [items copy];
    block.spaceBefore = 8;
    return block;
}

/// Slack's small buttons: 28 pt tall, 12 pt padding, 13 pt bold, radius 8, 8 pt apart.
- (CGFloat)layoutIn:(SNRenderLayout *)layout x:(CGFloat)x y:(CGFloat)y width:(CGFloat)width {
    static const CGFloat height = 28, padding = 12, gap = 8;
    NSFont *font = SNFont(SNFontSizeCaption, SNFontWeightBold);
    CGFloat left = x, top = y;
    for (SNButtonItem *item in self.items) {
        SNColorToken fill = item.style == SNButtonStylePrimary ? SNColorBaseInvHgl2 : item.style == SNButtonStyleDanger ? SNColorBaseInvImp : SNColorBasePry;
        NSDictionary *attributes = @{NSFontAttributeName : font, (__bridge NSString *)kCTForegroundColorAttributeName : (__bridge id)SNCGColor(SNColorContentPry)};
        CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)[[NSAttributedString alloc] initWithString:item.title attributes:attributes]);
        CGFloat textWidth = ceil(CTLineGetTypographicBounds(line, NULL, NULL, NULL)), buttonWidth = MIN(width, textWidth + 2 * padding);
        if (left > x && left + buttonWidth > x + width) left = x, top += height + gap;
        CGRect rect = CGRectMake(left, top, buttonWidth, height);
        AddBox(layout, rect, fill, item.style == SNButtonStyleDefault ? SNColorOtlSec : 0, SNRadiusLarge);
        SNLaidLine *laid = [SNLaidLine new];
        laid->line = CFBridgingRelease(line);
        laid->origin = CGPointMake(left + padding, top + SNBaselineOffset(font, height - 1));
        [layout->_lines addObject:laid];
        SNLaidPiece *piece = [SNLaidPiece new];
        piece->rect = rect, piece->target = item.target;
        [layout->_pieces addObject:piece];
        left += buttonWidth + gap;
    }
    return self.items.count ? top + height - y : 0;
}

- (void)appendPlainText:(NSMutableString *)text {
    for (SNButtonItem *item in self.items) [text appendFormat:@"[%@] ", item.title];
}

@end

@implementation SNTableBlock

+ (instancetype)tableWithRows:(NSArray<NSArray<NSAttributedString *> *> *)rows {
    SNTableBlock *block = [self new];
    block->_rows = [rows copy];
    block.spaceBefore = block.spaceAfter = 8;
    return block;
}

- (CGFloat)layoutIn:(SNRenderLayout *)layout x:(CGFloat)x y:(CGFloat)y width:(CGFloat)width {
    static const CGFloat padding = 8;
    NSUInteger columns = 0;
    for (NSArray *row in self.rows) columns = MAX(columns, row.count);
    if (!columns) return 0;
    CGFloat column = floor(width / columns), top = y;
    SNLaidBox *frame = AddBox(layout, CGRectZero, 0, SNLegacyForegroundLowSolid, SNRadiusLarge);
    for (NSUInteger r = 0; r < self.rows.count; r++) {
        CGFloat rowHeight = 0;
        for (NSUInteger c = 0; c < self.rows[r].count; c++)
            rowHeight = MAX(rowHeight, LayoutText(layout, self.rows[r][c], SNTextStyleBody, x + c * column + padding, top + padding, column - 2 * padding));
        rowHeight = MAX(rowHeight, SNTextStyleBody.lineHeight) + 2 * padding;
        if (r) AddBox(layout, CGRectMake(x, top, column * columns, 1), SNLegacyForegroundLowSolid, 0, 0);
        top += rowHeight;
    }
    for (NSUInteger c = 1; c < columns; c++) AddBox(layout, CGRectMake(x + c * column, y, 1, top - y), SNLegacyForegroundLowSolid, 0, 0);
    frame->rect = CGRectMake(x, y, column * columns, top - y);
    return top - y;
}

- (void)appendPlainText:(NSMutableString *)text {
    for (NSArray<NSAttributedString *> *row in self.rows) {
        for (NSAttributedString *cell in row) [text appendFormat:@"%@\t", cell.string];
        [text appendString:@"\n"];
    }
}

@end

@implementation SNRenderDocument

+ (instancetype)documentWithBlocks:(NSArray<SNRenderBlock *> *)blocks {
    SNRenderDocument *document = [self new];
    document->_blocks = [blocks copy];
    return document;
}

- (BOOL)isEmpty { return self.blocks.count == 0; }

- (NSString *)plainText {
    NSMutableString *text = [NSMutableString new];
    AppendPlain(self.blocks, text);
    return text;
}

- (SNRenderLayout *)layoutForWidth:(CGFloat)width {
    SNRenderLayout *layout = [SNRenderLayout new];
    layout->_lines = [NSMutableArray new];
    layout->_boxes = [NSMutableArray new];
    layout->_pieces = [NSMutableArray new];
    CGFloat height = LayoutBlocks(self.blocks, layout, 0, 0, width);
    layout->_size = CGSizeMake(width, ceil(height));
    return layout;
}

@end

@implementation SNRenderLayout

- (NSUInteger)lineCount { return _lines.count; }

static void AddRoundedRect(CGContextRef context, CGRect rect, CGFloat radius) {
    radius = MIN(radius, MIN(rect.size.width, rect.size.height) / 2);
    CGPathRef path = CGPathCreateWithRoundedRect(rect, radius, radius, NULL);
    CGContextAddPath(context, path);
    CGPathRelease(path);
}

static void DrawBox(CGContextRef context, CGRect rect, SNColorToken fill, SNColorToken border, CGFloat radius) {
    if (fill) {
        CGContextSetFillColorWithColor(context, SNCGColor(fill));
        AddRoundedRect(context, rect, radius);
        CGContextFillPath(context);
    }
    if (border) {
        // CSS borders lie inside the box.
        CGContextSetStrokeColorWithColor(context, SNCGColor(border));
        CGContextSetLineWidth(context, 1);
        AddRoundedRect(context, CGRectInset(rect, 0.5, 0.5), MAX(0, radius - 0.5));
        CGContextStrokePath(context);
    }
}

static void DrawImage(CGContextRef context, CGImageRef image, CGRect rect, CGFloat radius) {
    CGContextSaveGState(context);
    if (radius > 0) {
        AddRoundedRect(context, rect, radius);
        CGContextClip(context);
    }
    // Aspect fill, upright in the flipped context.
    CGFloat width = CGImageGetWidth(image), height = CGImageGetHeight(image);
    CGFloat scale = MAX(rect.size.width / width, rect.size.height / height);
    CGRect drawn = CGRectMake(CGRectGetMidX(rect) - width * scale / 2, CGRectGetMidY(rect) - height * scale / 2, width * scale, height * scale);
    CGContextTranslateCTM(context, 0, CGRectGetMinY(drawn) * 2 + drawn.size.height);
    CGContextScaleCTM(context, 1, -1);
    CGContextDrawImage(context, drawn, image);
    CGContextRestoreGState(context);
}

- (void)drawAtPoint:(CGPoint)origin hovered:(SNRenderTarget *)hovered images:(SNImageHolder *)images {
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    if (!context) return;
    CGContextSaveGState(context);
    CGContextTranslateCTM(context, origin.x, origin.y);
    CGFloat scale = CGContextConvertSizeToDeviceSpace(context, CGSizeMake(1, 1)).width ?: 2;
    for (SNLaidBox *box in _boxes) DrawBox(context, box->rect, box->fill, box->border, box->radius);

    NSMutableSet<SNChip *> *hoveredChips = [NSMutableSet new];
    for (SNLaidPiece *piece in _pieces) {
        BOOL isHovered = hovered && [piece->target isEqual:hovered];
        if (piece->chip) {
            SNChip *chip = piece->chip;
            if (isHovered && chip.hoverFill) [hoveredChips addObject:chip];
            CGRect rect = CGRectMake(piece->rect.origin.x, piece->baseline - chip.ascent - chip.padTop, piece->rect.size.width,
                                     chip.ascent + chip.descent + chip.padTop + chip.padBottom);
            DrawBox(context, rect, isHovered && chip.hoverFill ? chip.hoverFill : chip.fill, chip.border, chip.radius);
        }
        if (piece->image) {
            // Decoded by the longer side: a tall picture drawn at its width would be blurry.
            CGFloat pixels = MAX(piece->rect.size.width, piece->rect.size.height) * scale;
            CGImageRef image = [images imageWithURL:piece->image.url pixels:pixels];
            if (image) DrawImage(context, image, piece->rect, piece->image.radius);
        }
        if (piece->icon) {
            SNInlineIcon *icon = piece->icon;
            CGFloat glyph = icon.size;
            SNDrawIcon(icon.name, glyph, icon.color, NSMakeRect(piece->rect.origin.x + icon.inset, CGRectGetMidY(piece->rect) - glyph / 2, glyph, glyph));
        }
    }

    // Slack's text is antialiased without subpixel smoothing; baselines sit on device pixels.
    CGContextSetShouldSmoothFonts(context, false);
    CGContextSetTextMatrix(context, CGAffineTransformMakeScale(1, -1));
    for (SNLaidLine *laid in _lines) {
        CGPoint device = CGContextConvertPointToDeviceSpace(context, laid->origin);
        CGPoint position = CGContextConvertPointToUserSpace(context, CGPointMake(device.x, round(device.y)));
        for (id object in (__bridge NSArray *)CTLineGetGlyphRuns((__bridge CTLineRef)laid->line)) {
            CTRunRef run = (__bridge CTRunRef)object;
            NSDictionary *attributes = (__bridge NSDictionary *)CTRunGetAttributes(run);
            SNChip *chip = attributes[kChipKey];
            if (chip.color) {
                BOOL lit = [hoveredChips containsObject:chip] && chip.hoverColor;
                CGContextSetFillColorWithColor(context, SNCGColor(lit ? chip.hoverColor : chip.color));
            }
            CGContextSetTextPosition(context, position.x, position.y);
            CTRunDraw(run, context, CFRangeMake(0, 0));
        }
    }

    for (SNLaidPiece *piece in _pieces) {
        BOOL hoverLine = hovered && [piece->target isEqual:hovered] && !piece->chip &&
                         (piece->target.kind == SNRenderTargetLink || piece->target.kind == SNRenderTargetChannel);
        if (!piece->lines && !hoverLine) continue;
        CGContextSetFillColorWithColor(context, SNCGColor(piece->color ?: SNColorContentHgl1));
        if (piece->lines & kUnderline || hoverLine) CGContextFillRect(context, CGRectMake(piece->rect.origin.x, piece->baseline + 2, piece->rect.size.width, 1));
        if (piece->lines & kStrike) CGContextFillRect(context, CGRectMake(piece->rect.origin.x, piece->baseline - 5, piece->rect.size.width, 1));
    }
    CGContextRestoreGState(context);
}

- (SNRenderTarget *)targetAtPoint:(CGPoint)point {
    for (SNLaidPiece *piece in _pieces)
        if (piece->target && CGRectContainsPoint(piece->rect, point)) return piece->target;
    return nil;
}

- (NSRect)rectForTarget:(SNRenderTarget *)target {
    NSRect rect = NSZeroRect;
    for (SNLaidPiece *piece in _pieces)
        if ([piece->target isEqual:target]) rect = NSIsEmptyRect(rect) ? piece->rect : NSUnionRect(rect, piece->rect);
    return rect;
}

@end
