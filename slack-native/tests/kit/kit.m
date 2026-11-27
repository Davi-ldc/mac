// The shared controls: hover state machine, text, avatar, overlays and menus.
#import <ImageIO/ImageIO.h>
#import <QuartzCore/QuartzCore.h>

#import "render/icon.h"
#import "render/images.h"
#import "snapshot.h"
#import "test.h"
#import "ui/kit/avatar.h"
#import "ui/kit/button.h"
#import "ui/kit/dialog.h"
#import "ui/kit/hovercard.h"
#import "ui/kit/label.h"
#import "ui/kit/list.h"
#import "ui/kit/popover.h"
#import "ui/kit/tooltip.h"

/// An offscreen window to put views in; never shown.
static NSWindow *Window(NSSize size) {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:(NSRect){NSZeroPoint, size} styleMask:NSWindowStyleMaskBorderless
                                                     backing:NSBackingStoreBuffered defer:YES];
    window.releasedWhenClosed = NO;
    NSView *content = [[NSView alloc] initWithFrame:(NSRect){NSZeroPoint, size}];
    content.wantsLayer = YES;
    window.contentView = content;
    return window;
}

static NSEvent *Mouse(NSEventType type, NSWindow *window, NSPoint point) {
    return [NSEvent mouseEventWithType:type location:point modifierFlags:0 timestamp:0 windowNumber:window.windowNumber
                               context:nil eventNumber:0 clickCount:1 pressure:1];
}

SN_TEST(CommonHoverStates) {
    SNHoverView *view = [[SNHoverView alloc] initWithFrame:NSMakeRect(0, 0, 40, 20)];
    __block int clicks = 0;
    view.action = ^(SNHoverView *clicked) { clicks++; };
    view.hovered = YES;
    SNExpect(CGColorEqualToColor(view.overlayLayer.backgroundColor, SNCGColor(SNOverlayHover)), "hover paints the 8% overlay");
    view.pressed = YES;
    SNExpect(CGColorEqualToColor(view.overlayLayer.backgroundColor, SNCGColor(SNOverlayPressed)), "press paints the 18% overlay");
    [view mouseUp:Mouse(NSEventTypeLeftMouseUp, Window(NSMakeSize(40, 20)), NSMakePoint(5, 5))];
    SNExpect(clicks == 1 && !view.pressed, "releasing a press clicks");
    view.hovered = NO;
    SNExpect(view.overlayLayer.backgroundColor == NULL, "leaving clears the overlay");
    view.enabled = NO;
    view.hovered = YES;
    view.pressed = YES;
    SNExpect(!view.hovered && !view.pressed, "a disabled view ignores the pointer");
}

SN_TEST(CommonHoverAnimatesWithTheMotionTokens) {
    NSWindow *window = Window(NSMakeSize(100, 100));
    SNHoverView *view = [[SNHoverView alloc] initWithFrame:NSMakeRect(0, 0, 40, 20)];
    [window.contentView addSubview:view];
    // Core Animation animates only layers it has committed once.
    [CATransaction flush];
    view.hovered = YES;
    CABasicAnimation *animation = (CABasicAnimation *)[view.overlayLayer animationForKey:@"backgroundColor"];
    SNExpect(animation && fabs(animation.duration - SNDuration80) < 1e-9, "hover fades in over 80 ms");
    SNExpect([animation.timingFunction isEqual:SNEaseDefault()], "with the default easing");
    view.transitionDuration = 0;
    view.hovered = NO;
    SNExpect(![view.overlayLayer animationForKey:@"backgroundColor"] || view.overlayLayer.backgroundColor == NULL, "zero duration is instant");
}

SN_TEST(CommonIconsAreSlackNames) {
    for (NSString *name in SNIconNames()) {
        const char *what = [NSString stringWithFormat:@"%@ draws (%@)", name, SNHasSlackIcons() ? @"Slack's outline" : @"its SF Symbol"].UTF8String;
        SNExpect(SNIconImage(name, 20, SNColorContentPry, 2) != NULL, what);
    }
    SNExpect(SNIconImage(@"no-such-icon", 20, SNColorContentPry, 2) == NULL, "an unknown name draws nothing");
}

