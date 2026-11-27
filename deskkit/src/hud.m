// Owns the HUD window. Its measures are Raycast's HUD styles: a glass capsule 52 points
// high with 24 points either side of its text, tinted green from the top for a success.
#import "hud.h"
#import "panel.h"
#import "theme.h"

static const CGFloat kHeight = 52, kPadding = 24, kMaxWidth = 500;
/// How far above the bottom of the screen's usable area it sits, how long it stays and fades.
static const CGFloat kBottom = 80;
static const NSTimeInterval kShowSeconds = 1.5, kFadeSeconds = 0.25;

/// Raycast's success glow: green at 26% spreading down from above the capsule's top.
@interface DKHUDGlow : NSView
@end

@implementation DKHUDGlow
- (void)drawRect:(NSRect)dirty {
    NSColor *green = [NSColor.systemGreenColor colorWithAlphaComponent:0.26];
    NSGradient *glow = [[NSGradient alloc] initWithStartingColor:green endingColor:[green colorWithAlphaComponent:0]];
    NSRect bounds = self.bounds;
    // Unflipped: the glow's centre sits just above the top edge.
    [glow drawInRect:NSInsetRect(NSOffsetRect(bounds, 0, bounds.size.height * 0.45), -bounds.size.width * 0.2, 0)
        relativeCenterPosition:NSMakePoint(0, 0)];
}
@end

void DKShowHUD(NSString *title) {
    static NSPanel *panel;
    static NSUInteger shown;
    NSDictionary *style = @{NSFontAttributeName : DKFont(13, 500), NSForegroundColorAttributeName : DKTextPrimary()};
    CGFloat width = MIN(kMaxWidth, ceil([title sizeWithAttributes:style].width) + 2 * kPadding);
    if (!panel) {
        panel = [[NSPanel alloc] initWithContentRect:NSZeroRect
                                           styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                             backing:NSBackingStoreBuffered
                                               defer:NO];
        panel.releasedWhenClosed = NO;
        panel.level = NSStatusWindowLevel;
        panel.opaque = NO;
        panel.backgroundColor = NSColor.clearColor;
        panel.hasShadow = YES;
        panel.ignoresMouseEvents = YES;
        panel.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
        panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary |
                                   NSWindowCollectionBehaviorTransient;
    }
    NSView *glass = DKGlass(0, kHeight / 2);
    glass.frame = NSMakeRect(0, 0, width, kHeight);
    DKHUDGlow *glow = [[DKHUDGlow alloc] initWithFrame:glass.bounds];
    [glass addSubview:glow positioned:NSWindowBelow relativeTo:glass.subviews.lastObject];
    NSTextField *label = DKLabel(title, style[NSFontAttributeName], DKTextPrimary());
    label.alignment = NSTextAlignmentCenter;
    [label sizeToFit];
    label.frame = NSMakeRect(kPadding, (kHeight - label.frame.size.height) / 2, width - 2 * kPadding, label.frame.size.height);
    [glass addSubview:label];
    panel.contentView = glass;

    NSRect screen = NSScreen.mainScreen.visibleFrame;
    [panel setFrame:NSMakeRect(NSMidX(screen) - width / 2, NSMinY(screen) + kBottom, width, kHeight) display:YES];
    panel.alphaValue = 1;
    [panel orderFrontRegardless];
    NSUInteger mine = ++shown;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kShowSeconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (mine != shown) return;
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
            context.duration = kFadeSeconds;
            panel.animator.alphaValue = 0;
        } completionHandler:^{
            if (mine == shown) [panel orderOut:nil];
        }];
    });
}
