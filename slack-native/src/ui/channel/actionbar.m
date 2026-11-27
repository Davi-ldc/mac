// Owns the actions bar's buttons, their hover and tooltips.
#import <CoreText/CoreText.h>

#import "render/document.h"
#import "render/emoji.h"
#import "render/icon.h"
#import "render/strings.h"
#import "ui/channel/actionbar.h"
#import "ui/kit/hoverview.h"
#import "ui/kit/tooltip.h"

/// Slack's "smedium" icon buttons: 32 pt with 18 px icons.
static const CGFloat kButton = 32, kPadding = 4, kGlyph = 18, kEmoji = 18;
static const SNColorToken kButtonHover = 0xe8e8e80a;

/// An emoji drawn once into an image for a layer's contents, so the hover scale is a transform.
static CGImageRef EmojiImage(NSString *name, CGFloat box, CGFloat scale) {
    static NSMutableDictionary<NSString *, id> *cache;
    if (!cache) cache = [NSMutableDictionary new];
    NSString *key = [NSString stringWithFormat:@"%@/%g", name, box];
    if (cache[key]) return (__bridge CGImageRef)cache[key];
    NSString *unicode = SNEmojiUnicode(name) ?: @"";
    size_t side = (size_t)ceil(box * scale);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(NULL, side, side, 8, 0, space, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    CGContextScaleCTM(context, scale, scale);
    NSAttributedString *string = [[NSAttributedString alloc] initWithString:unicode attributes:@{NSFontAttributeName : SNEmojiFont(box)}];
    CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)string);
    CGFloat ascent = 0, descent = 0, width = CTLineGetTypographicBounds(line, &ascent, &descent, NULL);
    CGContextSetTextPosition(context, (box - width) / 2, (box - ascent - descent) / 2 + descent);
    CTLineDraw(line, context);
    CFRelease(line);
    CGImageRef image = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    cache[key] = (__bridge_transfer id)image;
    return image;
}

@interface SNActionButton : SNHoverView
@property (nonatomic) SNMessageAction kind;
@property (nonatomic, copy) NSString *reaction, *tip;
@property (nonatomic) SNLayer *glyph;
@property (nonatomic) CGFloat turn;
@end

@implementation SNActionButton

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.hoverColor = self.pressedColor = kButtonHover;
    self.overlayRadius = SNRadiusLarge;
    self.transitionDuration = SNLiveActionBarIconScale;
    return self;
}

- (void)layout {
    [super layout];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.glyph.bounds = CGRectMake(0, 0, kGlyph, kGlyph);
    self.glyph.position = CGPointMake(NSMidX(self.bounds), NSMidY(self.bounds));
    [CATransaction commit];
}

- (void)setHovered:(BOOL)hovered {
    BOOL changed = hovered != self.hovered;
    [super setHovered:hovered];
    if (!changed) return;
    if (self.hovered) [SNTooltip showText:self.tip forRect:self.bounds inView:self placement:SNPlacementAbove delay:SNLiveActionBarTooltipDelay];
    else [SNTooltip hide];
}

- (void)stateDidChange {
    [super stateDidChange];
    if ([self.glyph isKindOfClass:SNIconLayer.class])
        ((SNIconLayer *)self.glyph).color = self.hovered ? SNLegacyPrimaryForeground : SNLegacyForegroundMaxSolid;
    self.glyph.affineTransform = self.hovered ? CGAffineTransformRotate(CGAffineTransformMakeScale(1.2, 1.2), self.turn) : CGAffineTransformIdentity;
}

@end

@implementation SNMessageActionBar {
    CALayer *_group;
    NSMutableArray<SNActionButton *> *_buttons;
    BOOL _inThread, _summarize;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.wantsLayer = YES;
    _group = [CALayer layer];
    _group.backgroundColor = SNCGColor(SNColorBasePry);
    _group.borderColor = SNCGColor(SNMeasuredActionsBarBorder);
    _group.borderWidth = 1;
    _group.cornerRadius = SNRadiusXlarge;
    // components.json: 0 1px 3px rgba(0,0,0,0.08) under the ring.
    _group.shadowColor = CGColorGetConstantColor(kCGColorBlack);
    _group.shadowOpacity = 0.08;
    _group.shadowRadius = 1.5;
    _group.shadowOffset = CGSizeMake(0, -1);
    [self.layer addSublayer:_group];
    _buttons = [NSMutableArray new];
    return self;
}