SN_TEST(CommonButtonStyles) {
    SNButton *button = [SNButton iconButtonNamed:@"star" size:28 iconSize:18];
    SNExpect(button.icon.color == SNColorContentSec, "icon button rests in content-sec");
    button.hovered = YES;
    SNExpect(button.icon.color == SNColorContentPry, "and turns content-pry on hover");
    SNButton *primary = [SNButton primaryButtonWithTitle:@"Save"];
    SNExpect(primary.intrinsicContentSize.height == 36 && primary.intrinsicContentSize.width >= 80, "medium button size");
}

SN_TEST(CommonLabelBreaksLikeCSS) {
    NSFont *font = SNFont(11, 700);
    SNExpect(SNLineCount(@"Agentes e ferra­mentas", font, 52, 0) == 3, "soft hyphen breaks the long word");
    SNExpect(SNLineCount(@"Atividade", font, 52, 0) == 1, "short label stays on one line");
    CGFloat balanced = SNBalancedWidth(@"Agentes e ferra\u00ADmentas", font, 52);
    SNExpect(balanced < 52 && SNLineCount(@"Agentes e ferra\u00ADmentas", font, balanced, 0) == 3, "balanced lines are narrower, as many");
    SNExpect(SNLineCount(@"one two three four five six seven", SNFont(15, 400), 60, 2) == 2, "maximum lines");
    SNLabel *label = [SNLabel labelWithText:@"Hello" font:SNFont(15, 400) color:SNColorContentPry];
    label.lineHeight = 22;
    SNExpect([label heightForWidth:200] == 22 && label.intrinsicContentSize.height == 22, "line height");
}

SN_TEST(CommonAvatarShape) {
    SNAvatarView *avatar = [[SNAvatarView alloc] initWithFrame:NSMakeRect(0, 0, 36, 36)];
    avatar.presence = SNAvatarPresenceActive;
    SNPixels *pixels = SNRenderView(avatar, NSMakeSize(36, 36));
    SNExpect(([pixels colorAtPoint:NSMakePoint(18, 18)] == 0x35373bff), "placeholder fill");
    SNExpect(([pixels colorAtPoint:NSMakePoint(0.2, 0.2)] & 0xff) == 0, "rounded corner");
    SNExpect(([pixels colorAtPoint:NSMakePoint(32, 32)] == 0x3daa7cff), "green dot centred at 88.9%");
    SNExpect(([pixels colorAtPoint:NSMakePoint(32, 26.5)] & 0xff) == 0, "notch around the dot");
}

SN_TEST(CommonOverlayPlacement) {
    NSRect bounds = NSMakeRect(0, 0, 400, 300);
    NSRect above = SNPlaceOverlay(NSMakeSize(100, 30), NSMakeRect(150, 100, 50, 20), SNPlacementAbove, 8, YES, bounds);
    SNExpect(NSEqualRects(above, NSMakeRect(125, 62, 100, 30)), "centred above with the gap");
    NSRect flipped = SNPlaceOverlay(NSMakeSize(100, 30), NSMakeRect(150, 10, 50, 20), SNPlacementAbove, 8, YES, bounds);
    SNExpect(flipped.origin.y == 38 && SNPlacementOf(flipped, NSMakeRect(150, 10, 50, 20)) == SNPlacementBelow, "flips below when clipped");
    NSRect clamped = SNPlaceOverlay(NSMakeSize(100, 30), NSMakeRect(380, 100, 20, 20), SNPlacementBelow, 4, NO, bounds);
    SNExpect(NSMaxX(clamped) == 400, "kept inside the window");
    NSRect corner = SNPlaceOverlay(NSMakeSize(60, 30), NSMakeRect(370, 5, 26, 26), SNPlacementAbove, 8, YES, bounds);
    SNExpect(NSMinY(corner) == 39 && NSMaxX(corner) == 400, "in a corner: flipped below and pulled in");
}

