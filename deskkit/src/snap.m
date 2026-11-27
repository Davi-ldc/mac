// Owns window snapping: Rectangle's shortcuts, the geometry of each action, and the frames
// "restore" goes back to.
#import <AppKit/AppKit.h>

#import "features.h"
#import "hotkey.h"
#import "windows.h"

typedef enum { Tile, MaximizeHeight, Center, Larger, Smaller, Restore, NextDisplay, PreviousDisplay } Kind;

typedef struct {
    const char *name;
    UInt32 key, modifiers;
    Kind kind;
    /// For a Tile: the grid laid evenly over the screen, and the cells of it the window covers.
    struct { uint8_t columns, rows; } grid;
    struct { uint8_t column, row, width, height; } cell;
} Action;

// Rectangle's default shortcuts (its own set, not the Spectacle one), except the thirds,
// which follow this user's Rectangle setup.
static const UInt32 kCtrlOpt = controlKey | optionKey;
static const Action kActions[] = {
    {"leftHalf", kVK_LeftArrow, kCtrlOpt, Tile, {2, 1}, {0, 0, 1, 1}},
    {"rightHalf", kVK_RightArrow, kCtrlOpt, Tile, {2, 1}, {1, 0, 1, 1}},
    {"topHalf", kVK_UpArrow, kCtrlOpt, Tile, {1, 2}, {0, 0, 1, 1}},
    {"bottomHalf", kVK_DownArrow, kCtrlOpt, Tile, {1, 2}, {0, 1, 1, 1}},
    {"topLeft", kVK_ANSI_U, kCtrlOpt, Tile, {2, 2}, {0, 0, 1, 1}},
    {"topRight", kVK_ANSI_I, kCtrlOpt, Tile, {2, 2}, {1, 0, 1, 1}},
    {"bottomLeft", kVK_ANSI_J, kCtrlOpt, Tile, {2, 2}, {0, 1, 1, 1}},
    {"bottomRight", kVK_ANSI_K, kCtrlOpt, Tile, {2, 2}, {1, 1, 1, 1}},
    {"firstThird", kVK_ANSI_E, kCtrlOpt, Tile, {3, 1}, {0, 0, 1, 1}},
    {"centerThird", kVK_ANSI_R, kCtrlOpt, Tile, {3, 1}, {1, 0, 1, 1}},
    {"lastThird", kVK_ANSI_T, kCtrlOpt, Tile, {3, 1}, {2, 0, 1, 1}},
    {"firstTwoThirds", kVK_ANSI_D, kCtrlOpt, Tile, {3, 1}, {0, 0, 2, 1}},
    {"centerTwoThirds", kVK_ANSI_F, kCtrlOpt, Tile, {6, 1}, {1, 0, 4, 1}},
    {"lastTwoThirds", kVK_ANSI_G, kCtrlOpt, Tile, {3, 1}, {1, 0, 2, 1}},
    {"maximize", kVK_Return, kCtrlOpt, Tile, {1, 1}, {0, 0, 1, 1}},
    {"maximizeHeight", kVK_UpArrow, kCtrlOpt | shiftKey, .kind = MaximizeHeight},
    {"center", kVK_ANSI_C, kCtrlOpt, .kind = Center},
    {"larger", kVK_ANSI_Equal, kCtrlOpt, .kind = Larger},
    {"smaller", kVK_ANSI_Minus, kCtrlOpt, .kind = Smaller},
    {"restore", kVK_Delete, kCtrlOpt, .kind = Restore},
    {"nextDisplay", kVK_RightArrow, kCtrlOpt | cmdKey, .kind = NextDisplay},
    {"previousDisplay", kVK_LeftArrow, kCtrlOpt | cmdKey, .kind = PreviousDisplay},
};
static const size_t kActionCount = sizeof kActions / sizeof *kActions;

// Rectangle grows and shrinks a window by this much on each side.
static const CGFloat kSizeStep = 30;

/// Where an action that needs only the window's frame `w` and the screen's visible frame
/// `v` puts the window; CGRectNull for the others.
static CGRect Target(const Action *a, CGRect w, CGRect v) {
    CGFloat x = v.origin.x, y = v.origin.y, W = v.size.width, H = v.size.height;
    switch (a->kind) {
    case Tile:
        return CGRectMake(x + a->cell.column * W / a->grid.columns, y + a->cell.row * H / a->grid.rows,
                          a->cell.width * W / a->grid.columns, a->cell.height * H / a->grid.rows);
    case MaximizeHeight: return CGRectMake(w.origin.x, y, w.size.width, H);
    case Center: return CGRectMake(x + (W - w.size.width) / 2, y + (H - w.size.height) / 2, w.size.width, w.size.height);
    case Larger: return CGRectIntersection(CGRectInset(w, -kSizeStep, -kSizeStep), v);
    case Smaller: return CGRectInset(w, MIN(kSizeStep, w.size.width / 4), MIN(kSizeStep, w.size.height / 4));
    default: return CGRectNull;
    }
}

CGRect DKSnapTarget(NSString *action, CGRect window, CGRect visible) {
    for (size_t i = 0; i < kActionCount; i++)
        if (!strcmp(kActions[i].name, action.UTF8String)) return Target(&kActions[i], window, visible);
    return CGRectNull;
}

/// A Cocoa rectangle (origin at the bottom left of the primary screen) in Accessibility
/// coordinates (origin at its top left).
static CGRect AXRect(NSRect r) {
    CGFloat primaryHeight = NSScreen.screens.firstObject.frame.size.height;
    return CGRectMake(r.origin.x, primaryHeight - r.origin.y - r.size.height, r.size.width, r.size.height);
}

