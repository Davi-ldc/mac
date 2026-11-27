// Owns the picker's controller: which screen is showing, how its views are arranged, and
// what each key does.
#import <Carbon/Carbon.h>

#import "actionbar.h"
#import "actionmenu.h"
#import "bench.h"
#import "detailview.h"
#import "formview.h"
#import "listview.h"
#import "panel.h"
#import "picker.h"
#import "press.h"
#import "searchbar.h"
#import "theme.h"

@interface DKPicker () <NSTextFieldDelegate, NSWindowDelegate>
@end

@implementation DKPicker {
    DKPage *_root;
    NSImage *_logo;
    DKPanel *_panel;
    DKSearchBar *_searchBar;
    DKListView *_list;
    DKDetailView *_detail;
    DKFormView *_form;
    DKActionBar *_actionBar;
    DKActionMenu *_menu;
    NSMutableArray<DKScreen *> *_stack;
    /// ⏎ or the mouse button held on a row with a held action, and that row.
    DKPress *_press;
    DKItem *_pressedItem;
    /// ⏎ went down on a row with a held action and has not come up.
    BOOL _returnPressed;
}

- (instancetype)initWithRootPage:(DKPage *)page logo:(NSImage *)logo {
    if (!(self = [super init])) return nil;
    _root = page;
    _logo = logo;
    return self;
}

#pragma mark Views

- (void)build {
    _panel = [DKPanel new];
    _panel.delegate = self;
    __weak DKPicker *weakSelf = self;
    _panel.keyHandler = ^BOOL(NSEvent *event) { return [weakSelf handleKey:event]; };
    _panel.keyUpHandler = ^(NSEvent *event) { [weakSelf handleKeyUp:event]; };
    NSView *canvas = _panel.canvas;

    CGFloat body = DKPanelHeight - DKHeaderHeight;
    _list = [[DKListView alloc] initWithFrame:NSMakeRect(0, DKHeaderHeight, DKPanelWidth, body)];
    _list.onSelectionChange = ^(DKItem *item) { [weakSelf showSelection:item]; };
    _list.onActivate = ^(DKItem *item) { [weakSelf runAction:item.actions.firstObject]; };
    _list.onPress = ^(DKItem *item) { [weakSelf press:item]; };
    _list.onRelease = ^{ [weakSelf endPress]; };
    [canvas addSubview:_list];

    // Spans the header too: Raycast's detail pane starts its preview under the search bar.
    _detail = [[DKDetailView alloc] initWithFrame:NSMakeRect(DKPanelWidth - DKDetailWidth, 0, DKDetailWidth, DKPanelHeight)];
    [canvas addSubview:_detail];

    _form = [[DKFormView alloc] initWithFrame:canvas.bounds];
    [canvas addSubview:_form];

    _searchBar = [[DKSearchBar alloc] initWithLogo:_logo];
    _searchBar.field.delegate = self;
    _searchBar.onBack = ^{ [weakSelf pop]; };
    [canvas addSubview:_searchBar];

    _actionBar = [[DKActionBar alloc] initWithFrame:NSMakeRect(0, DKPanelHeight - DKFooterHeight, DKPanelWidth, DKFooterHeight)];
    _actionBar.onPrimary = ^{ [weakSelf runPrimary]; };
    _actionBar.onActions = ^{ [weakSelf toggleActions]; };
    [canvas addSubview:_actionBar];

    _menu = [[DKActionMenu alloc] initWithFrame:NSZeroRect];
    _menu.hidden = YES;
    _menu.onChoose = ^(DKAction *action) { [weakSelf runAction:action]; };
    [canvas addSubview:_menu];
    DKBenchMark("built");
}

#pragma mark Showing

- (BOOL)isVisible { return _panel.isVisible; }

- (void)warmUp {
    if (_panel) return;
    [self build];
    [self rest];
    // A first letter also sets up AppKit's text checking and the results' first layout,
    // which a rehearsal here takes off the user's first key press.
    [_searchBar.field.currentEditor insertText:@"a"];
    [self rest];
}

/// The root screen with an empty search, which is what a closed panel holds.
- (void)rest {
    [self endPress];
    _returnPressed = NO;
    _stack = [NSMutableArray arrayWithObject:_root];
    [self enterTop];
}

- (void)prepare:(DKScreen *)bottom {
    if (!_panel) [self build];
    _panel.level = NSFloatingWindowLevel;
    if (_stack.count == 1 && _stack.firstObject == bottom && !_searchBar.field.stringValue.length) {
        // Already on this screen, as a closed panel is on the root: only its rows may be stale.
        _menu.hidden = YES;
        [self refreshKeepingSelection:NO];
    } else {
        _stack = [NSMutableArray arrayWithObject:bottom];
        [self enterTop];
    }
    NSRect screen = NSScreen.mainScreen.visibleFrame;
    [_panel setFrameOrigin:NSMakePoint(NSMidX(screen) - DKPanelWidth / 2,
                                       NSMinY(screen) + screen.size.height * 0.62 - DKPanelHeight / 2)];
}

