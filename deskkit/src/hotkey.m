// Owns the Carbon hotkey registry behind every global shortcut.
#import "hotkey.h"

static NSMutableDictionary<NSNumber *, DKHotkey *> *registered;
static UInt32 nextID = 1;

@implementation DKHotkey {
    EventHotKeyRef _ref;
    DKHotkeyHandler _handler;
    UInt32 _id;
}

static OSStatus HandleHotkey(EventHandlerCallRef next, EventRef event, void *data) {
    EventHotKeyID hotkeyID;
    GetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID, NULL, sizeof hotkeyID,
                      NULL, &hotkeyID);
    DKHotkey *hotkey = registered[@(hotkeyID.id)];
    if (hotkey) hotkey->_handler(GetEventKind(event) == kEventHotKeyPressed);
    return noErr;
}

+ (instancetype)key:(UInt32)keyCode modifiers:(UInt32)modifiers handler:(DKHotkeyHandler)handler {
    if (!registered) {
        registered = [NSMutableDictionary new];
        EventTypeSpec kinds[] = {{kEventClassKeyboard, kEventHotKeyPressed},
                                 {kEventClassKeyboard, kEventHotKeyReleased}};
        InstallApplicationEventHandler(HandleHotkey, 2, kinds, NULL, NULL);
    }
    DKHotkey *hotkey = [DKHotkey new];
    hotkey->_handler = [handler copy];
    hotkey->_id = nextID++;
    EventHotKeyID hotkeyID = {'dkit', hotkey->_id};
    if (RegisterEventHotKey(keyCode, modifiers, hotkeyID, GetApplicationEventTarget(), 0,
                            &hotkey->_ref) != noErr) {
        fprintf(stderr, "deskkit: cannot register shortcut %u/%u\n", keyCode, modifiers);
        return nil;
    }
    registered[@(hotkey->_id)] = hotkey;
    return hotkey;
}

- (void)unregister {
    if (!_ref) return;
    UnregisterEventHotKey(_ref);
    _ref = NULL;
    [registered removeObjectForKey:@(_id)];
}

@end