/// The part of a screen that the menu bar and the Dock leave free. It follows the Dock, the
/// menu bar and the current Space, so every snap pays its two trips to the window server.
static CGRect Visible(NSScreen *screen) { return AXRect(screen.visibleFrame); }

/// The screen holding most of the window.
static NSScreen *ScreenFor(CGRect window) {
    NSScreen *best = NSScreen.mainScreen;
    CGFloat bestArea = 0;
    for (NSScreen *screen in NSScreen.screens) {
        CGSize overlap = CGRectIntersection(AXRect(screen.frame), window).size;
        CGFloat area = overlap.width * overlap.height;
        if (area > bestArea) bestArea = area, best = screen;
    }
    return best;
}

/// The window's frame on the next or the previous screen, with the same place and share of
/// the screen; CGRectNull when there is no other screen.
static CGRect OnOtherScreen(CGRect w, BOOL next) {
    NSArray<NSScreen *> *screens = NSScreen.screens;
    if (screens.count < 2) return CGRectNull;
    NSScreen *screen = ScreenFor(w);
    NSUInteger other = ([screens indexOfObject:screen] + (next ? 1 : screens.count - 1)) % screens.count;
    CGRect from = Visible(screen), to = Visible(screens[other]);
    return CGRectMake(to.origin.x + (w.origin.x - from.origin.x) / from.size.width * to.size.width,
                      to.origin.y + (w.origin.y - from.origin.y) / from.size.height * to.size.height,
                      w.size.width / from.size.width * to.size.width, w.size.height / from.size.height * to.size.height);
}

static const NSUInteger kRememberLimit = 50;

/// Windows paired with the frame each had before its first snap, oldest first.
static NSMutableArray<NSArray *> *remembered;

/// The window's place in `remembered`, or NSNotFound. Each shortcut gets its own reference
/// to the window, so they are compared by CFEqual.
static NSUInteger RememberedIndex(AXUIElementRef window) {
    for (NSUInteger i = 0; i < remembered.count; i++)
        if (CFEqual((__bridge CFTypeRef)remembered[i][0], window)) return i;
    return NSNotFound;
}

/// Keeps the frame of a window about to be snapped, unless one is already kept for it.
void DKSnapRemember(AXUIElementRef window, CGRect frame) {
    if (RememberedIndex(window) != NSNotFound) return;
    if (!remembered) remembered = [NSMutableArray new];
    [remembered addObject:@[ (__bridge id)window, @(frame) ]];
    if (remembered.count > kRememberLimit) [remembered removeObjectAtIndex:0];
}

/// The frame kept for the window, which is then forgotten; CGRectNull when there is none.
CGRect DKSnapRecall(AXUIElementRef window) {
    NSUInteger index = RememberedIndex(window);
    if (index == NSNotFound) return CGRectNull;
    CGRect frame = [remembered[index][1] rectValue];
    [remembered removeObjectAtIndex:index];
    return frame;
}

/// The window's position and size, in one round trip to its app; whichever cannot be read
/// is zero.
static CGRect Frame(AXUIElementRef window) {
    static CFArrayRef attributes;
    if (!attributes) attributes = CFBridgingRetain(@[ (id)kAXPositionAttribute, (id)kAXSizeAttribute ]);
    CGRect frame = CGRectZero;
    CFArrayRef values = NULL;
    AXUIElementCopyMultipleAttributeValues(window, attributes, 0, &values);
    if (values) {
        AXValueGetValue(CFArrayGetValueAtIndex(values, 0), kAXValueTypeCGPoint, &frame.origin);
        AXValueGetValue(CFArrayGetValueAtIndex(values, 1), kAXValueTypeCGSize, &frame.size);
        CFRelease(values);
    }
    return frame;
}

static void Set(AXUIElementRef window, CFStringRef attribute, AXValueType type, const void *value) {
    AXValueRef boxed = AXValueCreate(type, value);
    AXUIElementSetAttributeValue(window, attribute, boxed);
    CFRelease(boxed);
}

/// Takes the window from one frame to another, asking only for what changes: an app works
/// on a resize even when the size stays the same.
static void SetFrame(AXUIElementRef window, CGRect from, CGRect to) {
    BOOL resize = !CGSizeEqualToSize(from.size, to.size), move = !CGPointEqualToPoint(from.origin, to.origin);
    // Size, move, size: a window that hits the screen edge while moving can refuse the first
    // resize, and apps clamp sizes against the current position. The second resize is only
    // for a first one that did not take, which reading the size back tells far more cheaply.
    if (resize) Set(window, kAXSizeAttribute, kAXValueTypeCGSize, &to.size);
    if (move) Set(window, kAXPositionAttribute, kAXValueTypeCGPoint, &to.origin);
    if (resize && move && !CGSizeEqualToSize(Frame(window).size, to.size))
        Set(window, kAXSizeAttribute, kAXValueTypeCGSize, &to.size);
}

static void Perform(const Action *action) {
    AXUIElementRef window = DKCopyFocusedWindow(NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier);
    if (!window) return;
    CGRect frame = Frame(window), target;
    switch (action->kind) {
    case Restore: target = DKSnapRecall(window); break;
    case NextDisplay:
    case PreviousDisplay: target = OnOtherScreen(frame, action->kind == NextDisplay); break;
    default:
        target = Target(action, frame, Visible(ScreenFor(frame)));
        if (!CGRectIsNull(target)) DKSnapRemember(window, frame);
    }
    if (!CGRectIsNull(target)) SetFrame(window, frame, CGRectIntegral(target));
    CFRelease(window);
}

void DKStartSnapping(void) {
    for (size_t i = 0; i < kActionCount; i++) {
        const Action *action = &kActions[i];
        [DKHotkey key:action->key modifiers:action->modifiers handler:^(BOOL pressed) { if (pressed) Perform(action); }];
    }
}