- (void)show { [self showScreen:_root]; }

- (void)showScreen:(DKScreen *)screen {
    NSRunningApplication *front = NSWorkspace.sharedWorkspace.frontmostApplication;
    if (front.processIdentifier != getpid()) _previousApplication = front;
    [self prepare:screen];
    // A panel can only keep keyboard focus while its app is active.
    [NSApp activate];
    [_panel makeKeyAndOrderFront:nil];
    [self focus:_form.hidden ? _searchBar.field : _form.firstField];
}

/// Gives `field` the keyboard unless it has it. Asking again would end its editing and start
/// it over, and at every start AppKit works out whether to offer passwords or one-time
/// codes for the field, building a window for the offer.
- (void)focus:(NSTextField *)field {
    if (!field.currentEditor) [_panel makeFirstResponder:field];
}

- (void)showForInspection:(DKScreen *)screen {
    [self prepare:screen ?: _root];
    _panel.level = CGWindowLevelForKey(kCGDesktopIconWindowLevelKey) + 1;
    [_panel orderFrontRegardless];
}

- (void)search:(NSString *)query {
    _searchBar.field.stringValue = query;
    [self refreshKeepingSelection:NO];
}

- (void)hide {
    [_panel orderOut:nil];
    // After the current event, which may be one of the panel's own delegate calls, and
    // after whatever the action that closed the panel goes on to do.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self->_panel.visible) [self rest];
    });
}

- (void)dismiss {
    [self hide];
    [_previousApplication activateWithOptions:0];
}

// Clicking another window already moved focus there, so there is nothing to give back.
- (void)windowDidResignKey:(NSNotification *)notification {
    // An inspection panel can pass through key status by accident and must stay up.
    if (_panel.level == NSFloatingWindowLevel) [self hide];
}

- (void)pushScreen:(DKScreen *)screen {
    [_stack addObject:screen];
    [self enterTop];
}

- (void)pop {
    if (_stack.count <= 1) return [self dismiss];
    [_stack removeLastObject];
    [self enterTop];
}

- (void)enterTop {
    [self endPress];
    _menu.hidden = YES;
    DKScreen *screen = _stack.lastObject;
    BOOL isForm = [screen isKindOfClass:DKForm.class];
    _searchBar.showsBack = screen != _root;
    _searchBar.showsField = !isForm;
    _searchBar.field.stringValue = @"";
    [_actionBar showScreen:screen != _root ? screen : nil];
    _form.hidden = !isForm;

    if (isForm) {
        DKForm *form = (DKForm *)screen;
        _list.hidden = _detail.hidden = YES;
        [_form showForm:form];
        [_actionBar showPrimaryTitle:form.submitTitle shortcut:[DKShortcut shortcutWithString:@"cmd+return"] hasMore:NO];
        [_panel makeFirstResponder:_form.firstField];
        return;
    }
    DKPage *page = (DKPage *)screen;
    [_searchBar setPlaceholder:page.placeholder];
    _list.hidden = NO;
    _detail.hidden = !page.showsDetail;
    NSRect frame = _list.frame;
    frame.size.width = page.showsDetail ? DKPanelWidth - DKDetailWidth : DKPanelWidth;
    _list.frame = frame;
    [self focus:_searchBar.field];
    [self refreshKeepingSelection:NO];
}

- (void)reload { [self refreshKeepingSelection:YES]; }

- (void)reloadIcons { [_list reloadIcons]; }

- (void)refreshKeepingSelection:(BOOL)keep {
    DKPage *page = (DKPage *)_stack.lastObject;
    if (![page isKindOfClass:DKPage.class]) return;
    NSArray<DKItem *> *items = page.items(_searchBar.field.stringValue);
    DKBenchMark("results");
    [_list setItems:items keepSelection:keep];
    DKBenchMark("listed");
}

- (void)showSelection:(DKItem *)item {
    if (item != _pressedItem) [self endPress];
    // Clicking another row while the Actions menu is open dismisses the menu, as in Raycast.
    _menu.hidden = YES;
    if (!_detail.hidden) [_detail showItem:item];
    DKAction *primary = item.actions.firstObject;
    [_actionBar showPrimaryTitle:primary.title shortcut:[DKShortcut shortcutWithString:@"return"] hasMore:primary != nil];
}

#pragma mark Actions