SN_TEST(CommonTooltipShowsAfterTheDelay) {
    NSWindow *window = Window(NSMakeSize(300, 200));
    SNHoverView *view = [[SNHoverView alloc] initWithFrame:NSMakeRect(100, 100, 30, 30)];
    view.tooltip = @"Help";
    [window.contentView addSubview:view];
    view.hovered = YES;
    SNOverlayHost *host = [SNOverlayHost hostForWindow:window];
    SNExpect(host.subviews.count == 0, "nothing before 150 ms");
    SNSettle(SNTooltipDelay + 0.1);
    SNExpect(host.subviews.count == 1, "tooltip after the delay");
    view.hovered = NO;
    SNSettle(0.2);
    SNExpect(host.subviews.count == 0, "gone after leaving");
}

SN_TEST(CommonMenuKeyboard) {
    NSWindow *window = Window(NSMakeSize(500, 400));
    __block NSString *chosen;
    SNMenu *menu = [[SNMenu alloc] initWithItems:@[
        [SNMenuItem headerWithTitle:@"Header"], [SNMenuItem itemWithTitle:@"First" action:^{ chosen = @"first"; }], [SNMenuItem separator],
        [SNMenuItem itemWithTitle:@"Second" action:^{ chosen = @"second"; }]
    ]
                                           width:0];
    SNExpect(menu.frame.size.width == 300 && menu.frame.size.height == 12 + 24 + 28 + 16 + 28 + 12, "menu metrics");
    [menu showForRect:NSMakeRect(10, 10, 20, 20) inView:window.contentView placement:SNPlacementBelow];
    NSEvent * (^key)(unsigned short) = ^(unsigned short code) {
        return [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0 context:nil
                              characters:@"" charactersIgnoringModifiers:@"" isARepeat:NO keyCode:code];
    };
    [menu keyDown:key(125)];
    SNExpect(menu.highlightedIndex == 1, "down skips the header");
    [menu keyDown:key(125)];
    SNExpect(menu.highlightedIndex == 3, "and the separator");
    [menu keyDown:key(36)];
    SNExpect([chosen isEqualToString:@"second"] && SNPopover.current == nil, "return chooses and closes");
}

SN_TEST(CommonHoverCardWaits) {
    NSWindow *window = Window(NSMakeSize(600, 400));
    // Near the top of the unflipped content view: 24 to 60 pt from the top of the window.
    NSRect target = NSMakeRect(20, 340, 36, 36);
    [SNHoverCard hoverBeganOverRect:target inView:window.contentView key:@"U1" content:^NSView * {
        return [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 340, 120)];
    }];
    SNOverlayHost *host = [SNOverlayHost hostForWindow:window];
    SNSettle(0.25);
    SNExpect(host.subviews.count == 0, "no card before 370 ms");
    SNSettle(0.25);
    NSRect card = host.subviews.firstObject.frame;
    SNExpect(host.subviews.count == 1 && card.size.width == SNHoverCardWidth, "340 pt card after the delay");
    SNExpect(NSMinY(card) == 60 + 11 && NSMinX(card) == 20, "11 pt below the target's bottom-left");
    [SNHoverCard close];
}

SN_TEST(CommonHoverCardFollowsThePerson) {
    NSWindow *window = Window(NSMakeSize(600, 400));
    NSView *view = window.contentView;
    NSView * (^card)(void) = ^NSView * { return [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 340, 120)]; };
    [SNHoverCard hoverBeganOverRect:NSMakeRect(20, 340, 36, 36) inView:view key:@"UA" content:card];
    SNSettle(SNHoverCardDelay + 0.1);
    SNExpect([SNHoverCard.key isEqualToString:@"UA"], "A's card opens");
    // From A's avatar to B's name, within the close delay.
    [SNHoverCard hoverEnded];
    [SNHoverCard hoverBeganOverRect:NSMakeRect(80, 340, 60, 20) inView:view key:@"UB" content:card];
    SNSettle(SNHoverCardDelay + 0.1);
    SNExpect([SNHoverCard.key isEqualToString:@"UB"] && [SNOverlayHost hostForWindow:window].subviews.count == 1, "B's card replaces A's");
    [SNHoverCard hoverEnded];
    [SNHoverCard hoverBeganOverRect:NSMakeRect(80, 340, 60, 20) inView:view key:@"UB" content:card];
    SNSettle(SNLiveHoverCardCloseDelay + 0.1);
    SNExpect([SNHoverCard.key isEqualToString:@"UB"], "back on B in time, B's card stays");
    [SNHoverCard close];
}

