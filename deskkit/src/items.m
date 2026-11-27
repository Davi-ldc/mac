// Owns the picker's data types and shortcut parsing.
#import <Carbon/Carbon.h>

#import "items.h"

@implementation DKShortcut {
    NSEventModifierFlags _modifiers;
    /// A lowercase character, or one of "return", "delete", "tab", "space".
    NSString *_key;
}

static const NSEventModifierFlags kRelevant =
    NSEventModifierFlagCommand | NSEventModifierFlagShift | NSEventModifierFlagOption | NSEventModifierFlagControl;

+ (instancetype)shortcutWithString:(NSString *)spec {
    DKShortcut *shortcut = [DKShortcut new];
    NSDictionary *modifiers = @{@"cmd" : @(NSEventModifierFlagCommand), @"shift" : @(NSEventModifierFlagShift),
                                @"opt" : @(NSEventModifierFlagOption), @"ctrl" : @(NSEventModifierFlagControl)};
    for (NSString *part in [spec.lowercaseString componentsSeparatedByString:@"+"]) {
        NSNumber *flag = modifiers[part];
        if (flag) shortcut->_modifiers |= flag.unsignedIntegerValue;
        else shortcut->_key = part;
    }
    return shortcut->_key ? shortcut : nil;
}

- (BOOL)matchesEvent:(NSEvent *)event {
    if ((event.modifierFlags & kRelevant) != _modifiers) return NO;
    NSDictionary *named = @{@"return" : @(kVK_Return), @"delete" : @(kVK_Delete), @"tab" : @(kVK_Tab), @"space" : @(kVK_Space)};
    NSNumber *code = named[_key];
    if (code) return event.keyCode == code.unsignedShortValue;
    return [event.charactersIgnoringModifiers.lowercaseString isEqualToString:_key];
}

- (NSArray<NSString *> *)keycaps {
    NSMutableArray *caps = [NSMutableArray new];
    // Apple's order for modifier glyphs.
    if (_modifiers & NSEventModifierFlagControl) [caps addObject:@"⌃"];
    if (_modifiers & NSEventModifierFlagOption) [caps addObject:@"⌥"];
    if (_modifiers & NSEventModifierFlagShift) [caps addObject:@"⇧"];
    if (_modifiers & NSEventModifierFlagCommand) [caps addObject:@"⌘"];
    NSDictionary *glyphs = @{@"return" : @"↵", @"delete" : @"⌫", @"tab" : @"⇥", @"space" : @"␣"};
    [caps addObject:glyphs[_key] ?: _key.uppercaseString];
    return caps;
}

@end

@implementation DKAction

+ (instancetype)actionWithTitle:(NSString *)title symbol:(NSString *)symbol shortcut:(NSString *)shortcut
                        handler:(void (^)(void))handler {
    DKAction *action = [DKAction new];
    action->_title = [title copy];
    action->_symbol = [symbol copy];
    action->_shortcut = shortcut ? [DKShortcut shortcutWithString:shortcut] : nil;
    action.handler = handler;
    return action;
}

- (BOOL)matchesEvent:(NSEvent *)event {
    if ([_shortcut matchesEvent:event]) return YES;
    for (DKShortcut *shortcut in _otherShortcuts)
        if ([shortcut matchesEvent:event]) return YES;
    return NO;
}

@end

@implementation DKDetail
@end

@implementation DKItem

- (NSArray<DKAction *> *)actions {
    if (!_actions && _actionsLoader) _actions = [_actionsLoader() copy];
    return _actions;
}

@end

@implementation DKScreen
@end

@implementation DKPage
@end

@implementation DKFormField

+ (instancetype)fieldWithLabel:(NSString *)label placeholder:(NSString *)placeholder value:(NSString *)value {
    DKFormField *field = [DKFormField new];
    field->_label = [label copy];
    field->_placeholder = [placeholder copy];
    field->_value = [value copy];
    return field;
}

@end

@implementation DKForm
@end