- (BOOL)isFlipped { return YES; }
- (NSArray<NSView *> *)buttons { return _buttons; }
- (CGFloat)width { return 2 * kPadding + _buttons.count * kButton; }

- (SNActionButton *)addButton:(SNMessageAction)kind tip:(NSString *)tip {
    SNActionButton *button = [[SNActionButton alloc] initWithFrame:NSMakeRect(kPadding + _buttons.count * kButton, kPadding, kButton, kButton)];
    button.kind = kind;
    button.tip = tip;
    __weak SNMessageActionBar *weakSelf = self;
    button.action = ^(SNActionButton *pressed) {
        SNMessageActionBar *bar = weakSelf;
        if (bar.action) bar.action(pressed.kind, pressed.reaction, pressed.frame);
    };
    [self addSubview:button];
    [_buttons addObject:button];
    return button;
}

- (void)addIcon:(NSString *)name kind:(SNMessageAction)kind tip:(NSString *)key {
    SNActionButton *button = [self addButton:kind tip:SNLocalized(key)];
    SNIconLayer *icon = [SNIconLayer iconNamed:name size:kGlyph color:SNLegacyForegroundMaxSolid];
    button.glyph = icon;
    [button.layer addSublayer:icon];
    [button stateDidChange];
}

- (void)showForMessage:(SNMessage *)message inThread:(BOOL)inThread {
    BOOL summarize = message.replyCount > 0;
    _message = message;
    // The buttons depend only on these two: moving from row to row keeps them.
    if (_buttons.count && inThread == _inThread && summarize == _summarize) return;
    _inThread = inThread, _summarize = summarize;
    for (NSView *button in _buttons) [button removeFromSuperview];
    [_buttons removeAllObjects];
    NSArray *quick = @[ @[ @"white_check_mark", @"channel.action.done" ], @[ @"eyes", @"channel.action.looking" ], @[ @"raised_hands", @"channel.action.nice" ] ];
    for (NSArray<NSString *> *pair in quick) {
        SNActionButton *button = [self addButton:SNMessageActionQuickReaction tip:SNLocalized(pair[1])];
        button.reaction = pair[0];
        SNLayer *emoji = [SNLayer layer];
        emoji.contents = (__bridge id)EmojiImage(pair[0], kEmoji, 2);
        emoji.contentsGravity = kCAGravityResizeAspect;
        button.glyph = emoji;
        [button.layer addSublayer:emoji];
    }
    [self addIcon:@"add-reaction" kind:SNMessageActionAddReaction tip:@"channel.action.react"];
    _buttons.lastObject.turn = 4 * M_PI / 180;
    if (!inThread) [self addIcon:@"threads" kind:SNMessageActionReply tip:@"channel.action.reply"];
    [self addIcon:@"share-message" kind:SNMessageActionForward tip:@"channel.action.forward"];
    _buttons.lastObject.enabled = NO;
    [self addIcon:@"check-add" kind:SNMessageActionTask tip:@"channel.action.task"];
    _buttons.lastObject.enabled = NO;
    if (summarize) {
        [self addIcon:@"ai-summary" kind:SNMessageActionSummarize tip:@"channel.action.summarize"];
        _buttons.lastObject.enabled = NO;
    }
    [self addIcon:@"ellipsis-vertical-filled" kind:SNMessageActionMore tip:@"channel.action.more"];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _group.frame = CGRectMake(0, 0, self.width, SNActionBarHeight);
    _group.shadowPath = CFAutorelease(CGPathCreateWithRoundedRect(_group.bounds, SNRadiusXlarge, SNRadiusXlarge, NULL));
    [CATransaction commit];
}

@end
