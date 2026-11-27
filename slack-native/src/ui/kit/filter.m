// Owns the filter field's look, its states and its keys.
#import "render/icon.h"
#import "ui/kit/button.h"
#import "ui/kit/filter.h"

static const CGFloat kRadius = 8, kGlyph = 16;
/// c-filter_input__right_icons: 20 pt wide inside the right padding, the clear glyph 18 pt (it
/// takes the button's 18 px font size).
static const CGFloat kRightIcons = 20, kClearGlyph = 18;
/// The ring's line, and its band in the line's colour at 30%.
static const CGFloat kRing = 1, kBand = SNFocusRingReach;
static const SNColorToken kBandColor = (SNColorOtlHgl1 & 0xffffff00) | 0x4c;

@implementation SNFocusRingLayer {
    SNLayer *_band, *_line;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _band = [SNLayer layer];
    _band.borderColor = SNCGColor(kBandColor);
    _band.borderWidth = kBand - kRing;
    _line = [SNLayer layer];
    _line.borderColor = SNCGColor(SNColorOtlHgl1);
    _line.borderWidth = kRing;
    [self addSublayer:_band];
    [self addSublayer:_line];
    return self;
}

- (void)setRingAroundRect:(CGRect)rect radius:(CGFloat)radius {
    self.frame = CGRectInset(rect, -kBand, -kBand);
    _band.frame = self.bounds;
    _band.cornerRadius = radius + kBand;
    _line.frame = CGRectInset(self.bounds, kBand - kRing, kBand - kRing);
    _line.cornerRadius = radius + kRing;
}

@end

/// Tells the field when it takes the caret (AppKit says nothing until the first edit).
@interface SNFilterTextField : NSTextField
@property (nonatomic, copy, nullable) void (^becameFirstResponder)(void);
@end

@implementation SNFilterTextField
- (BOOL)becomeFirstResponder {
    BOOL became = [super becomeFirstResponder];
    if (became && self.becameFirstResponder) self.becameFirstResponder();
    return became;
}
@end

@interface SNFilterField () <NSTextFieldDelegate>
@end

@implementation SNFilterField {
    SNLayer *_box;
    SNFocusRingLayer *_ring;
    SNIconLayer *_glyph;
    SNButton *_clear;
    BOOL _editing;
}

