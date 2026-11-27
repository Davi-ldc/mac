// Owns the top bar's controls and their flexible layout.
#import "ui/kit/container.h"
#import "ui/kit/label.h"
#import "ui/shell/topbar.h"

/// CSS: the traffic lights' spacer is 2 * 12 + 52 wide; the bar has 4 pt of padding on the right
/// and its right group a 4 pt margin.
static const CGFloat kSpacer = 76, kBarPadding = 4, kRightMargin = 4;
/// Slack splits the rest between the history group (flex 1), the search group (flex 2) and the
/// right group (flex 1 plus its own width). This basis is fitted to the reference capture at
/// 1435 pt, which it reproduces to the point; the right group's full content is not known.
static const CGFloat kRightBasis = 73;
/// History buttons: a 20 pt glyph with 3 pt padding and 1 pt margins, 4 pt apart; the history
/// menu button keeps 8 pt to the search field.
static const CGFloat kButton = 26, kButtonPitch = 32, kHistoryEnd = 8 + 1 + kButton / 2;
/// The search field's fill is on its container, rounded 4 pt (sk6-radius-base); the AI button's
/// outline is rounded like the field inside it (6 pt).
static const CGFloat kSearchHeight = 28, kSearchRadius = SNRadiusBase, kAIRadius = 6, kAIButton = 28, kAIGap = 8, kAIInset = 3.5;
/// The toggle's 20 pt icon is centred 90 pt from the left.
static const CGFloat kToggleCentre = 90;
/// Inactive windows draw the bar's content at this opacity (measured, see effects.txt [L1]).
static const CGFloat kDimmedAlpha = 0.66;

static SNButton *TopBarButton(NSString *icon) {
    SNButton *button = [[SNButton alloc] initWithFrame:NSMakeRect(0, 0, kButton, kButton)];
    button.icon.iconName = icon;
    button.icon.iconSize = 20;
    button.contentColor = button.hoverContentColor = button.pressedContentColor = SNThemeContentInvPry;
    // components.json top_nav_history_button: the hover and pressed backgrounds replace each
    // other instantly.
    button.hoverColor = SNThemeSurfInvPry;
    button.pressedColor = SNThemeSurfInvSec;
    button.transitionDuration = 0;
    button.cornerRadius = SNRadiusBase;
    button.disabledAlpha = 0.45;
    button.tooltipPlacement = SNPlacementBelow;
    // a_tooltip_help: the tooltip hangs 8 pt under the bar, not under the 26 pt button.
    CGFloat reach = -(SNTopBarHeight - kButton) / 2;
    button.tooltipInsets = NSEdgeInsetsMake(reach, 0, reach, 0);
    return button;
}

/// The search field reports the mouse going down instead of acting on release.
@interface SNTopBarSearchField : SNHoverView
@property (nonatomic, copy) void (^mouseWentDown)(void);
@end

@implementation SNTopBarSearchField

- (void)mouseDown:(NSEvent *)event {
    if (self.mouseWentDown) self.mouseWentDown();
}

- (void)mouseUp:(NSEvent *)event {}

@end

