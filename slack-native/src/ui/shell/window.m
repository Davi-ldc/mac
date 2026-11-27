// Owns the window's style, the traffic lights' position and setting the cursor.
#import "ui/kit/hoverview.h"
#import "ui/shell/window.h"

/// Measured on the official app: the first button starts 12 pt from the left and the buttons'
/// centres are 19 pt from the top. AppKit centres them in the titlebar container, so the
/// container is made 2 * 12 + 14 tall.
static const CGFloat kLightsInset = 12;

@implementation SNMainWindow {
    /// The cursor this window set last, if it is not the arrow.
    NSCursor *_shownCursor;
}

- (instancetype)initWithSize:(NSSize)size {
    NSWindowStyleMask style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable |
                              NSWindowStyleMaskResizable | NSWindowStyleMaskFullSizeContentView;
    if (!(self = [super initWithContentRect:NSMakeRect(0, 0, size.width, size.height) styleMask:style backing:NSBackingStoreBuffered defer:YES]))
        return nil;
    self.titlebarAppearsTransparent = YES;
    self.titleVisibility = NSWindowTitleHidden;
    self.title = @"Slack Native";
    self.releasedWhenClosed = NO;
    self.minSize = NSMakeSize(500, 300);
    self.backgroundColor = NSColor.clearColor;
    self.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    for (NSString *name in @[ NSWindowDidResizeNotification, NSWindowDidExitFullScreenNotification, NSWindowDidEndLiveResizeNotification ])
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(placeTrafficLights) name:name object:self];
    [self placeTrafficLights];
    return self;
}

- (void)placeTrafficLights {
    NSButton *close = [self standardWindowButton:NSWindowCloseButton];
    NSView *container = close.superview.superview;
    if (!container) return;
    CGFloat height = 2 * kLightsInset + close.frame.size.height;
    NSRect frame = container.frame;
    frame.size.height = height;
    frame.origin.y = self.frame.size.height - height;
    container.frame = frame;
    CGFloat step = [self standardWindowButton:NSWindowMiniaturizeButton].frame.origin.x - close.frame.origin.x;
    NSWindowButton buttons[] = {NSWindowCloseButton, NSWindowMiniaturizeButton, NSWindowZoomButton};
    for (int i = 0; i < 3; i++) {
        NSButton *button = [self standardWindowButton:buttons[i]];
        [button setFrameOrigin:NSMakePoint(kLightsInset + i * step, (height - button.frame.size.height) / 2)];
    }
}

// The titlebar can be laid out again when the key state changes; placing the buttons again
// keeps them where Slack has them.
- (void)becomeKeyWindow {
    [super becomeKeyWindow];
    [self placeTrafficLights];
    if (self.keyStateChanged) self.keyStateChanged(YES);
    [self updateCursor];
}

- (void)resignKeyWindow {
    [super resignKeyWindow];
    [self placeTrafficLights];
    if (self.keyStateChanged) self.keyStateChanged(NO);
}

#pragma mark Cursor

- (void)setContentView:(NSView *)contentView {
    [super setContentView:contentView];
    // Every move over the window comes through sendEvent:, whatever the views under it track.
    [contentView addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
                                                              options:NSTrackingMouseMoved | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect
                                                                owner:self
                                                             userInfo:nil]];
}

/// After AppKit has handled the event, so the cursor set here is the last word. Not while
/// dragging: a resizer keeps its cursor when the pointer outruns it.
- (void)sendEvent:(NSEvent *)event {
    [super sendEvent:event];
    switch (event.type) {
    case NSEventTypeMouseMoved:
    case NSEventTypeMouseEntered:
    case NSEventTypeMouseExited:
    case NSEventTypeCursorUpdate:
    case NSEventTypeScrollWheel:
    case NSEventTypeLeftMouseDown:
    case NSEventTypeLeftMouseUp:
        [self updateCursor];
        break;
    default:
        break;
    }
}

- (void)updateCursor {
    if (!self.isKeyWindow) return;
    NSCursor *cursor = SNCursorAtPoint(self, self.mouseLocationOutsideOfEventStream);
    if (!cursor) {
        // Only a cursor set here is taken back: AppKit's (the I-beam, the window's resize edges)
        // are left alone.
        if (!_shownCursor || NSCursor.currentCursor != _shownCursor) {
            _shownCursor = nil;
            return;
        }
        cursor = NSCursor.arrowCursor;
    }
    if (NSCursor.currentCursor != cursor) [cursor set];
    _shownCursor = cursor == NSCursor.arrowCursor ? nil : cursor;
}

@end
