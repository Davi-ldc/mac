// Other apps' windows through Accessibility: one shared stream of window events, and the
// queries the window rules make. deskkit's own process never appears in either, since an
// Accessibility call into itself would wait on its own main thread.
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, DKWindowEvent) {
    DKWindowCreated,
    DKWindowDestroyed,
    /// The app's focused window changed to `window`.
    DKWindowFocused,
    DKWindowMinimized,
    /// The app came to the front; `window` is NULL.
    DKAppActivated,
    /// The app quit, taking its windows without a destroy event for each; `window` is NULL.
    DKAppTerminated,
};

typedef void (^DKWindowEventHandler)(DKWindowEvent event, AXUIElementRef _Nullable window, pid_t pid);

/// The first handler starts watching every regular app: those running, those launched
/// later, and those whose Accessibility was not ready (or not yet allowed) at first try.
void DKObserveWindows(DKWindowEventHandler handler);

/// The app's windows on the current Space, as AXUIElementRefs.
NSArray *DKAppWindows(pid_t pid);
/// The app's focused window, or NULL. Caller releases.
AXUIElementRef _Nullable DKCopyFocusedWindow(pid_t pid);
BOOL DKIsStandardWindow(AXUIElementRef window);
pid_t DKWindowOwner(AXUIElementRef window);
/// The window server's id for an Accessibility window, or 0.
CGWindowID DKWindowID(AXUIElementRef window);
/// The window server's normal windows (layer 0), front to back: those on the current Space,
/// or all of them, including windows on other Spaces and parked off screen.
NSArray<NSDictionary *> *DKWindowList(BOOL currentSpaceOnly);

NS_ASSUME_NONNULL_END
