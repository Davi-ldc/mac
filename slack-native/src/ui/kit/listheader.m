// Owns the list header's layout.
#import "render/strings.h"
#import "ui/kit/label.h"
#import "ui/kit/listheader.h"

/// Measured on the captures. Page: the title's button 8 pt from the column's edge with 8 pt of
/// padding, the compose button 28 pt square 8 pt from the right and the switch 10 pt left of
/// it. Peek: text 16 pt from either edge.
static const CGFloat kPageHeight = 49, kPeekHeight = 45, kPageInset = 8, kTitlePadding = 8, kTitleHeight = 30, kCompose = 28,
                     kSwitchGap = 10, kPeekInset = 16, kCaretGap = 4;

@implementation SNListHeader {
    SNListHeaderStyle _style;
    SNLabel *_title;
    SNIconLayer *_caret;
    CALayer *_hairline;
}

- (instancetype)initWithTitle:(NSString *)title style:(SNListHeaderStyle)style caret:(BOOL)caret compose:(BOOL)compose {
    if (!(self = [super initWithFrame:NSZeroRect])) return nil;
    self.wantsLayer = YES;
    _style = style;
    _height = style == SNListHeaderPage ? kPageHeight : kPeekHeight;
    _titleButton = [[SNHoverView alloc] initWithFrame:NSZeroRect];
    _titleButton.hoverColor = _titleButton.pressedColor = style == SNListHeaderPage ? SNThemeSurfInvTer : 0;
    _titleButton.overlayRadius = 6;
    _titleButton.transitionDuration = 0;
    CGFloat size = style == SNListHeaderPage ? SNFontSizeSubtitle : SNFontSizeBase;
    _title = [SNLabel labelWithText:title font:SNFont(size, SNFontWeightBlack) color:SNThemeContentInvPry];
    _title.lineHeight = round(size * 1.25);
    [_titleButton addSubview:_title];
    if (caret) {
        // The caret has no size of its own: it takes the title's font size.
        _caret = [SNIconLayer iconNamed:@"caret-down" size:size color:SNThemeContentInvPry];
        [_titleButton.layer addSublayer:_caret];
    }
    [self addSubview:_titleButton];
    _unreadsToggle = [[SNUnreadsToggle alloc] initWithTitle:SNLocalized(@"dms.unreads")];
    [self addSubview:_unreadsToggle];
    if (compose) {
        _composeButton = [SNButton iconButtonNamed:@"compose" size:kCompose iconSize:20];
        _composeButton.contentColor = SNThemeContentInvSec;
        _composeButton.hoverContentColor = _composeButton.pressedContentColor = SNThemeContentInvPry;
        _composeButton.hoverFillColor = 0;
        _composeButton.hoverColor = _composeButton.pressedColor = SNThemeSurfInvTer;
        _composeButton.tooltip = SNLocalized(@"dms.compose");
        _composeButton.tooltipPlacement = SNPlacementBelow;
        [self addSubview:_composeButton];
    }
    if (style == SNListHeaderPeek) {
        _unreadsToggle.inverse = NO;
        _hairline = [CALayer layer];
        _hairline.backgroundColor = SNCGColor(SNColorOtlTer);
        [self.layer addSublayer:_hairline];
    }
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)layout {
    [super layout];
    NSSize size = self.bounds.size;
    CGFloat middle = (self.height - (_hairline ? 1 : 0)) / 2, right = size.width - (_style == SNListHeaderPage ? kPageInset : kPeekInset);
    if (self.composeButton) {
        self.composeButton.frame = NSMakeRect(right - kCompose, middle - kCompose / 2, kCompose, kCompose);
        right -= kCompose + kSwitchGap;
    }
    NSSize toggle = self.unreadsToggle.fittingSize;
    self.unreadsToggle.frame = NSMakeRect(right - toggle.width, middle - toggle.height / 2, toggle.width, toggle.height);

    CGFloat padding = _style == SNListHeaderPage ? kTitlePadding : 0, x = _style == SNListHeaderPage ? kPageInset : kPeekInset;
    CGFloat caret = _caret ? kCaretGap + _caret.iconSize : 0;
    CGFloat textWidth = MIN(ceil(_title.textWidth), MAX(0, NSMinX(self.unreadsToggle.frame) - x - 2 * padding - caret));
    CGFloat buttonWidth = padding + textWidth + caret + padding;
    _titleButton.frame = NSMakeRect(x, middle - kTitleHeight / 2, buttonWidth, kTitleHeight);
    _title.frame = NSMakeRect(padding, (kTitleHeight - _title.lineHeight) / 2, textWidth, _title.lineHeight);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _caret.frame = CGRectMake(padding + textWidth + kCaretGap, (kTitleHeight - _caret.iconSize) / 2, _caret.iconSize, _caret.iconSize);
    _hairline.frame = CGRectMake(0, self.height - 1, size.width, 1);
    [CATransaction commit];
}

@end