SN_TEST(CommonDisablingHidesTheTooltip) {
    NSWindow *window = Window(NSMakeSize(300, 200));
    SNHoverView *view = [[SNHoverView alloc] initWithFrame:NSMakeRect(100, 100, 30, 30)];
    view.tooltip = @"Send now";
    [window.contentView addSubview:view];
    view.hovered = YES;
    SNSettle(SNTooltipDelay + 0.1);
    view.enabled = NO;
    SNExpect([SNOverlayHost hostForWindow:window].subviews.count == 0, "a hovered view that turns disabled takes its tooltip away");
}

SN_TEST(CommonPopoversGiveTheKeyboardBack) {
    NSWindow *window = Window(NSMakeSize(500, 400));
    NSTextView *text = [[NSTextView alloc] initWithFrame:NSMakeRect(10, 300, 200, 40)];
    [window.contentView addSubview:text];
    [window makeFirstResponder:text];
    SNMenu *menu = [[SNMenu alloc] initWithItems:@[ [SNMenuItem itemWithTitle:@"One" action:nil] ] width:0];
    [menu showForRect:NSMakeRect(10, 10, 20, 20) inView:window.contentView placement:SNPlacementBelow];
    SNExpect(window.firstResponder == menu, "the menu takes the keyboard");
    [SNPopover.current close];
    SNExpect(window.firstResponder == text, "and gives it back when it closes");

    // A popover opened from inside the open one: the anchor leaves the window as the first closes.
    NSView *inner = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 100, 60)];
    NSView *anchor = [[NSView alloc] initWithFrame:NSMakeRect(10, 10, 20, 20)];
    [inner addSubview:anchor];
    [SNPopover showContent:inner forRect:NSMakeRect(10, 10, 20, 20) inView:window.contentView placement:SNPlacementBelow gap:4];
    SNPopover *second = [SNPopover showContent:[[NSView alloc] initWithFrame:NSMakeRect(0, 0, 80, 40)] forRect:anchor.bounds inView:anchor placement:SNPlacementBelow gap:4];
    SNExpect(second && SNPopover.current == second && !anchor.window, "opens where its anchor was");
    [second close];
    SNExpect(!second.content && ![SNPopover showContent:[NSView new] forRect:NSZeroRect inView:anchor placement:SNPlacementBelow gap:0],
             "a closed popover lets go of its content; none opens without a window");
}

