// Owns the confirmation modal: its layout, opening, keys and closing.
#import "render/strings.h"
#import "ui/kit/button.h"
#import "ui/kit/dialog.h"
#import "ui/kit/label.h"
#import "ui/kit/overlay.h"
#import "ui/kit/popover.h"

/// components.json modal: 520 wide, radius 8; the title bar 70 tall with 20/28 padding and a
/// 22 pt black title; the 36 pt close button 20 pt from the top right; content 28 pt in; the
/// footer 84 tall with 24/28 padding; medium buttons 36 tall, at least 80 wide, 12 pt padding.
static const CGFloat kDefaultWidth = 520, kSide = 28, kTitleBar = 70, kTitleTop = 20, kTitleLine = 30, kClose = 36, kCloseInset = 20;
static const CGFloat kTextLine = 22, kAccessoryGap = 16, kFooter = 84, kFooterPad = 24, kButtonHeight = 36, kButtonMinimum = 80;
static const CGFloat kButtonPadding = 12, kButtonGap = 12;
static const SNColorToken kBackdrop = SNColorBaseModal, kDanger = SNColorBaseInvImp;
static const CFTimeInterval kOpen = 0.08;
static const unsigned short kEscape = 53, kReturn = 36;

@interface SNDialogBackdrop : NSView
@property (nonatomic, copy) void (^clicked)(void);
@end

@implementation SNDialogBackdrop
- (BOOL)isFlipped { return YES; }
- (void)mouseDown:(NSEvent *)event { self.clicked(); }
@end

@interface SNDialogContent : NSView
@end

@implementation SNDialogContent
- (BOOL)isFlipped { return YES; }
@end

static SNButton *MediumButton(SNButton *button) {
    button.font = SNFont(SNFontSizeBase, SNFontWeightBold);
    return button;
}

/// c-alert--level_error inside a dialog: 12 pt in, 8 pt corners, 16 pt over the footer.
static const CGFloat kNotePadding = 12, kNoteGap = 16;

@implementation SNConfirmDialog {
    SNDialogBackdrop *_backdrop;
    SNPanelView *_panel;
    SNDialogContent *_content;
    SNLabel *_heading, *_question, *_note;
    NSView *_accessory, *_noteBox;
    SNButton *_close, *_cancelButton, *_confirmButton;
    BOOL _alert, _danger, _waiting, _confirmEnabled;
    SNColorToken _confirmFill, _confirmContent;
    void (^_completion)(BOOL);
    void (^_perform)(void (^)(NSString *));
    id _monitor;
    BOOL _returnArmed;
    CGFloat _width;
}

- (instancetype)init {
    if ((self = [super init])) _confirmEnabled = YES;
    return self;
}

static SNConfirmDialog *current;

+ (SNConfirmDialog *)current { return current; }

+ (instancetype)showInWindow:(NSWindow *)window
                       title:(NSString *)title
                        text:(NSString *)text
                   accessory:(NSView *)accessory
                confirmTitle:(NSString *)confirmTitle
                  completion:(void (^)(BOOL))completion {
    [current cancel];
    SNConfirmDialog *dialog = [self new];
    dialog->_completion = [completion copy];
    dialog->_danger = YES;
    [dialog buildInHost:[SNOverlayHost hostForWindow:window] title:title text:text accessory:accessory confirmTitle:confirmTitle];
    current = dialog;
    return dialog;
}

+ (instancetype)showAlertInWindow:(NSWindow *)window title:(NSString *)title text:(NSString *)text buttonTitle:(NSString *)buttonTitle {
    [current cancel];
    SNConfirmDialog *dialog = [self new];
    dialog->_alert = YES;
    [dialog buildInHost:[SNOverlayHost hostForWindow:window] title:title text:text accessory:nil confirmTitle:buttonTitle];
    current = dialog;
    return dialog;
}

+ (instancetype)showInWindow:(NSWindow *)window
                       title:(NSString *)title
                        text:(NSString *)text
                   accessory:(NSView *)accessory
                confirmTitle:(NSString *)confirmTitle
                      danger:(BOOL)danger
                     perform:(void (^)(void (^)(NSString *)))perform {
    [current cancel];
    SNConfirmDialog *dialog = [self new];
    dialog->_perform = [perform copy];
    dialog->_danger = danger;
    [dialog buildInHost:[SNOverlayHost hostForWindow:window] title:title text:text accessory:accessory confirmTitle:confirmTitle];
    current = dialog;
    return dialog;
}

