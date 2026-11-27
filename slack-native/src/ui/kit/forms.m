// Owns the dialogs' form controls: their frames, focus ring, typing and the select's list.
#import "render/icon.h"
#import "ui/kit/forms.h"
#import "ui/kit/label.h"
#import "ui/kit/popover.h"

/// The select's list stops growing here and scrolls (c-select's maxListHeight).
static const CGFloat kListHeight = 240, kMenuPadding = 12, kMenuRow = 28;
static const CGFloat kInputPadding = 12, kIcon = 16;

NSView *SNFormLabel(NSString *text) {
    SNLabel *label = [SNLabel labelWithText:text font:SNFont(SNFontSizeBase, SNFontWeightBold) color:SNColorContentPry];
    label.lineHeight = SNFormLabelLine;
    label.frame = NSMakeRect(0, 0, 0, SNFormLabelLine);
    return label;
}

/// Base-pry, a 1 pt otl-pry border and radius 8; focused, the border goes.
static void SNFormDrawBox(NSRect bounds, BOOL focused) {
    NSBezierPath *box = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(bounds, 0.5, 0.5) xRadius:SNRadiusLarge - 0.5 yRadius:SNRadiusLarge - 0.5];
    [SNColor(SNColorBasePry) setFill];
    [box fill];
    if (focused) return;
    [SNColor(SNColorOtlPry) setStroke];
    [box stroke];
}

/// The field's frame: SNFormDrawBox, and while focused the ring's two bands (sublayers, outside
/// the box).
@interface SNFormFrame : NSView
@property (nonatomic) BOOL focusShown;
@end

@implementation SNFormFrame {
    CALayer *_halo, *_ring;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.wantsLayer = YES;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;
    _halo = [CALayer layer];
    _halo.borderColor = SNCGColor(SNColorWithAlpha(SNColorOtlHgl1, 0.3));
    _halo.borderWidth = 4;
    _halo.cornerRadius = SNRadiusLarge + 5;
    _ring = [CALayer layer];
    _ring.borderColor = SNCGColor(SNColorOtlHgl1);
    _ring.borderWidth = 1;
    _ring.cornerRadius = SNRadiusLarge + 1;
    for (CALayer *layer in @[ _halo, _ring ]) {
        layer.hidden = YES;
        layer.actions = @{@"hidden" : NSNull.null, @"bounds" : NSNull.null, @"position" : NSNull.null};
        [self.layer addSublayer:layer];
    }
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)layout {
    [super layout];
    _halo.frame = NSInsetRect(self.bounds, -5, -5);
    _ring.frame = NSInsetRect(self.bounds, -1, -1);
}

- (void)setFocusShown:(BOOL)focusShown {
    if (focusShown == _focusShown) return;
    _focusShown = focusShown;
    _halo.hidden = _ring.hidden = !focusShown;
    self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirtyRect { SNFormDrawBox(self.bounds, _focusShown); }

@end

@interface SNFormInput () <NSTextFieldDelegate, NSTextViewDelegate>
@end

@implementation SNFormInput {
    SNFormFrame *_frame;
    NSTextField *_field;
    NSScrollView *_scroll;
    NSTextView *_textView;
    SNIconLayer *_icon;
    NSTextField *_placeholder;
    NSString *_placeholderText;
    __weak NSWindow *_observed;
}

- (NSString *)placeholder { return _placeholderText; }

static NSAttributedString *Placeholder(NSString *text) {
    return [[NSAttributedString alloc] initWithString:text ?: @""
                                           attributes:@{NSFontAttributeName : SNFont(SNFontSizeBase, SNFontWeightRegular), NSForegroundColorAttributeName : SNColor(SNColorContentTer)}];
}

- (instancetype)initWithPlaceholder:(NSString *)placeholder icon:(NSString *)icon {
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, 200, SNFormControlHeight)])) return nil;
    [self buildFrame];
    _field = [NSTextField textFieldWithString:@""];
    _field.bordered = NO;
    _field.drawsBackground = NO;
    _field.focusRingType = NSFocusRingTypeNone;
    _field.font = SNFont(SNFontSizeBase, SNFontWeightRegular);
    _field.textColor = SNColor(SNColorContentPry);
    _field.placeholderAttributedString = Placeholder(placeholder);
    _placeholderText = [placeholder copy];
    _field.delegate = self;
    [self addSubview:_field];
    if (icon) {
        _icon = [SNIconLayer iconNamed:icon size:kIcon color:SNColorContentSec];
        [_frame.layer addSublayer:_icon];
    }
    return self;
}