- (void)runPrimary {
    if (!_form.hidden) return [self submitForm];
    [self runAction:_list.selectedItem.actions.firstObject];
}

- (void)runAction:(DKAction *)action {
    if (!action) return;
    _menu.hidden = YES;
    action.handler();
}

/// Starts timing a press of ⏎ or the mouse button on `item`, which runs its held action if
/// it lasts. Rows without one have nothing to time.
- (void)press:(DKItem *)item {
    [self endPress];
    if (!item.heldAction) return;
    _pressedItem = item;
    [_list showPressed:YES];
    __weak DKPicker *weakSelf = self;
    _press = [[DKPress alloc] initWithSeconds:DKHoldSeconds held:^{
        [weakSelf endPress];
        [weakSelf runAction:item.heldAction];
    }];
}

/// Ends the press, if any: YES when it was a tap.
- (BOOL)endPress {
    if (!_press) return NO;
    BOOL tap = [_press end];
    _press = nil;
    _pressedItem = nil;
    [_list showPressed:NO];
    return tap;
}

- (void)toggleActions {
    NSArray<DKAction *> *actions = _list.selectedItem.actions;
    if (!_menu.hidden || !actions.count || !_form.hidden) {
        _menu.hidden = YES;
        [self focus:_form.hidden ? _searchBar.field : _form.firstField];
        return;
    }
    [_menu showActions:actions title:_list.selectedItem.actionsTitle anchoredAt:NSMakePoint(DKPanelWidth - DKInset, DKPanelHeight - DKInset)];
    _menu.hidden = NO;
    [_panel makeFirstResponder:_menu.filterField];
}

- (void)submitForm {
    DKForm *form = (DKForm *)_stack.lastObject;
    NSString *error = form.submit(_form.values);
    if (error) [_form showError:error];
    else [self pop];
}

#pragma mark Keyboard

- (BOOL)handleKey:(NSEvent *)event {
    NSEventModifierFlags modifiers = event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagShift |
                                                            NSEventModifierFlagOption | NSEventModifierFlagControl);
    unsigned short key = event.keyCode;
    BOOL plain = modifiers == 0;
    BOOL actionsKey = modifiers == NSEventModifierFlagCommand && [event.charactersIgnoringModifiers isEqualToString:@"k"];

    if (!_menu.hidden) {
        if (key == kVK_Escape || actionsKey) return [self toggleActions], YES;
        if (key == kVK_DownArrow) return [_menu moveSelection:1], YES;
        if (key == kVK_UpArrow) return [_menu moveSelection:-1], YES;
        if (key == kVK_Return && plain) return [self runAction:_menu.selectedAction], YES;
        for (DKAction *action in _list.selectedItem.actions)
            if (!plain && [action matchesEvent:event]) return [self runAction:action], YES;
        return NO;
    }

    if (!_form.hidden) {
        if (key == kVK_Escape) return [self pop], YES;
        if (key == kVK_Return && modifiers == NSEventModifierFlagCommand) return [self submitForm], YES;
        if (key == kVK_Return && plain) {
            if (![_form insertNewline] && ![_form focusNextField]) [self submitForm];
            return YES;
        }
        return NO;
    }

    if (key == kVK_Escape) {
        if (_searchBar.field.stringValue.length) {
            _searchBar.field.stringValue = @"";
            [self refreshKeepingSelection:NO];
        } else {
            [self pop];
        }
        return YES;
    }
    if (key == kVK_DownArrow) return [_list moveSelection:1], YES;
    if (key == kVK_UpArrow) return [_list moveSelection:-1], YES;
    if (key == kVK_Return && plain) {
        // A held ⏎ repeats; the repeats are part of the hold.
        if (event.isARepeat && _returnPressed) return YES;
        DKItem *item = _list.selectedItem;
        _returnPressed = item.heldAction != nil;
        if (_returnPressed) [self press:item];
        else [self runPrimary];
        return YES;
    }
    if (actionsKey) return [self toggleActions], YES;
    if (key == kVK_Delete && plain && !_searchBar.field.stringValue.length && _stack.count > 1) return [self pop], YES;
    for (DKAction *action in _list.selectedItem.actions)
        if (!plain && [action matchesEvent:event]) return [self runAction:action], YES;
    return NO;
}

- (void)handleKeyUp:(NSEvent *)event {
    if (event.keyCode != kVK_Return || !_returnPressed) return;
    _returnPressed = NO;
    DKItem *item = _pressedItem;
    if ([self endPress]) [self runAction:item.actions.firstObject];
}

- (void)controlTextDidChange:(NSNotification *)notification {
    DKBenchMark("query");
    if (notification.object == _searchBar.field) [self refreshKeepingSelection:NO];
}

@end