+ (instancetype)showFormInWindow:(NSWindow *)window
                           title:(NSString *)title
                       accessory:(NSView *)accessory
                           width:(CGFloat)width
                    confirmTitle:(NSString *)confirmTitle
                       confirmed:(void (^)(void))confirmed {
    [current cancel];
    SNConfirmDialog *dialog = [self new];
    dialog->_width = width;
    dialog->_completion = ^(BOOL ok) {
        if (ok) confirmed();
    };
    [dialog buildInHost:[SNOverlayHost hostForWindow:window] title:title text:nil accessory:accessory confirmTitle:confirmTitle];
    current = dialog;
    return dialog;
}

- (NSView *)panel { return _panel; }

- (void)accessoryHeightChanged { [self layoutPanelIn:_panel.superview.bounds]; }
- (NSString *)errorText { return _noteBox ? _note.text : nil; }

- (void)buildInHost:(SNOverlayHost *)host title:(NSString *)title text:(NSString *)text accessory:(NSView *)accessory confirmTitle:(NSString *)confirmTitle {
    __weak SNConfirmDialog *weakSelf = self;
    if (!_width) _width = kDefaultWidth;
    _backdrop = [[SNDialogBackdrop alloc] initWithFrame:host.bounds];
    _backdrop.wantsLayer = YES;
    _backdrop.layer.backgroundColor = SNCGColor(kBackdrop);
    _backdrop.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _backdrop.clicked = ^{ [weakSelf cancel]; };
    [host addSubview:_backdrop];

    CGFloat inner = _width - 2 * kSide;
    SNLabel *heading = _heading = [SNLabel labelWithText:title font:SNFont(SNFontSizeTitle, SNFontWeightBlack) color:SNColorContentPry];
    heading.lineHeight = kTitleLine;
    heading.frame = NSMakeRect(kSide, kTitleTop, inner - kClose, kTitleLine);
    _question = [SNLabel labelWithText:text ?: @"" font:SNFont(SNFontSizeBase, SNFontWeightRegular) color:SNColorContentPry];
    _question.lineHeight = kTextLine;
    _question.maximumLines = 0;
    _accessory = accessory;

    SNShadowStack shadow = {2, {{0, 0, 0, 1, 0xe8e8e821, NO}, {0, 18, 48, 0, 0x00000059, NO}}};
    _panel = [[SNPanelView alloc] initWithFill:SNColorBasePry radius:SNRadiusLarge shadow:shadow];
    _panel.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin | NSViewMaxYMargin;
    _content = [[SNDialogContent alloc] initWithFrame:NSZeroRect];
    _content.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [_panel.contentView addSubview:_content];

    _close = [SNButton iconButtonNamed:@"close" size:kClose iconSize:20];
    // .c-sk-modal__close_button:hover lays base-pry-hover over the icon button's base-ter.
    _close.hoverColor = SNOverlayHover;
    _close.tooltip = SNLocalized(@"channel.dialog.close");
    _close.frame = NSMakeRect(_width - kCloseInset - kClose, kTitleTop + (kTitleLine - kClose) / 2, kClose, kClose);
    _close.action = ^(SNButton *button) { [weakSelf cancel]; };
    _cancelButton = MediumButton([SNButton outlineButtonWithTitle:SNLocalized(@"channel.dialog.cancel")]);
    _cancelButton.action = ^(SNButton *button) {
        SNConfirmDialog *dialog = weakSelf;
        if (dialog.cancelAction) dialog.cancelAction();
        else [dialog cancel];
    };
    _confirmButton = MediumButton([SNButton primaryButtonWithTitle:confirmTitle]);
    if (_danger) {
        _confirmButton.fillColor = _confirmButton.hoverFillColor = kDanger;
        _confirmButton.hoverColor = SNColorBaseImpHover;
        _confirmButton.pressedColor = SNColorBaseImpPressed;
    }
    _confirmButton.action = ^(SNButton *button) { [weakSelf confirm]; };
    _confirmFill = _confirmButton.fillColor;
    _confirmContent = _confirmButton.contentColor;
    _cancelButton.hidden = _alert;
    for (NSView *view in @[ heading, _close, _question, _cancelButton, _confirmButton ]) [_content addSubview:view];
    if (accessory) [_content addSubview:accessory];
    [self layoutPanelIn:host.bounds];
    [host addSubview:_panel];

    for (CALayer *layer in @[ _backdrop.layer, _panel.layer ]) {
        CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
        fade.fromValue = @0;
        fade.toValue = @1;
        fade.duration = kOpen;
        [layer addAnimation:fade forKey:@"open"];
    }
    // Scaled about the dialog's centre: its layer's anchor is the corner.
    CGFloat height = NSHeight(_panel.frame);
    CABasicAnimation *scale = [CABasicAnimation animationWithKeyPath:@"transform"];
    CATransform3D small = CATransform3DMakeTranslation(_width * 0.025, height * 0.025, 0);
    scale.fromValue = [NSValue valueWithCATransform3D:CATransform3DScale(small, 0.95, 0.95, 1)];
    scale.toValue = [NSValue valueWithCATransform3D:CATransform3DIdentity];
    scale.duration = kOpen;
    scale.timingFunction = SNEaseDefault();
    [_panel.layer addAnimation:scale forKey:@"scale"];

    // A Return still held from what opened the dialog (saving an emptied edit) must not delete:
    // only a press that starts after it opened confirms.
    NSEvent *opening = NSApp.currentEvent;
    _returnArmed = !(opening.type == NSEventTypeKeyDown && opening.keyCode == kReturn);
    _monitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown | NSEventMaskKeyUp handler:^NSEvent *(NSEvent *event) {
        SNConfirmDialog *dialog = weakSelf;
        return dialog && [dialog handleKeyEvent:event] ? nil : event;
    }];
}