- (void)setPlaceholder:(NSString *)placeholder {
    _placeholderText = [placeholder copy];
    _field.placeholderAttributedString = Placeholder(placeholder);
    _placeholder.attributedStringValue = Placeholder(placeholder);
}

- (instancetype)initMultilineWithPlaceholder:(NSString *)placeholder height:(CGFloat)height {
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, 200, height)])) return nil;
    [self buildFrame];
    _scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    _scroll.drawsBackground = NO;
    _scroll.hasVerticalScroller = YES;
    _scroll.scrollerStyle = NSScrollerStyleOverlay;
    _textView = [[NSTextView alloc] initWithFrame:NSZeroRect];
    _textView.drawsBackground = NO;
    _textView.richText = NO;
    _textView.font = SNFont(SNFontSizeBase, SNFontWeightRegular);
    _textView.textColor = SNColor(SNColorContentPry);
    _textView.insertionPointColor = SNColor(SNColorContentPry);
    _textView.textContainerInset = NSZeroSize;
    _textView.textContainer.lineFragmentPadding = 0;
    _textView.verticallyResizable = YES;
    _textView.autoresizingMask = NSViewWidthSizable;
    _textView.delegate = self;
    NSMutableParagraphStyle *lines = [NSMutableParagraphStyle new];
    lines.minimumLineHeight = lines.maximumLineHeight = 22;
    _textView.defaultParagraphStyle = lines;
    _textView.typingAttributes = @{NSFontAttributeName : _textView.font, NSForegroundColorAttributeName : _textView.textColor, NSParagraphStyleAttributeName : lines};
    _scroll.documentView = _textView;
    [self addSubview:_scroll];
    _placeholder = [NSTextField labelWithAttributedString:Placeholder(placeholder)];
    [self addSubview:_placeholder];
    return self;
}

- (void)buildFrame {
    _frame = [[SNFormFrame alloc] initWithFrame:self.bounds];
    _frame.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self addSubview:_frame];
}

- (void)dealloc { [_observed removeObserver:self forKeyPath:@"firstResponder"]; }

- (BOOL)isFlipped { return YES; }

- (NSView *)editor { return _field ?: _textView; }

- (void)layout {
    [super layout];
    _frame.frame = self.bounds;
    if (_field) {
        CGFloat x = kInputPadding + (_icon ? kIcon + 8 : 0), height = ceil(_field.intrinsicContentSize.height);
        _field.frame = NSMakeRect(x, round((NSHeight(self.bounds) - height) / 2), NSWidth(self.bounds) - x - kInputPadding, height);
        _icon.frame = CGRectMake(kInputPadding - 2, (NSHeight(self.bounds) - kIcon) / 2, kIcon, kIcon);
    } else {
        _scroll.frame = NSMakeRect(kInputPadding, 8, NSWidth(self.bounds) - 2 * kInputPadding, NSHeight(self.bounds) - 12);
        _textView.frame = NSMakeRect(0, 0, NSWidth(_scroll.frame), MAX(NSHeight(_textView.frame), NSHeight(_scroll.frame)));
        _textView.textContainer.containerSize = NSMakeSize(NSWidth(_scroll.frame), CGFLOAT_MAX);
        _placeholder.frame = NSMakeRect(kInputPadding, 8, NSWidth(_scroll.frame), 22);
    }
}

