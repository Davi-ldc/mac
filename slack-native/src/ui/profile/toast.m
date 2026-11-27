// Owns the toast's layout, timing and its one instance.
#import "render/icon.h"
#import "ui/kit/button.h"
#import "ui/kit/overlay.h"
#import "ui/profile/toast.h"

/// .c-toast: 12/16 padding, max-width 350, 15 pt on 1.5 lines; the wrapper's 8 pt gaps; the
/// close button a 28 pt medium icon button 2 pt down; offsets 20 pt from the bottom right.
static const CGFloat kPaddingY = 12, kPaddingX = 16, kMaxWidth = 350, kLine = 22.5, kIcon = 20, kGap = 8, kClose = 28, kOffset = 20;
/// c-toast-fade-in/out: 80 ms cubic-bezier(.36,.19,.29,1), rising 20 pt.
static const NSTimeInterval kFade = 0.08;
static const CGFloat kRise = 20;

@interface SNToastView : SNPanelView
@property (nonatomic) NSAttributedString *text;
@property (nonatomic, copy) NSString *icon;
@property (nonatomic) SNButton *closeButton;
@property (nonatomic, copy) void (^hoverChanged)(BOOL inside);
@end

@interface SNToastBody : NSView
@property (nonatomic, weak) SNToastView *toast;
@end

@implementation SNToastBody
- (BOOL)isFlipped { return YES; }

- (void)drawRect:(NSRect)dirtyRect {
    CGContextSetShouldSmoothFonts(NSGraphicsContext.currentContext.CGContext, false);
    SNToastView *toast = self.toast;
    CGFloat height = NSHeight(self.bounds);
    SNDrawIcon(toast.icon, kIcon, SNColorContentInvPry, NSMakeRect(kPaddingX, (height - kIcon) / 2, kIcon, kIcon));
    CGFloat x = kPaddingX + kIcon + kGap, width = NSWidth(self.bounds) - x - kGap - kClose - kPaddingX;
    CGFloat textHeight = ceil([toast.text boundingRectWithSize:NSMakeSize(width, 1000) options:NSStringDrawingUsesLineFragmentOrigin].size.height);
    [toast.text drawWithRect:NSMakeRect(x, (height - textHeight) / 2, width, textHeight) options:NSStringDrawingUsesLineFragmentOrigin];
}
@end

@implementation SNToastView

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *area in self.trackingAreas) [self removeTrackingArea:area];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
                                                       options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
                                                         owner:self
                                                      userInfo:nil]];
}

- (void)mouseEntered:(NSEvent *)event {
    self.closeButton.hidden = NO;
    if (self.hoverChanged) self.hoverChanged(YES);
}

- (void)mouseExited:(NSEvent *)event {
    self.closeButton.hidden = YES;
    if (self.hoverChanged) self.hoverChanged(NO);
}

@end

/// Slack's rt() markup: <b>...</b> in bold, the rest regular.
static NSAttributedString *Styled(NSString *text) {
    NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
    paragraph.minimumLineHeight = paragraph.maximumLineHeight = kLine;
    NSFont *regular = SNFont(SNFontSizeBase, SNFontWeightRegular);
    // Centres the glyphs in the 1.5 line as a CSS line box does.
    CGFloat offset = (kLine - (regular.ascender - regular.descender)) / 2 - 1;
    NSDictionary *base = @{NSFontAttributeName : regular, NSForegroundColorAttributeName : SNColor(SNColorContentInvPry), NSParagraphStyleAttributeName : paragraph,
                           NSBaselineOffsetAttributeName : @(offset)};
    NSMutableAttributedString *styled = [NSMutableAttributedString new];
    NSScanner *scanner = [NSScanner scannerWithString:text];
    scanner.charactersToBeSkipped = nil;
    BOOL bold = NO;
    while (!scanner.isAtEnd) {
        NSString *run = nil;
        [scanner scanUpToString:bold ? @"</b>" : @"<b>" intoString:&run];
        if (run.length) {
            NSMutableDictionary *attributes = [base mutableCopy];
            if (bold) attributes[NSFontAttributeName] = SNFont(SNFontSizeBase, SNFontWeightBold);
            [styled appendAttributedString:[[NSAttributedString alloc] initWithString:run attributes:attributes]];
        }
        if ([scanner scanString:bold ? @"</b>" : @"<b>" intoString:NULL]) bold = !bold;
    }
    return styled;
}

