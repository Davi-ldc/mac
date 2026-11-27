// Owns the transient message panel (the "hold" hint for Ghostty's cmd+q), drawn as
// Hammerspoon's hs.alert draws its default style, which it replaces: the numbers and the
// placement below are that style's (hs/alert.lua).
#import <AppKit/AppKit.h>

#import "alert.h"

static const CGFloat kTextSize = 27, kPadding = kTextSize / 2, kRadius = 27, kStrokeWidth = 2;
static const NSTimeInterval kFadeSeconds = 0.15;

/// The rounded box and its text.
@interface DKAlertView : NSView
@property(copy) NSAttributedString *text;
@end

@implementation DKAlertView

- (void)drawRect:(NSRect)dirty {
    // The stroke is centred on the outline, so the outline sits half a stroke inside the
    // frame, which hs.alert widens by one stroke for it.
    NSBezierPath *box = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, kStrokeWidth / 2, kStrokeWidth / 2)
                                                        xRadius:kRadius yRadius:kRadius];
    [[NSColor colorWithWhite:0 alpha:0.75] setFill];
    [box fill];
    [NSColor.whiteColor setStroke];
    box.lineWidth = kStrokeWidth;
    [box stroke];
    NSSize size = _text.size;
    [_text drawAtPoint:NSMakePoint((self.bounds.size.width - ceil(size.width)) / 2, (self.bounds.size.height - size.height) / 2)];
}

@end

static NSPanel *panel;
static NSTimer *hideTimer;

void DKShowAlert(NSString *text, NSTimeInterval seconds) {
    if (!panel) {
        panel = [[NSPanel alloc] initWithContentRect:NSZeroRect
                                           styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                             backing:NSBackingStoreBuffered
                                               defer:YES];
        // hs.drawing's level, above everything but the cursor.
        panel.level = NSScreenSaverWindowLevel;
        panel.opaque = NO;
        panel.backgroundColor = NSColor.clearColor;
        panel.hasShadow = NO;
        panel.ignoresMouseEvents = YES;
        panel.releasedWhenClosed = NO;
        panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorStationary |
                                   NSWindowCollectionBehaviorIgnoresCycle | NSWindowCollectionBehaviorFullScreenAuxiliary;
        panel.contentView = [DKAlertView new];
    }
    DKAlertView *view = (DKAlertView *)panel.contentView;
    view.text = [[NSAttributedString alloc] initWithString:text attributes:@{
        NSFontAttributeName : [NSFont systemFontOfSize:kTextSize],
        NSForegroundColorAttributeName : NSColor.whiteColor,
    }];
    NSSize textSize = view.text.size;
    NSSize size = NSMakeSize(ceil(textSize.width) + 2 * kPadding + kStrokeWidth, textSize.height + 2 * kPadding + kStrokeWidth);
    // hs.alert centres the box on the screen with the focused window and puts its top edge
    // (1 - 1/1.55) of the screen's height plus 55 points below the screen's top.
    NSRect screen = NSScreen.mainScreen.frame;
    CGFloat top = NSMaxY(screen) - (screen.size.height * (1 - 1 / 1.55) + 55);
    [panel setFrame:NSMakeRect(NSMinX(screen) + (screen.size.width - size.width) / 2, top - size.height, size.width, size.height)
            display:NO];
    view.needsDisplay = YES;
    if (!panel.visible) panel.alphaValue = 0;
    [panel orderFrontRegardless];
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = kFadeSeconds;
        panel.animator.alphaValue = 1;
    }];
    [hideTimer invalidate];
    hideTimer = [NSTimer scheduledTimerWithTimeInterval:seconds repeats:NO block:^(NSTimer *t) { DKHideAlert(); }];
}

void DKHideAlert(void) {
    [hideTimer invalidate];
    hideTimer = nil;
    if (!panel.visible) return;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = kFadeSeconds;
        panel.animator.alphaValue = 0;
    } completionHandler:^{
        // A new alert may have started while this one faded.
        if (!hideTimer) [panel orderOut:nil];
    }];
}
