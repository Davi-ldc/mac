// System-wide keyboard shortcuts.
#import <Carbon/Carbon.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^DKHotkeyHandler)(BOOL pressed);

/// A shortcut through Carbon's hotkey API, which needs no Accessibility permission and
/// costs nothing until the key is pressed. Reports press and release. A registered
/// hotkey stays alive until unregistered.
@interface DKHotkey : NSObject
/// Returns nil when registration fails. Carbon does not refuse a shortcut another app
/// holds; the most recent registration receives it.
+ (nullable instancetype)key:(UInt32)keyCode modifiers:(UInt32)carbonModifiers handler:(DKHotkeyHandler)handler;
- (void)unregister;
@end

NS_ASSUME_NONNULL_END