/// Stacks the question, the accessory and the red note under the title bar, the footer under
/// them, and centres the dialog in `bounds` at that height.
- (void)layoutPanelIn:(NSRect)bounds {
    CGFloat inner = _width - 2 * kSide;
    _question.frame = NSMakeRect(kSide, kTitleBar, inner, _question.text.length ? [_question heightForWidth:inner] : 0);
    CGFloat y = NSMaxY(_question.frame);
    CGFloat noteHeight = 0, noteTextHeight = 0;
    if (_noteBox) {
        noteTextHeight = [_note heightForWidth:inner - 2 * kNotePadding];
        noteHeight = kNoteGap + noteTextHeight + 2 * kNotePadding;
    }
    if (_accessory) {
        CGFloat accessoryY = y + (_question.text.length ? kAccessoryGap : 0);
        CGFloat maxAccessory = MAX(48, bounds.size.height - 32 - accessoryY - noteHeight - kFooter);
        CGFloat accessoryHeight = MIN(_accessory.frame.size.height, maxAccessory);
        _accessory.frame = NSMakeRect(kSide, accessoryY, inner, accessoryHeight);
        y = NSMaxY(_accessory.frame);
    }
    if (_noteBox) {
        _noteBox.frame = NSMakeRect(kSide, y + kNoteGap, inner, noteTextHeight + 2 * kNotePadding);
        _note.frame = NSMakeRect(kNotePadding, kNotePadding, inner - 2 * kNotePadding, noteTextHeight);
        y = NSMaxY(_noteBox.frame);
    }
    CGFloat height = y + kFooter;
    _panel.frame = NSMakeRect(round((bounds.size.width - _width) / 2), round(MAX(0, bounds.size.height - height) / 2), _width, height);
    _content.frame = _panel.contentView.bounds;
    CGFloat right = _width - kSide, buttonY = height - kFooterPad - kButtonHeight;
    for (SNButton *button in _alert ? @[ _confirmButton ] : @[ _confirmButton, _cancelButton ]) {
        CGFloat width = MAX(kButtonMinimum, ceil(button.fittingContentSize.width) + 2 * kButtonPadding);
        button.frame = NSMakeRect(right - width, buttonY, width, kButtonHeight);
        right -= width + kButtonGap;
    }
}

- (BOOL)confirmEnabled { return _confirmEnabled; }