- (instancetype)initWithPlaceholder:(NSString *)placeholder {
    if (!(self = [super initWithFrame:NSZeroRect])) return nil;
    self.wantsLayer = YES;
    // The ring reaches past the bounds.
    self.clipsToBounds = NO;
    // Measured on the DMs capture: the glyph centred 17 pt from the left, the text from 34 pt.
    _glyphCentre = 17;
    _textX = 34;
    _glyphColor = SNThemeContentInvSec;
    _ring = [SNFocusRingLayer layer];
    _ring.opacity = 0;
    _box = [SNLayer layer];
    _box.backgroundColor = SNCGColor(SNThemeSurfInvSec);
    _box.borderColor = SNCGColor(SNThemeOtlInvPry);
    _box.borderWidth = 1;
    _box.cornerRadius = kRadius;
    for (CALayer *layer in @[ _ring, _box ]) [self.layer addSublayer:layer];
    _glyph = [SNIconLayer iconNamed:@"quick-switch" size:kGlyph color:_glyphColor];
    [self.layer addSublayer:_glyph];

    SNFilterTextField *field = [SNFilterTextField textFieldWithString:@""];
    __weak SNFilterField *weakSelf = self;
    field.becameFirstResponder = ^{ [weakSelf setEditing:YES]; };
    _textField = field;
    _textField.bordered = NO;
    _textField.drawsBackground = NO;
    _textField.focusRingType = NSFocusRingTypeNone;
    _textField.font = SNFont(SNFontSizeCaption, SNFontWeightRegular);
    _textField.textColor = SNColor(SNThemeContentInvPry);
    _textField.placeholderAttributedString = [[NSAttributedString alloc] initWithString:placeholder attributes:@{
        NSFontAttributeName : SNFont(SNFontSizeCaption, SNFontWeightRegular),
        NSForegroundColorAttributeName : SNColor(SNThemeContentInvSec),
    }];
    _textField.cell.scrollable = YES;
    _textField.delegate = self;
    [self addSubview:_textField];

    // Themed, the clear glyph is the text's colour and does not change under the pointer.
    _clear = [SNButton iconButtonNamed:@"close-circle-filled" size:kClearGlyph iconSize:kClearGlyph];
    _clear.contentColor = _clear.hoverContentColor = _clear.pressedContentColor = SNThemeContentInvPry;
    _clear.hoverFillColor = 0;
    _clear.hoverColor = _clear.pressedColor = 0;
    _clear.hidden = YES;
    _clear.action = ^(SNButton *button) {
        SNFilterField *filter = weakSelf;
        [filter clearText];
        [filter focus];
    };
    [_clear stateDidChange];
    [self addSubview:_clear];
    return self;
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

- (BOOL)isFlipped { return YES; }

- (NSView *)clearButton { return _clear; }

- (NSString *)text { return _textField.stringValue; }

- (void)setText:(NSString *)text {
    _textField.stringValue = text ?: @"";
    _clear.hidden = !_textField.stringValue.length;
}

- (void)setGlyphCentre:(CGFloat)glyphCentre {
    _glyphCentre = glyphCentre;
    self.needsLayout = YES;
}

- (void)setTextX:(CGFloat)textX {
    _textX = textX;
    self.needsLayout = YES;
}

- (void)setGlyphColor:(SNColorToken)glyphColor {
    _glyphColor = glyphColor;
    _glyph.color = glyphColor;
}

- (void)layout {
    [super layout];
    NSSize size = self.bounds.size;
    // The CSS padding p puts the glyph's centre at 1 + p + 8 and the right icons p from the far
    // border; the input's own padding is what is left between the glyph and textX.
    CGFloat padding = self.glyphCentre - 1 - kGlyph / 2, inputPadding = self.textX - self.glyphCentre - kGlyph / 2;
    CGFloat icons = size.width - 1 - padding - kRightIcons;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _box.frame = CGRectMake(0, 0, size.width, size.height);
    [_ring setRingAroundRect:_box.frame radius:kRadius];
    _glyph.frame = CGRectMake(self.glyphCentre - kGlyph / 2, (size.height - kGlyph) / 2, kGlyph, kGlyph);
    [CATransaction commit];
    CGFloat height = ceil(self.textField.intrinsicContentSize.height);
    // NSTextField's cell insets its text by 2 pt.
    self.textField.frame = NSMakeRect(self.textX - 2, (size.height - height) / 2, MAX(0, icons - inputPadding - self.textX + 4), height);
    _clear.frame = NSMakeRect(icons, (size.height - kClearGlyph) / 2, kClearGlyph, kClearGlyph);
}

#pragma mark Focus

- (void)focus { [self.window makeFirstResponder:_textField]; }

- (BOOL)isFocused { return _editing; }

/// A click on the field's padding or glyph gives the input the caret, as Slack's does.
- (void)mouseDown:(NSEvent *)event { [self focus]; }

- (void)viewWillMoveToWindow:(NSWindow *)window {
    [NSNotificationCenter.defaultCenter removeObserver:self name:NSWindowDidBecomeKeyNotification object:nil];
    [NSNotificationCenter.defaultCenter removeObserver:self name:NSWindowDidResignKeyNotification object:nil];
    if (!window) return;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(windowKeyChanged:) name:NSWindowDidBecomeKeyNotification object:window];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(windowKeyChanged:) name:NSWindowDidResignKeyNotification object:window];
}

/// The browser blurs the input while its window is in the background: the ring goes with it.
- (void)windowKeyChanged:(NSNotification *)notification { [self showRing]; }

- (void)setEditing:(BOOL)editing {
    _editing = editing;
    [self showRing];
}

- (void)showRing {
    BOOL ring = _editing && self.window.isKeyWindow;
    // The border turns transparent and the ring shows in 80 ms ease-out (c-filter_input--active).
    SNAnimate(SNDuration80, [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut], ^{
        self->_ring.opacity = ring ? 1 : 0;
        self->_box.borderColor = SNCGColor(ring ? 0 : SNThemeOtlInvPry);
    });
}

#pragma mark Text

- (void)clearText {
    self.text = @"";
    if (self.textChanged) self.textChanged(@"");
    if (self.cleared) self.cleared();
}

- (void)controlTextDidChange:(NSNotification *)notification {
    _clear.hidden = !_textField.stringValue.length;
    if (self.textChanged) self.textChanged(self.textField.stringValue);
}

- (void)controlTextDidEndEditing:(NSNotification *)notification { [self setEditing:NO]; }

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)command {
    if (command == @selector(cancelOperation:)) {
        // Escape empties the field; an empty one leaves it as it is.
        if (self.text.length) [self clearText];
        return YES;
    }
    if (command == @selector(moveDown:) && self.downPressed) {
        self.downPressed();
        return YES;
    }
    // The field has nothing to submit: Return changes nothing.
    return command == @selector(insertNewline:);
}

@end