@implementation SNToast

static SNToastView *toast;
static NSUInteger generation;

+ (NSString *)currentText { return toast.text.string; }

+ (void)showText:(NSString *)text icon:(NSString *)icon duration:(NSTimeInterval)duration inWindow:(NSWindow *)window {
    SNOverlayHost *host = [SNOverlayHost hostForWindow:window];
    if (!host) return;
    [self close];
    SNShadowStack shadow = {2, {{0, 0, 0, 1, 0x1d1c1d21, NO}, {0, 4, 12, 0, 0x00000014, NO}}};
    SNToastView *view = [[SNToastView alloc] initWithFill:SNColorBaseInvPry radius:SNRadiusLarge shadow:shadow];
    view.text = Styled(text);
    view.icon = icon;
    CGFloat chrome = kPaddingX + kIcon + kGap + kGap + kClose + kPaddingX;
    CGFloat textWidth = MIN(ceil(view.text.size.width), kMaxWidth - chrome);
    CGFloat textHeight = ceil([view.text boundingRectWithSize:NSMakeSize(textWidth, 1000) options:NSStringDrawingUsesLineFragmentOrigin].size.height);
    NSSize size = NSMakeSize(chrome + textWidth, kPaddingY * 2 + MAX(MAX(textHeight, kLine), kClose + 2));
    SNToastBody *body = [[SNToastBody alloc] initWithFrame:(NSRect){NSZeroPoint, size}];
    body.toast = view;
    [view.contentView addSubview:body];
    __weak SNToastView *weakView = view;
    view.closeButton = [SNButton iconButtonNamed:@"close" size:kClose iconSize:kIcon];
    view.closeButton.contentColor = view.closeButton.hoverContentColor = SNColorContentInvPry;
    view.closeButton.hoverFillColor = 0;
    view.closeButton.frame = NSMakeRect(size.width - kPaddingX - kClose, (size.height - kClose) / 2 + 1, kClose, kClose);
    view.closeButton.hidden = YES;
    view.closeButton.action = ^(SNButton *button) {
        if (weakView == toast) [SNToast dismiss];
    };
    [view.contentView addSubview:view.closeButton];
    NSRect bounds = host.bounds;
    NSRect frame = NSMakeRect(NSMaxX(bounds) - kOffset - size.width, NSMaxY(bounds) - kOffset - size.height, size.width, size.height);
    view.frame = NSOffsetRect(frame, 0, kRise);
    view.alphaValue = 0;
    [host addSubview:view];
    toast = view;
    NSUInteger shown = ++generation;
    view.hoverChanged = ^(BOOL inside) {
        // The pointer holds the toast; leaving starts its time again.
        NSUInteger held = ++generation;
        if (!inside) [SNToast dismissAfter:duration generation:held];
    };
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = kFade;
        context.timingFunction = [CAMediaTimingFunction functionWithControlPoints:.36 :.19 :.29 :1];
        view.animator.alphaValue = 1;
        view.animator.frame = frame;
    }];
    [self dismissAfter:duration generation:shown];
}

+ (void)dismissAfter:(NSTimeInterval)delay generation:(NSUInteger)due {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (due == generation) [self dismiss];
    });
}

+ (void)dismiss {
    SNToastView *view = toast;
    toast = nil;
    generation++;
    if (!view) return;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = kFade;
        context.timingFunction = [CAMediaTimingFunction functionWithControlPoints:.36 :.19 :.29 :1];
        view.animator.alphaValue = 0;
        view.animator.frame = NSOffsetRect(view.frame, 0, kRise);
    } completionHandler:^{ [view removeFromSuperview]; }];
}

+ (void)close {
    generation++;
    [toast removeFromSuperview];
    toast = nil;
}

@end