/// A 4 px PNG in a folder of its own.
static NSURL *PictureFile(NSString *name) {
    NSURL *folder = [NSFileManager.defaultManager.temporaryDirectory URLByAppendingPathComponent:@"sn-pictures" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *url = [folder URLByAppendingPathComponent:name];
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(NULL, 4, 4, 8, 0, space, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGContextSetRGBFillColor(context, 1, 0, 0, 1);
    CGContextFillRect(context, CGRectMake(0, 0, 4, 4));
    CGImageRef image = CGBitmapContextCreateImage(context);
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL((__bridge CFURLRef)url, CFSTR("public.png"), 1, NULL);
    CGImageDestinationAddImage(destination, image, NULL);
    CGImageDestinationFinalize(destination);
    CFRelease(destination);
    CGImageRelease(image);
    CGContextRelease(context);
    CGColorSpaceRelease(space);
    return url;
}

static void WaitForPictures(void) {
    for (int i = 0; i < 100 && SNImageLoadsInFlight(); i++) SNSettle(0.01);
}

SN_TEST(CommonAvatarForgetsTheLastPicture) {
    SNAvatarView *avatar = [[SNAvatarView alloc] initWithFrame:NSMakeRect(0, 0, 36, 36)];
    avatar.imageURL = PictureFile(@"first.png");
    SNExpect(avatar.image == NULL, "nothing until the picture arrives");
    WaitForPictures();
    SNExpect(avatar.image != NULL, "then its picture");
    avatar.imageURL = [NSURL fileURLWithPath:@"/nonexistent/second.png"];
    SNExpect(avatar.image == NULL, "another person's picture is not shown while theirs loads");
    avatar.imageURL = nil;
    SNExpect(avatar.image == NULL, "nor when they have none");
}

SN_TEST(CommonPicturesAreSharedWhileHeld) {
    NSURL *url = PictureFile(@"shared.png"), *dead = [NSURL fileURLWithPath:@"/nonexistent/dead-emoji.png"];
    NSView *one = [NSView new], *two = [NSView new];
    // A pool per step, as each event has: what a step let go of is gone after it.
    @autoreleasepool {
        [one.imageHolder imageWithURL:url pixels:44];
        [two.imageHolder imageWithURL:url pixels:44];
        SNExpect(SNImageLoadsInFlight() == 1, "two views showing one picture fetch it once");
    }
    WaitForPictures();
    @autoreleasepool {
        CGImageRef first = [one.imageHolder imageWithURL:url pixels:44];
        SNExpect(first && first == [two.imageHolder imageWithURL:url pixels:32], "and draw the one bitmap, at any size it covers");
        [one.imageHolder removeAllImages];
        SNExpect([two.imageHolder imageWithURL:url pixels:44] == first && SNImageLoadsInFlight() == 0, "it stays while one of them holds it");
        [two.imageHolder removeAllImages];
        SNExpect([one.imageHolder imageWithURL:url pixels:44] == first && SNImageLoadsInFlight() == 0, "taken back in the same turn, it is the same bitmap");
        [one.imageHolder removeAllImages];
    }
    SNSettle(0.01);
    @autoreleasepool {
        [one.imageHolder imageWithURL:url pixels:44];
        SNExpect(SNImageLoadsInFlight() == 1, "and goes with the last at the end of the turn: asked again, it is fetched again");
    }
    WaitForPictures();

    @autoreleasepool {
        SNExpect([one.imageHolder imageWithURL:dead pixels:44] == NULL && SNImageLoadsInFlight() == 1, "a missing picture is asked for");
    }
    WaitForPictures();
    @autoreleasepool {
        SNExpect([one.imageHolder imageWithURL:dead pixels:44] == NULL && SNImageLoadsInFlight() == 0, "and not again while held after it failed");
        [one.imageHolder removeFailedImages];
    }
    @autoreleasepool {
        [one.imageHolder imageWithURL:dead pixels:44];
        SNExpect(SNImageLoadsInFlight() == 1, "until it is let go");
    }
    WaitForPictures();
}

SN_TEST(CommonPicturesSurviveUntilAfterDrawPass) {
    NSURL *url = PictureFile(@"redraw-retention.png");
    NSView *view = [NSView new];
    @autoreleasepool { [view.imageHolder imageWithURL:url pixels:44]; }
    WaitForPictures();
    CGImageRef first = NULL;
    @autoreleasepool {
        first = [view.imageHolder imageWithURL:url pixels:44];
        SNExpect(first != NULL, "picture decoded");
        // removeAllImages defers release until order 2500000 (after CA draw/commit at 2000000),
        // so neither dispatch_async(main) nor a draw pass in the same turn drops the bitmap.
        [view.imageHolder removeAllImages];
    }
    __block BOOL dispatchSawSame = NO, drawPassSawSame = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            CGImageRef duringDispatch = [view.imageHolder imageWithURL:url pixels:44];
            dispatchSawSame = duringDispatch == first && SNImageLoadsInFlight() == 0;
            [view.imageHolder removeAllImages];
        }
    });
    CFRunLoopObserverRef drawObserver = CFRunLoopObserverCreateWithHandler(NULL, kCFRunLoopBeforeWaiting, false, 2000000,
                                                                           ^(CFRunLoopObserverRef observer, CFRunLoopActivity activity) {
        @autoreleasepool {
            CGImageRef duringDraw = [view.imageHolder imageWithURL:url pixels:44];
            drawPassSawSame = duringDraw == first && SNImageLoadsInFlight() == 0;
            [view.imageHolder removeAllImages];
        }
        CFRunLoopObserverInvalidate(observer);
    });
    CFRunLoopAddObserver(CFRunLoopGetMain(), drawObserver, kCFRunLoopCommonModes);
    CFRelease(drawObserver);
    SNSettle(0.02);
    SNExpect(dispatchSawSame && drawPassSawSame, "deferred release keeps picture alive across dispatch_async and CA draw order 2000000");

    // After the run-loop turn finishes (order 2500000), the unheld picture is freed.
    @autoreleasepool {
        [view.imageHolder imageWithURL:url pixels:44];
        SNExpect(SNImageLoadsInFlight() == 1, "and releases it after the draw pass");
    }
    WaitForPictures();
}