- (NSString *)text { return _field ? _field.stringValue : _textView.string; }

- (void)setText:(NSString *)text {
    if (_field) _field.stringValue = text ?: @"";
    else _textView.string = text ?: @"";
    _placeholder.hidden = self.text.length > 0;
}

- (void)focus { [self.window makeFirstResponder:self.editor]; }

#pragma mark Focus

- (void)viewWillMoveToWindow:(NSWindow *)window {
    [_observed removeObserver:self forKeyPath:@"firstResponder"];
    _observed = window;
    [window addObserver:self forKeyPath:@"firstResponder" options:0 context:NULL];
    [super viewWillMoveToWindow:window];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    NSResponder *responder = self.window.firstResponder;
    // A text field types through the window's field editor, whose delegate it is.
    BOOL focused = responder == _textView || responder == _field ||
                   ([responder isKindOfClass:NSTextView.class] && ((NSTextView *)responder).delegate == (id)_field && _field);
    _frame.focusShown = focused;
}

#pragma mark Typing

- (void)edited {
    _placeholder.hidden = self.text.length > 0;
    if (self.changed) self.changed(self.text);
}

- (void)controlTextDidChange:(NSNotification *)notification { [self edited]; }
- (void)textDidChange:(NSNotification *)notification { [self edited]; }

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)command {
    return self.keyCommand && self.keyCommand(command);
}

- (BOOL)textView:(NSTextView *)textView doCommandBySelector:(SEL)command { return self.keyCommand && self.keyCommand(command); }

@end

@implementation SNFormChoice

+ (instancetype)choiceWithTitle:(NSString *)title value:(NSString *)value {
    SNFormChoice *choice = [self new];
    choice->_title = [title copy];
    choice->_value = [value copy];
    return choice;
}

@end

/// SNMenu's rows (12 pt of padding, 28 pt rows), kept in view by the arrow keys when it scrolls.
@interface SNFormSelectMenu : SNMenu
@end

@implementation SNFormSelectMenu

- (void)keyDown:(NSEvent *)event {
    [super keyDown:event];
    if (self.highlightedIndex != NSNotFound) [self scrollRectToVisible:NSMakeRect(0, kMenuPadding + self.highlightedIndex * kMenuRow, NSWidth(self.bounds), kMenuRow)];
}

@end

@implementation SNFormSelect

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.hoverColor = 0;
    __weak SNFormSelect *weakSelf = self;
    self.action = ^(SNFormSelect *select) { [weakSelf open]; };
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)setValue:(NSString *)value {
    _value = [value copy];
    self.needsDisplay = YES;
}

- (void)setShownTitle:(NSString *)shownTitle {
    _shownTitle = [shownTitle copy];
    self.needsDisplay = YES;
}

- (NSString *)choiceTitle {
    if (_shownTitle) return _shownTitle;
    for (SNFormChoice *choice in _choices)
        if ([choice.value isEqualToString:_value ?: @""]) return choice.title;
    return nil;
}

- (void)choose:(NSString *)value {
    self.value = value;
    if (self.changed) self.changed(value);
}