// A disabled c-button keeps its size and turns ctr-sec with dimmed text.
- (void)setConfirmEnabled:(BOOL)enabled {
    _confirmEnabled = enabled;
    _confirmButton.enabled = !_waiting && enabled;
    _confirmButton.fillColor = _confirmButton.hoverFillColor = enabled ? _confirmFill : SNColorCtrSec;
    _confirmButton.contentColor = _confirmButton.hoverContentColor = enabled ? _confirmContent : SNColorContentTer;
}

- (void)showStepTitled:(NSString *)title text:(NSString *)text accessory:(NSView *)accessory confirmTitle:(NSString *)confirmTitle cancelTitle:(NSString *)cancelTitle {
    _heading.text = title;
    _question.text = text ?: @"";
    if (accessory != _accessory) {
        [_accessory removeFromSuperview];
        _accessory = accessory;
        if (accessory) [_content addSubview:accessory];
    }
    _confirmButton.title = confirmTitle;
    _cancelButton.title = cancelTitle ?: SNLocalized(@"channel.dialog.cancel");
    [_noteBox removeFromSuperview];
    _noteBox = nil;
    [self layoutPanelIn:_panel.superview.bounds];
}

- (void)setWaiting:(BOOL)waiting {
    _waiting = waiting;
    _confirmButton.enabled = !waiting && _confirmEnabled;
}

- (BOOL)waiting { return _waiting; }

- (void)close { [self closeConfirmed:YES]; }

- (void)showError:(NSString *)error {
    if (!error) {
        [_noteBox removeFromSuperview];
        _noteBox = nil;
        [self layoutPanelIn:_panel.superview.bounds];
        return;
    }
    if (!_noteBox) {
        _noteBox = [[NSView alloc] initWithFrame:NSZeroRect];
        _noteBox.wantsLayer = YES;
        _noteBox.layer.backgroundColor = SNCGColor(SNColorSurfImp);
        _noteBox.layer.borderColor = SNCGColor(SNColorOtlImp);
        _noteBox.layer.borderWidth = 1;
        _noteBox.layer.cornerRadius = 8;
        _note = [SNLabel labelWithText:@"" font:SNFont(SNFontSizeBase, SNFontWeightRegular) color:SNColorContentPry];
        _note.lineHeight = kTextLine;
        _note.maximumLines = 0;
        [_noteBox addSubview:_note];
        [_content addSubview:_noteBox];
    }
    _note.text = error;
    [self layoutPanelIn:_panel.superview.bounds];
}

- (BOOL)handleKeyEvent:(NSEvent *)event {
    if (event.keyCode != kEscape && event.keyCode != kReturn) return NO;
    // A select's list or a suggestion list open over the dialog takes these keys itself.
    if (SNPopover.current || (self.passesKey && self.passesKey(event))) return NO;
    if (event.type == NSEventTypeKeyUp) {
        if (event.keyCode == kReturn) _returnArmed = YES;
        return NO;
    }
    if (event.keyCode == kEscape) [self cancel];
    else if (_returnArmed && !event.isARepeat) [self confirm];
    // Repeats stop here too, so they never reach the text view under the dialog.
    return YES;
}

- (void)confirm {
    if (!self.confirmEnabled || _waiting) return;
    if (self.confirmAction) return self.confirmAction();
    if (!_perform) return [self closeConfirmed:YES];
    if (_waiting || !self.confirmEnabled || !_panel.superview) return;
    _waiting = YES;
    _confirmButton.enabled = NO;
    __weak SNConfirmDialog *weakSelf = self;
    _perform(^(NSString *error) {
        SNConfirmDialog *dialog = weakSelf;
        if (!dialog) return;
        dialog->_waiting = NO;
        if (!error) return [dialog closeConfirmed:YES];
        // Slack's dialogs keep the button off until something changes after a refusal.
        dialog.confirmEnabled = NO;
        [dialog showError:error];
    });
}

- (void)cancel { [self closeConfirmed:NO]; }

- (void)closeConfirmed:(BOOL)confirmed {
    if (!_panel.superview) return;
    if (current == self) current = nil;
    // A list or calendar opened from the dialog goes with it.
    [SNPopover.current close];
    [NSEvent removeMonitor:_monitor];
    _monitor = nil;
    [_backdrop removeFromSuperview];
    [_panel removeFromSuperview];
    void (^completion)(BOOL) = _completion;
    _completion = nil;
    _perform = nil;
    if (completion) completion(confirmed);
}

@end