@interface SNTestRecycledRow : SNHoverView
@property (nonatomic, readonly) SNLabel *label;
@property (nonatomic, readonly) SNButton *button;
@end

@implementation SNTestRecycledRow
- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _label = [SNLabel labelWithText:@"Same text" font:SNFont(SNFontSizeBase, SNFontWeightRegular) color:SNColorContentPry];
    _label.wantsLayer = YES;
    _label.frame = NSMakeRect(8, 8, 120, 22);
    _button = [SNButton outlineButtonWithTitle:@"Action"];
    _button.frame = NSMakeRect(140, 4, 90, 32);
    [self addSubview:_label];
    [self addSubview:_button];
    return self;
}
@end

@interface SNTestRecycledList : SNListView
@end

@implementation SNTestRecycledList
- (SNHoverView *)makeRow { return [[SNTestRecycledRow alloc] initWithFrame:NSZeroRect]; }
- (CGFloat)heightOfIndex:(NSUInteger)index width:(CGFloat)width { return 40; }
- (void)showIndex:(NSUInteger)index inRow:(SNHoverView *)row {
    SNTestRecycledRow *cell = (SNTestRecycledRow *)row;
    // Intentionally assign the same text so SNLabel setText: early-returns on reuse.
    cell.label.text = @"Same text";
    cell.button.title = @"Action";
}
@end

static BOOL HasNonZeroPixel(SNPixels *pixels, NSRect rect) {
    size_t x0 = (size_t)MAX(0, floor(NSMinX(rect) * SNSnapshotScale)), x1 = (size_t)MIN(pixels.width, ceil(NSMaxX(rect) * SNSnapshotScale));
    size_t y0 = (size_t)MAX(0, floor(NSMinY(rect) * SNSnapshotScale)), y1 = (size_t)MIN(pixels.height, ceil(NSMaxY(rect) * SNSnapshotScale));
    for (size_t y = y0; y < y1; y++)
        for (size_t x = x0; x < x1; x++)
            if (pixels.bytes[(y * pixels.width + x) * 4 + 3] > 0) return YES;
    return NO;
}

static BOOL PixelsEqualInRect(SNPixels *a, SNPixels *b, NSRect rect) {
    if (a.width != b.width || a.height != b.height) return NO;
    size_t x0 = (size_t)MAX(0, floor(NSMinX(rect) * SNSnapshotScale)), x1 = (size_t)MIN(a.width, ceil(NSMaxX(rect) * SNSnapshotScale));
    size_t y0 = (size_t)MAX(0, floor(NSMinY(rect) * SNSnapshotScale)), y1 = (size_t)MIN(a.height, ceil(NSMaxY(rect) * SNSnapshotScale));
    for (size_t y = y0; y < y1; y++)
        for (size_t x = x0; x < x1; x++) {
            size_t off = (y * a.width + x) * 4;
            if (memcmp(a.bytes + off, b.bytes + off, 4) != 0) return NO;
        }
    return YES;
}