- (void)open {
    NSMutableArray<SNMenuItem *> *items = [NSMutableArray new];
    __weak SNFormSelect *weakSelf = self;
    NSUInteger chosen = NSNotFound;
    for (SNFormChoice *choice in _choices) {
        NSString *value = choice.value;
        SNMenuItem *item = [SNMenuItem itemWithTitle:choice.title action:^{ [weakSelf choose:value]; }];
        item.checked = [value isEqualToString:_value ?: @""];
        if (item.checked) chosen = items.count;
        [items addObject:item];
    }
    SNFormSelectMenu *menu = [[SNFormSelectMenu alloc] initWithItems:items width:NSWidth(self.bounds)];
    if (NSHeight(menu.frame) <= kListHeight) {
        [menu showForRect:self.bounds inView:self placement:SNPlacementBelow];
        if (chosen != NSNotFound) menu.highlightedIndex = chosen;
        return;
    }
    SNPanelView *panel = [[SNPanelView alloc] initWithFill:SNColorCtrPry radius:SNRadiusMenuLive shadow:SNMenuShadow];
    panel.frame = NSMakeRect(0, 0, NSWidth(menu.frame), kListHeight);
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:panel.contentView.bounds];
    scroll.drawsBackground = NO;
    scroll.hasVerticalScroller = YES;
    scroll.scrollerStyle = NSScrollerStyleOverlay;
    scroll.documentView = menu;
    [panel.contentView addSubview:scroll];
    if (chosen != NSNotFound) {
        menu.highlightedIndex = chosen;
        CGFloat row = kMenuPadding + chosen * kMenuRow + kMenuRow / 2, visible = NSHeight(scroll.contentView.bounds);
        [scroll.contentView scrollToPoint:NSMakePoint(0, MIN(MAX(0, row - visible / 2), NSHeight(menu.frame) - visible))];
        [scroll reflectScrolledClipView:scroll.contentView];
    }
    [SNPopover showContent:panel forRect:self.bounds inView:self placement:SNPlacementBelow gap:4];
    [self.window makeFirstResponder:menu];
}

- (void)drawRect:(NSRect)dirtyRect {
    SNFormDrawBox(self.bounds, NO);
    NSString *title = self.choiceTitle;
    SNColorToken color = !self.enabled ? SNColorContentTer : title ? SNColorContentPry : SNColorContentTer;
    CGFloat height = NSHeight(self.bounds);
    SNDrawText(title ?: _placeholder ?: @"", SNFont(SNFontSizeBase, SNFontWeightRegular), color, height, NSTextAlignmentLeft, 1,
               NSMakeRect(kInputPadding, 0, NSWidth(self.bounds) - kInputPadding - 32, height));
    SNDrawIcon(@"caret-down", kIcon, self.enabled ? SNColorContentPry : SNColorContentTer, NSMakeRect(NSWidth(self.bounds) - kInputPadding - kIcon, (height - kIcon) / 2, kIcon, kIcon));
}

@end

static const CGFloat kRadio = 14, kRadioGap = 8;

@implementation SNFormRadio

- (instancetype)initWithTitle:(NSString *)title {
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, 200, 22)])) return nil;
    _title = [title copy];
    self.hoverColor = self.pressedColor = 0;
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)setChecked:(BOOL)checked {
    _checked = checked;
    self.needsDisplay = YES;
}

- (void)stateDidChange {
    [super stateDidChange];
    self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    CGFloat height = NSHeight(self.bounds);
    NSRect circle = NSMakeRect(0.75, (height - kRadio) / 2 + 0.75, kRadio - 1.5, kRadio - 1.5);
    NSBezierPath *ring = [NSBezierPath bezierPathWithOvalInRect:circle];
    ring.lineWidth = 1.5;
    [SNColor(_checked ? SNColorBaseInvHgl1 : SNColorBasePry) setFill];
    [ring fill];
    [SNColor(_checked ? SNColorBaseInvHgl1 : self.hovered ? SNColorOtlPry : SNColorOtlSec) setStroke];
    [ring stroke];
    if (_checked) {
        [SNColor(0xffffffff) setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(circle, 3.25, 3.25)] fill];
    }
    SNColorToken color = self.enabled ? SNColorContentPry : SNColorContentTer;
    SNDrawText(_title, SNFont(SNFontSizeBase, SNFontWeightRegular), color, height, NSTextAlignmentLeft, 1, NSMakeRect(kRadio + kRadioGap, 0, NSWidth(self.bounds) - kRadio - kRadioGap, height));
}

@end
