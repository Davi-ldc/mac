// Native macOS window following system Light/Dark appearance with unified toolbar and global keyboard routing.
#import "ui/shell/window.h"
#import "render/icons.h"

@implementation SPWindow

- (instancetype)initWithContentRect:(NSRect)contentRect
                          styleMask:(NSWindowStyleMask)style
                            backing:(NSBackingStoreType)backingStoreType
                              defer:(BOOL)flag {
    if (!(self = [super initWithContentRect:contentRect styleMask:style backing:backingStoreType defer:flag])) return nil;
    // Follow macOS system appearance (Light & Dark) automatically; never force DarkAqua.
    // Transparent full-size-content titlebar hosts our lightweight native glass controls without NSToolbar RAM bloat.
    self.titleVisibility = NSWindowTitleHidden;
    self.titlebarAppearsTransparent = YES;
    self.backgroundColor = SPWindowBackgroundColor();
    self.movableByWindowBackground = NO;
    self.minSize = NSMakeSize(760.0, 520.0);
    self.releasedWhenClosed = NO;
    return self;
}

- (BOOL)isEditingText {
    NSResponder *fr = self.firstResponder;
    if (!fr) return NO;
    return [fr isKindOfClass:NSText.class] || [fr isKindOfClass:NSTextField.class];
}

- (BOOL)handleKeyEvent:(NSEvent *)event {
    if (event.type != NSEventTypeKeyDown) return NO;
    NSEventModifierFlags mods = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    NSString *chars = event.charactersIgnoringModifiers.lowercaseString ?: @"";

    // Space toggles play/pause ONLY when not editing text.
    if (event.keyCode == 49 && mods == 0) {
        if (![self isEditingText] && _onSpaceTogglePlayPause) {
            _onSpaceTogglePlayPause();
            return YES;
        }
        return NO;
    }

    // Cmd+K / Cmd+L / Cmd+F focus toolbar search with text selected.
    if (mods == NSEventModifierFlagCommand &&
        ([chars isEqualToString:@"k"] || [chars isEqualToString:@"l"] || [chars isEqualToString:@"f"])) {
        if (_onFocusSearch) {
            _onFocusSearch();
            return YES;
        }
    }

    // Cmd+[ / Cmd+] Back / Forward.
    if (mods == NSEventModifierFlagCommand && [chars isEqualToString:@"["]) {
        if (_onNavigateBack) { _onNavigateBack(); return YES; }
    }
    if (mods == NSEventModifierFlagCommand && [chars isEqualToString:@"]"]) {
        if (_onNavigateForward) { _onNavigateForward(); return YES; }
    }

    return NO;
}

- (BOOL)performKeyEquivalent:(NSEvent *)event {
    if (event.type == NSEventTypeKeyDown && [self isEditingText]) {
        NSEventModifierFlags mods = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
        NSEventModifierFlags cleanMods = mods & ~NSEventModifierFlagNumericPad & ~NSEventModifierFlagFunction;
        NSString *chars = event.charactersIgnoringModifiers ?: @"";
        unichar key = chars.length ? [chars characterAtIndex:0] : 0;
        BOOL shift = (cleanMods & NSEventModifierFlagShift) != 0;
        if ((cleanMods & NSEventModifierFlagCommand) != 0 &&
            (cleanMods & ~(NSEventModifierFlagCommand | NSEventModifierFlagShift)) == 0) {
            SEL sel = NULL;
            if (key == NSLeftArrowFunctionKey) sel = shift ? @selector(moveToBeginningOfLineAndModifySelection:) : @selector(moveToBeginningOfLine:);
            else if (key == NSRightArrowFunctionKey) sel = shift ? @selector(moveToEndOfLineAndModifySelection:) : @selector(moveToEndOfLine:);
            else if (key == NSUpArrowFunctionKey) sel = shift ? @selector(moveToBeginningOfDocumentAndModifySelection:) : @selector(moveToBeginningOfDocument:);
            else if (key == NSDownArrowFunctionKey) sel = shift ? @selector(moveToEndOfDocumentAndModifySelection:) : @selector(moveToEndOfDocument:);
            if (sel && [self.firstResponder respondsToSelector:sel]) {
                [self.firstResponder doCommandBySelector:sel];
                return YES;
            }
        }
    }
    return [super performKeyEquivalent:event];
}

- (void)sendEvent:(NSEvent *)event {
    if (event.type == NSEventTypeKeyDown && [self handleKeyEvent:event]) {
        return;
    }
    [super sendEvent:event];
}

@end