@implementation SNTopBar {
    SNContainerView *_content;
    SNLabel *_placeholder;
    SNIconLayer *_magnifier;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _content = [[SNContainerView alloc] initWithFrame:self.bounds];
    _content.wantsLayer = YES;
    [self addSubview:_content];

    _sidebarButton = TopBarButton(@"sidebar-left");
    _backButton = TopBarButton(@"arrow-left");
    _forwardButton = TopBarButton(@"arrow-right");
    _historyButton = TopBarButton(@"clock");
    _helpButton = TopBarButton(@"help");
    // Slack draws the Slackbot sprite here, a picture rather than an icon.
    _aiButton = TopBarButton(@"ai-sparkle");
    _aiButton.frame = NSMakeRect(0, 0, kAIButton, kAIButton);
    _aiButton.borderColor = SNLegacyHairline;
    _aiButton.cornerRadius = kAIRadius;

    SNTopBarSearchField *searchField = [[SNTopBarSearchField alloc] initWithFrame:NSMakeRect(0, 0, 100, kSearchHeight)];
    __weak SNTopBar *weakSelf = self;
    searchField.mouseWentDown = ^{
        SNTopBar *bar = weakSelf;
        if (bar.searchPressed) bar.searchPressed();
    };
    _searchField = searchField;
    // components.json top_nav_search: theme-surf-inv-pry with its hover tint blended on top,
    // and no hover change of its own.
    _searchField.layer.backgroundColor = SNCGColor(SNColorOver(SNThemeSurfInvPryHover, SNThemeSurfInvPry));
    _searchField.layer.cornerRadius = kSearchRadius;
    _searchField.hoverColor = _searchField.pressedColor = 0;
    // No size of its own: the icon takes the body's 15 px.
    _magnifier = [SNIconLayer iconNamed:@"search" size:15 color:SNThemeContentInvPry];
    [_searchField.layer addSublayer:_magnifier];
    _placeholder = [SNLabel labelWithText:@"" font:SNFont(SNFontSizeCaption, SNFontWeightRegular) color:SNThemeContentInvPry];
    _placeholder.lineHeight = SNFontSizeCaption * SNLeadingSmall;
    [_searchField addSubview:_placeholder];

    for (NSView *view in @[ _sidebarButton, _backButton, _forwardButton, _historyButton, _searchField, _aiButton, _helpButton ])
        [_content addSubview:view];
    return self;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)mouseDownCanMoveWindow { return YES; }

- (void)mouseUp:(NSEvent *)event {
    if (event.clickCount != 2) return;
    NSString *action = [NSUserDefaults.standardUserDefaults stringForKey:@"AppleActionOnDoubleClick"];
    if ([action isEqualToString:@"Minimize"]) [self.window performMiniaturize:nil];
    else if (![action isEqualToString:@"None"]) [self.window performZoom:nil];
}

- (void)setSearchPlaceholder:(NSString *)searchPlaceholder {
    _searchPlaceholder = [searchPlaceholder copy];
    _placeholder.text = searchPlaceholder;
}

- (void)setDimmed:(BOOL)dimmed {
    _dimmed = dimmed;
    _content.alphaValue = dimmed ? kDimmedAlpha : 1;
}

- (void)layout {
    [super layout];
    NSSize size = self.bounds.size;
    _content.frame = self.bounds;
    CGFloat share = MAX(0, (size.width - kBarPadding - kSpacer - kRightBasis) / 4);
    CGFloat leftEnd = kSpacer + share, middleEnd = kSpacer + 3 * share, middle = size.height / 2;
    void (^centre)(NSView *, CGFloat) = ^(NSView *view, CGFloat x) {
        NSSize own = view.frame.size;
        view.frame = NSMakeRect(x - own.width / 2, middle - own.height / 2, own.width, own.height);
    };
    centre(_sidebarButton, kToggleCentre);
    centre(_historyButton, leftEnd - kHistoryEnd);
    centre(_forwardButton, leftEnd - kHistoryEnd - kButtonPitch);
    centre(_backButton, leftEnd - kHistoryEnd - 2 * kButtonPitch);
    centre(_aiButton, middleEnd - kAIInset - kAIButton / 2);
    CGFloat searchEnd = middleEnd - kAIInset - kAIButton - kAIGap;
    _searchField.frame = NSMakeRect(leftEnd, middle - kSearchHeight / 2, MAX(40, searchEnd - leftEnd), kSearchHeight);
    centre(_helpButton, size.width - kBarPadding - kRightMargin - kButton / 2);

    // components.json top_nav_search: padding 5 5 5 12, the glyph's box (15 pt, measured on the
    // capture's text position), then 8 pt before the text.
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _magnifier.frame = CGRectMake(12, (kSearchHeight - 15) / 2, 15, 15);
    [CATransaction commit];
    CGFloat textX = 12 + 15 + 8, lineHeight = _placeholder.lineHeight;
    _placeholder.frame = NSMakeRect(textX, (kSearchHeight - lineHeight) / 2, MAX(0, _searchField.frame.size.width - textX - 12), lineHeight);
}

@end
