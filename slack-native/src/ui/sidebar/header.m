// Owns the header's geometry (live, 311 pt column): a 49 pt row whose title button spans
// x 8-166 at y 9.5-40 (4 pt / 8 pt padding around 18 pt black text and the caret), 28 pt icon
// buttons 4 pt apart ending 8 pt from the right edge; the field 28 pt tall at y 57, inset 8 pt.
#import "render/strings.h"
#import "ui/kit/label.h"
#import "ui/sidebar/header.h"

/// The title and buttons are centred 25 pt from the top (live).
static const CGFloat kMiddle = 25, kInset = 8, kButton = 28, kButtonGap = 4;
static const CGFloat kTitlePaddingX = 8, kTitleHeight = 30.5, kCaretBox = 20, kCaretGap = 4;
static const CGFloat kFieldTop = 57, kFieldHeight = 28;

/// The workspace name and its caret; a click opens the workspace menu.
@interface SNSidebarTitleButton : SNHoverView
@property (nonatomic, copy) NSString *title;
@end

@implementation SNSidebarTitleButton

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;
    // Hover and press look the same and switch at once (live).
    self.hoverColor = self.pressedColor = SNThemeSurfInvTer;
    self.overlayRadius = SNRadiusLarge - 2;
    self.transitionDuration = 0;
    return self;
}

- (NSFont *)font { return SNFont(SNFontSizeSubtitle, SNFontWeightBlack); }

- (CGFloat)fittingWidth {
    CGFloat text = ceil([self.title sizeWithAttributes:@{NSFontAttributeName : self.font}].width);
    return kTitlePaddingX + text + kCaretGap + kCaretBox + kTitlePaddingX;
}

- (void)setTitle:(NSString *)title {
    _title = [title copy];
    self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirty {
    NSRect bounds = self.bounds;
    CGFloat textWidth = bounds.size.width - 2 * kTitlePaddingX - kCaretGap - kCaretBox;
    SNDrawText(self.title ?: @"", self.font, SNThemeContentInvPry, SNFontSizeSubtitle * SNLeadingSmall, NSTextAlignmentLeft, 1,
               NSMakeRect(kTitlePaddingX, (bounds.size.height - SNFontSizeSubtitle * SNLeadingSmall) / 2, textWidth,
                          SNFontSizeSubtitle * SNLeadingSmall));
    // The caret has no size of its own: it takes the title's font size.
    SNDrawIcon(@"caret-down", SNFontSizeSubtitle, SNThemeContentInvPry, NSMakeRect(NSMaxX(bounds) - kTitlePaddingX - kCaretBox, (bounds.size.height - kCaretBox) / 2 + 1, kCaretBox, kCaretBox));
}

@end

@implementation SNSidebarHeaderView {
    SNSidebarTitleButton *_title;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _title = [[SNSidebarTitleButton alloc] initWithFrame:NSZeroRect];
    _titleButton = _title;
    _settingsButton = [self iconButton:@"settings" tip:@"sidebar.settings"];
    _composeButton = [self iconButton:@"compose" tip:@"sidebar.compose"];
    _filterField = [[SNFilterField alloc] initWithPlaceholder:SNLocalized(@"sidebar.filter.placeholder")];
    // The small field: 4 pt paddings put the glyph's centre at 13 and the text at 25 (live).
    _filterField.glyphCentre = 13;
    _filterField.textX = 25;
    _filterField.glyphColor = SNThemeContentInvPry;
    for (NSView *view in @[ _title, _settingsButton, _composeButton, _filterField ]) [self addSubview:view];
    return self;
}

- (SNButton *)iconButton:(NSString *)icon tip:(NSString *)tip {
    SNButton *button = [SNButton iconButtonNamed:icon size:kButton iconSize:20];
    // effects.txt A13: glyph rgba(227,206,235,0.8) -> #f8f8f8 on an 8% fill, 80 ms default curve.
    button.contentColor = SNThemeContentInvSec;
    button.hoverContentColor = button.pressedContentColor = SNThemeContentInvPry;
    button.hoverFillColor = 0;
    button.hoverColor = SNThemeSurfInvTer;
    button.transitionDuration = SNLiveSidebarHeaderIconHover;
    button.transitionTiming = SNEaseDefault();
    button.tooltip = SNLocalized(tip);
    button.tooltipPlacement = SNPlacementBelow;
    [button stateDidChange];
    return button;
}

- (BOOL)isFlipped { return YES; }

- (void)setWorkspaceName:(NSString *)workspaceName {
    _workspaceName = [workspaceName copy];
    _title.title = workspaceName;
    self.needsLayout = YES;
}

- (void)layout {
    [super layout];
    CGFloat width = self.bounds.size.width, middle = kMiddle;
    _composeButton.frame = NSMakeRect(width - kInset - kButton, middle - kButton / 2 + 1, kButton, kButton);
    _settingsButton.frame = NSOffsetRect(_composeButton.frame, -kButton - kButtonGap, 0);
    CGFloat titleRoom = NSMinX(_settingsButton.frame) - kButtonGap - kInset;
    _title.frame = NSMakeRect(kInset, middle - kTitleHeight / 2, MAX(0, MIN(_title.fittingWidth, titleRoom)), kTitleHeight);
    _filterField.frame = NSMakeRect(kInset, kFieldTop, MAX(0, width - 2 * kInset), kFieldHeight);
}

@end