SN_TEST(CommonListRecycleRedrawsLayerBackedSubviews) {
    NSWindow *window = Window(NSMakeSize(300, 200));
    window.opaque = NO;
    window.backgroundColor = NSColor.clearColor;
    SNTestRecycledList *list = [[SNTestRecycledList alloc] initWithFrame:NSMakeRect(0, 0, 300, 200)];
    list.overscan = 0;
    [window.contentView addSubview:list];
    NSMutableArray<NSString *> *keys = [NSMutableArray new];
    for (int i = 0; i < 40; i++) [keys addObject:[NSString stringWithFormat:@"row-%d", i]];
    [list showKeys:keys];
    NSRect labelRect = NSMakeRect(8, 8, 120, 22), buttonRect = NSMakeRect(140, 4, 90, 32);
    SNPixels *before = SNRenderView(list, NSMakeSize(300, 200));
    SNExpect([list rowAtIndex:0] && HasNonZeroPixel(before, labelRect) && HasNonZeroPixel(before, buttonRect),
             "initial row draws its layer-backed label and button");

    // Scroll far down so row 0 is recycled (ClearLayerContents), then back to top.
    [list.scrollView.contentView scrollToPoint:NSMakePoint(0, 1200)];
    [list.scrollView reflectScrolledClipView:list.scrollView.contentView];
    SNExpect([list rowAtIndex:0] == nil, "row 0 recycled off screen");

    [list.scrollView.contentView scrollToPoint:NSZeroPoint];
    [list.scrollView reflectScrolledClipView:list.scrollView.contentView];
    SNPixels *after = SNRenderView(list, NSMakeSize(300, 200));
    SNExpect([list rowAtIndex:0] && HasNonZeroPixel(after, labelRect) && HasNonZeroPixel(after, buttonRect),
             "recycled row draws non-empty layer-backed SNLabel and SNButton subviews");
    SNExpect(PixelsEqualInRect(before, after, labelRect) && PixelsEqualInRect(before, after, buttonRect),
             "recycled row redraws layer-backed SNLabel and SNButton subviews identically even when setText: early-returns");
}

SN_TEST(ConfirmDialogWaitingRecoveryAndFailedImageRetry) {
    // 1. SNConfirmDialog.waiting = NO restores confirmEnabled instead of locking it disabled.
    NSWindow *window = Window(NSMakeSize(640, 480));
    __block NSInteger confirms = 0;
    SNConfirmDialog *dialog = [SNConfirmDialog showFormInWindow:window title:@"Invite" accessory:[[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 40)]
                                                          width:520 confirmTitle:@"Send" confirmed:^{ confirms++; }];
    dialog.confirmAction = ^{ confirms++; };
    SNExpect(dialog.confirmEnabled, "confirm starts enabled");
    dialog.waiting = YES;
    SNExpect(dialog.waiting && dialog.confirmEnabled, "waiting preserves logical confirmEnabled");
    [dialog confirm];
    SNExpect(confirms == 0, "confirm is ignored while waiting");
    dialog.waiting = NO;
    SNExpect(!dialog.waiting && dialog.confirmEnabled, "clearing waiting restores confirmEnabled");
    SNButton *confirmButton = [dialog valueForKey:@"confirmButton"];
    SNExpect(confirmButton.enabled, "confirm button is clickable again after waiting = NO");
    [dialog confirm];
    SNExpect(confirms == 1, "confirm fires after error recovery");
    dialog.confirmEnabled = NO;
    dialog.waiting = YES;
    dialog.waiting = NO;
    SNExpect(!dialog.confirmEnabled && !confirmButton.enabled, "explicitly disabled confirm stays disabled across waiting");
    [dialog cancel];

    // 2. SNRetryFailedImages drops failed pictures across holders so they fetch again on reconnect.
    NSURL *dead = [NSURL fileURLWithPath:@"/nonexistent/retry-reconnect-test.png"];
    NSView *view = [NSView new];
    @autoreleasepool {
        SNExpect([view.imageHolder imageWithURL:dead pixels:44] == NULL && SNImageLoadsInFlight() == 1, "failed picture starts loading");
    }
    WaitForPictures();
    @autoreleasepool {
        SNExpect([view.imageHolder imageWithURL:dead pixels:44] == NULL && SNImageLoadsInFlight() == 0, "stays cached during backoff");
    }
    SNRetryFailedImages();
    @autoreleasepool {
        [view.imageHolder imageWithURL:dead pixels:44];
        SNExpect(SNImageLoadsInFlight() == 1, "SNRetryFailedImages allows immediate retry on reconnect");
    }
    WaitForPictures();
}
