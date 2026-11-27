// Owns the composer's layout, focus and button states, drafts and sending.
#import "model/json.h"
#import "render/emoji.h"
#import "render/strings.h"
#import "ui/composer/attachments.h"
#import "ui/composer/autocomplete.h"
#import "ui/composer/broadcast.h"
#import "ui/composer/commands.h"
#import "ui/composer/composer.h"
#import "ui/composer/drop.h"
#import "ui/composer/gifpicker.h"
#import "ui/composer/pasteboard.h"
#import "ui/composer/textview.h"
#import "ui/emoji/picker.h"
#import "ui/kit/button.h"
#import "ui/kit/dialog.h"
#import "ui/kit/label.h"
#import "ui/kit/popover.h"
#import "ui/present/names.h"

// Measured on design/ref/composer_*.png (points from the box's outer edges): a 1 pt border; the
// formatting bar's 28 pt buttons centred 21 pt down, 32 pt apart from x 19; the first line box
// 46.75 pt down (5.75 under the bar) and 13 pt in; a 40 pt footer; 20 pt beside the box and 24 pt
// under it.
static const CGFloat kSideMargin = 20, kBottomMargin = 24, kToolbar = 41, kTextTop = 5.75, kTextBottom = SNComposerTextBottom, kFooter = SNComposerFooterHeight;
static const CGFloat kTextInset = SNComposerTextInset, kButton = 28, kNoToolbarTextTop = SNComposerTextTop;
/// The notification bar filling the margin under the box (.p-notification_bar: 12 pt in, its
/// section .7em of 15 on a 16 pt line, centred), and how long the connection may be down before
/// it says so (Slack's 10 s grace).
static const CGFloat kNoticeInset = 12, kNoticeFont = 10.5, kNoticeLine = 16, kNoticeIcon = 12;
static const NSTimeInterval kOfflineGrace = 10;
/// A thread's "also send" checkbox: an 18 pt line 8 pt under the box.
static const CGFloat kBroadcastGap = 8, kBroadcastLine = 18;
/// The context bar above the box (components.json composer_context_bar): 41 pt with 6 pt more
/// under the box's top corners; a longer notice adds its lines.
static const CGFloat kContextBar = 41, kContextFiller = 6, kContextLine = 16.25, kContextTextX = 41;
static const SNColorToken kContextFill = SNLegacyForegroundSoftSolid, kContextText = SNLegacyPrimaryForeground;
static const SNColorToken kSeparator = SNColorOtlTer;
/// Hairlines when text is hidden above or below (composer-overflow-hairlines).
static const SNColorToken kOverflowLine = SNLegacyHairline;
/// Slack's limits for a message's files (the web client's upload checks): 10 at a time, 1 GiB each.
static const NSUInteger kMaximumFiles = 10;
static const long long kFileSizeLimit = 1LL << 30;
static const SNColorToken kSendGreen = 0x007a5aff, kSendGreenHover = 0x148567ff, kSendDivider = 0xffffff66, kEmojiDisc = 0xecb22eff, kEmojiGlyphOnDisc = 0x1d1c1dff;

#pragma mark Parts

/// Slack's NotificationBar under the box: "Slack is trying to connect." with the offline cloud
/// while the connection is down, else who is typing, their names in bold; one line, ellipsized.
@interface SNComposerNotificationBar : NSView
/// Text and bold runs, in order; the offline notice when `offline`.
@property (nonatomic, copy) NSArray<NSArray *> *runs;
@property (nonatomic) BOOL offline;
@property (nonatomic, readonly) NSString *text;
@end

@implementation SNComposerNotificationBar

- (BOOL)isFlipped { return YES; }

- (NSString *)text {
    NSMutableString *text = [NSMutableString new];
    for (NSArray *run in self.runs) [text appendString:run[0]];
    return text;
}

- (void)setRuns:(NSArray<NSArray *> *)runs {
    if ([runs isEqualToArray:_runs]) return;
    _runs = [runs copy];
    self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    CGContextSetShouldSmoothFonts(NSGraphicsContext.currentContext.CGContext, false);
    SNColorToken color = self.offline ? SNLegacyPrimaryForeground : SNLegacyForegroundMaxSolid;
    CGFloat x = 0, top = (NSHeight(self.bounds) - kNoticeLine) / 2, width = NSWidth(self.bounds);
    for (NSArray *run in self.runs) {
        NSFont *font = SNFont(kNoticeFont, [run[1] boolValue] ? SNFontWeightBold : SNFontWeightRegular);
        CGFloat runWidth = MIN(SNTextWidth(run[0], font), width - x);
        if (runWidth <= 0) break;
        SNDrawText(run[0], font, color, kNoticeLine, NSTextAlignmentLeft, 1, NSMakeRect(x, top, runWidth, kNoticeLine));
        x += runWidth;
    }
    if (self.offline && x + 4 + kNoticeIcon <= width)
        SNDrawIcon(@"cloud-offline-filled", kNoticeIcon, color, NSMakeRect(x + 4, (NSHeight(self.bounds) - kNoticeIcon) / 2, kNoticeIcon, kNoticeIcon));
}

@end

/// The box: its fill, border, the bars' separators and the overflow hairlines.
@interface SNComposerBoxView : NSView
@property (nonatomic) BOOL focused, toolbarShown, hiddenAbove, hiddenBelow;
/// Where the text's area ends (the files' row or the footer starts).
@property (nonatomic) CGFloat textBottom;
@property (nonatomic, copy) NSArray<NSNumber *> *toolbarSeparators, *footerSeparators;
@end

void SNDrawComposerBox(NSRect box, BOOL focused) {
    [SNColor(focused ? SNMeasuredComposerBorderFocus : SNMeasuredComposerBorderRest) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:box xRadius:SNRadiusLarge yRadius:SNRadiusLarge] fill];
    [SNColor(SNMeasuredComposerFill) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(box, 1, 1) xRadius:SNRadiusLarge - 1 yRadius:SNRadiusLarge - 1] fill];
}

@implementation SNComposerBoxView

- (BOOL)isFlipped { return YES; }

- (void)setFocused:(BOOL)focused {
    if (focused == _focused) return;
    _focused = focused;
    self.needsDisplay = YES;
}

- (void)setToolbarShown:(BOOL)toolbarShown {
    if (toolbarShown == _toolbarShown) return;
    _toolbarShown = toolbarShown;
    self.needsDisplay = YES;
}

- (void)setToolbarSeparators:(NSArray<NSNumber *> *)separators {
    if ([separators isEqualToArray:_toolbarSeparators]) return;
    _toolbarSeparators = [separators copy];
    self.needsDisplay = YES;
}

- (void)setFooterSeparators:(NSArray<NSNumber *> *)separators {
    if ([separators isEqualToArray:_footerSeparators]) return;
    _footerSeparators = [separators copy];
    self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    NSRect bounds = self.bounds;
    SNDrawComposerBox(bounds, self.focused);
    [SNColor(SNColorOver(kSeparator, SNMeasuredComposerFill)) setFill];
    for (NSNumber *x in self.toolbarSeparators) NSRectFill(NSMakeRect(x.doubleValue, kToolbar / 2 + 0.5 - 10, 1, 20));
    CGFloat footer = NSHeight(bounds) - 1 - kFooter / 2;
    for (NSNumber *x in self.footerSeparators) NSRectFill(NSMakeRect(x.doubleValue, footer - 10, 1, 20));
    [SNColor(SNColorOver(kOverflowLine, SNMeasuredComposerFill)) setFill];
    if (self.hiddenAbove && self.toolbarShown) NSRectFill(NSMakeRect(1, kToolbar, NSWidth(bounds) - 2, 1));
    if (self.hiddenBelow) NSRectFill(NSMakeRect(1, self.textBottom - 1, NSWidth(bounds) - 2, 1));
}

@end

/// "Essa pessoa verá suas mensagens quando voltar. Notificar mesmo assim?" over the box of a DM
/// with someone whose notifications are paused, or the composer's own notice.
@interface SNComposerContextBar : NSView
@property (nonatomic, copy, nullable) NSString *notice;
/// The bar's height at `width` with its text wrapped.
- (CGFloat)heightForWidth:(CGFloat)width;
@end

@implementation SNComposerContextBar

- (BOOL)isFlipped { return YES; }

- (void)setNotice:(NSString *)notice {
    _notice = [notice copy];
    self.needsDisplay = YES;
}

- (CGFloat)heightForWidth:(CGFloat)width {
    if (!self.notice) return kContextBar;
    NSUInteger lines = MAX(1u, SNLineCount(self.notice, SNFont(SNFontSizeCaption, SNFontWeightRegular), MAX(1, width - kContextTextX - 12), 0));
    return kContextBar + (lines - 1) * kContextLine;
}

- (void)drawRect:(NSRect)dirtyRect {
    CGContextSetShouldSmoothFonts(NSGraphicsContext.currentContext.CGContext, false);
    NSRect bounds = self.bounds;
    NSBezierPath *shape = [NSBezierPath bezierPathWithRoundedRect:bounds xRadius:SNRadiusLarge yRadius:SNRadiusLarge];
    [SNColor(kContextFill) setFill];
    [shape fill];
    // components.json composer_context_bar: padding 12, a 16 pt icon 12 pt before 13 pt text.
    NSFont *font = SNFont(SNFontSizeCaption, SNFontWeightRegular);
    if (self.notice) {
        SNDrawIcon(@"warning", 16, SNColorContentSec, NSMakeRect(13, 12.5, 16, 16));
        SNDrawText(self.notice, font, kContextText, kContextLine, NSTextAlignmentLeft, 0, NSMakeRect(kContextTextX, 12, NSWidth(bounds) - kContextTextX - 12, NSHeight(bounds) - 12));
        return;
    }
    SNDrawIcon(@"notifications-dnd-filled", 16, SNColorContentSec, NSMakeRect(13, 12.5, 16, 16));
    NSString *text = SNLocalized(@"composer.context.dnd");
    CGFloat x = kContextTextX;
    SNDrawText(text, font, kContextText, 16.25, NSTextAlignmentLeft, 1, NSMakeRect(x, 12, NSWidth(bounds) - x - 12, 16.25));
    x += [text sizeWithAttributes:@{NSFontAttributeName : font}].width + 4;
    SNDrawText(SNLocalized(@"composer.context.notify"), SNFont(SNFontSizeCaption, SNFontWeightBold), SNColorContentHgl1, 16.25, NSTextAlignmentLeft, 1,
               NSMakeRect(x, 12, MAX(0, NSWidth(bounds) - x - 12), 16.25));
}

@end

/// The split send button: the paper plane and the options caret, green once there is text.
@interface SNComposerSendPart : SNHoverView
@property (nonatomic, readonly) SNIconLayer *icon;
@property (nonatomic) BOOL leading, active;
@end

@implementation SNComposerSendPart

- (instancetype)initWithIcon:(NSString *)name size:(CGFloat)size leading:(BOOL)leading {
    if (!(self = [super initWithFrame:NSZeroRect])) return nil;
    _leading = leading;
    _icon = [SNIconLayer iconNamed:name size:size color:SNColorContentPry];
    [self.layer addSublayer:_icon];
    self.hoverColor = self.pressedColor = 0;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;
    [self stateDidChange];
    return self;
}

- (void)layout {
    [super layout];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    CGFloat glyph = _icon.iconSize;
    _icon.frame = CGRectMake((NSWidth(self.bounds) - glyph) / 2, (NSHeight(self.bounds) - glyph) / 2, glyph, glyph);
    [CATransaction commit];
}

- (void)setActive:(BOOL)active {
    _active = active;
    self.enabled = active;
    [self stateDidChange];
}

- (void)stateDidChange {
    [super stateDidChange];
    // Empty: the glyphs at 30% on no fill, and no hover (send-button-hover).
    _icon.color = self.active ? 0xffffffff : SNColorWithAlpha(SNColorContentPry, 0.3);
    self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    if (!self.active) return;
    NSRect bounds = self.bounds;
    CGFloat r = SNRadiusBase;
    NSBezierPath *path = [NSBezierPath bezierPath];
    CGFloat left = NSMinX(bounds), right = NSMaxX(bounds), top = NSMinY(bounds), bottom = NSMaxY(bounds);
    CGFloat leftRadius = self.leading ? r : 0, rightRadius = self.leading ? 0 : r;
    [path moveToPoint:NSMakePoint(left + leftRadius, top)];
    [path appendBezierPathWithArcFromPoint:NSMakePoint(right, top) toPoint:NSMakePoint(right, bottom) radius:rightRadius];
    [path appendBezierPathWithArcFromPoint:NSMakePoint(right, bottom) toPoint:NSMakePoint(left, bottom) radius:rightRadius];
    [path appendBezierPathWithArcFromPoint:NSMakePoint(left, bottom) toPoint:NSMakePoint(left, top) radius:leftRadius];
    [path appendBezierPathWithArcFromPoint:NSMakePoint(left, top) toPoint:NSMakePoint(right, top) radius:leftRadius];
    [SNColor(self.hovered || self.pressed ? kSendGreenHover : kSendGreen) setFill];
    [path fill];
    if (!self.leading) {
        [SNColor(kSendDivider) setFill];
        NSRectFill(NSMakeRect(0, 4, 1, NSHeight(bounds) - 8));
    }
}

@end

/// The smiley: on hover a yellow disc appears behind a tilted alternate face
/// (composer-emoji-button-hover, measured live).
@interface SNComposerEmojiButton : SNButton
@end

@implementation SNComposerEmojiButton {
    SNLayer *_disc;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _disc = [SNLayer layer];
    _disc.backgroundColor = SNCGColor(kEmojiDisc);
    _disc.opacity = 0;
    [self.layer insertSublayer:_disc below:self.icon];
    return self;
}

- (void)layout {
    [super layout];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    CGFloat size = 18;
    _disc.bounds = CGRectMake(0, 0, size, size);
    _disc.cornerRadius = size / 2;
    _disc.position = CGPointMake(NSMidX(self.bounds), NSMidY(self.bounds));
    [CATransaction commit];
}

- (void)stateDidChange {
    [super stateDidChange];
    BOOL on = self.hovered || self.pressed;
    // The disc and the alternate glyph swap at once; only the tilt eases in.
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _disc.opacity = on ? 1 : 0;
    self.icon.color = on ? kEmojiGlyphOnDisc : self.contentColor;
    [CATransaction commit];
    CGAffineTransform tilt = CGAffineTransformScale(CGAffineTransformMakeRotation(-15 * M_PI / 180), 1.05, 1.05);
    SNAnimate(SNLiveComposerEmojiHover, SNEasePress(), ^{ self.icon.affineTransform = on ? tilt : CGAffineTransformIdentity; });
}

@end

/// The formatting toggle "Aa", underlined while the formatting bar shows.
@interface SNComposerToggleButton : SNButton
@property (nonatomic) BOOL on;
@end

@implementation SNComposerToggleButton {
    SNLayer *_underline;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _underline = [SNLayer layer];
    [self.layer addSublayer:_underline];
    return self;
}

- (void)layout {
    [super layout];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    CGFloat width = round(NSWidth(self.bounds) * 0.75);
    _underline.frame = CGRectMake((NSWidth(self.bounds) - width) / 2, NSHeight(self.bounds) - 4 - 1.5, width, 1.5);
    _underline.cornerRadius = 0.75;
    [CATransaction commit];
}

- (void)setOn:(BOOL)on {
    _on = on;
    [self stateDidChange];
}

- (void)stateDidChange {
    [super stateDidChange];
    SNColorToken content = self.pressed ? self.pressedContentColor : self.hovered ? self.hoverContentColor : self.contentColor;
    _underline.backgroundColor = SNCGColor(content);
    _underline.opacity = self.on ? 1 : 0;
    _underline.affineTransform = CGAffineTransformMakeTranslation(0, self.on ? 0 : 2);
}

@end

/// The paragraph-style button: a glyph and a caret.
@interface SNComposerMenuButton : SNButton
@end

@implementation SNComposerMenuButton {
    SNIconLayer *_caret;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _caret = [SNIconLayer iconNamed:@"caret-down" size:20 color:self.contentColor];
    [self.layer addSublayer:_caret];
    return self;
}

- (void)layout {
    [super layout];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    CGFloat glyph = self.icon.iconSize;
    self.icon.bounds = CGRectMake(0, 0, glyph, glyph);
    self.icon.position = CGPointMake(12, NSMidY(self.bounds));
    _caret.frame = CGRectMake(30 - 10, NSMidY(self.bounds) - 10, 20, 20);
    [CATransaction commit];
}

- (void)stateDidChange {
    [super stateDidChange];
    _caret.color = self.icon.color;
}

@end

#pragma mark Composer


/// A formatting-bar button: its kind of action and where it sits.
typedef struct {
    const char *icon, *tooltip;
    CGFloat centre;
} SNFormatButtonSpec;

static const SNFormatButtonSpec kFormatButtons[] = {
    {"bold", "composer.format.bold", 19},
    {"italic", "composer.format.italic", 51},
    {"underline", "composer.format.underline", 83},
    {"strikethrough", "composer.format.strike", 115},
    {"paragraph", "composer.format.paragraph", 155},
    {"link", "composer.format.link", 204},
    {"numbered-list", "composer.format.ordered", 236},
    {"bulleted-list", "composer.format.bullet", 268},
    {"quote", "composer.format.quote", 309},
    {"code", "composer.format.code", 341},
    {"code-block", "composer.format.codeblock", 373},
    {"divider", "composer.format.more", 405},
};
/// Slack's composer buttons are its "smedium" icon buttons, whose icons are 18 px.
static const CGFloat kButtonIcon = 18;
static const CGFloat kToolbarSeparators[] = {183, 288};
static const CGFloat kFooterSeparators[] = {135, 212};
typedef NS_ENUM(NSInteger, SNFooterButton) { SNFooterPlus, SNFooterFormat, SNFooterEmoji, SNFooterMention, SNFooterVideo, SNFooterMic, SNFooterSlash };
static const CGFloat kFooterCentres[] = {21, 51, 83, 115, 158, 190, 235};

@interface SNComposer () <SNComposerTextViewDelegate, SNChangeObserver>
@end

@implementation SNComposer {
    id<SNSource> _source;
    SNComposerContextBar *_contextBar;
    SNComposerBoxView *_box;
    NSScrollView *_scroll;
    SNComposerTextView *_textView;
    NSArray<SNButton *> *_formatButtons;
    NSArray<SNButton *> *_footerButtons;
    SNComposerSendPart *_send, *_sendOptions;
    SNComposerAutocomplete *_autocomplete;
    SNSlashCommands *_commands;
    SNComposerBroadcastToggle *_broadcast;
    NSString *_broadcastLabel;
    /// Who is typing here, or that Slack is trying to connect, in the margin under the box.
    SNComposerNotificationBar *_notice;
    NSSet<NSString *> *_typingUsers;
    /// When the connection went down (or the composer came without one); nil while connected.
    NSDate *_disconnectedSince;
    SNComposerAttachments *_attachments;
    /// The files attached to this conversation's or thread's composer, as the source has them.
    NSArray<SNUpload *> *_uploads;
    /// A GIF picked for the message (Slack's draft gif unfurl) and its thumbnail in the files row.
    NSDictionary *_gif;
    SNUpload *_gifItem;
    SNComposerDropOverlay *_dropOverlay;
    BOOL _toolbarShown;
    CGFloat _preferredHeight;
    /// What the buttons were last styled for (-1: not yet).
    NSInteger _styledFocus, _styledEmpty;
    /// The users the placeholder and the context bar name, and whether a group DM member is not
    /// known yet (any user who arrives may be them).
    NSSet<NSString *> *_namedUsers;
    BOOL _waitsForPeople;
}

- (instancetype)initWithSource:(id<SNSource>)source {
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, 848, 160)])) return nil;
    _source = source;
    _toolbarShown = YES;
    _styledFocus = _styledEmpty = -1;
    [source addChangeObserver:self];

    // _contextBar, _broadcast and _attachments are created lazily when first shown so idle
    // composers keep no hidden backing stores or layers on launch.
    // In the view tree only while it says something: even hidden, a view that draws gets a
    // backing store as wide as the composer.
    _notice = [[SNComposerNotificationBar alloc] initWithFrame:NSZeroRect];
    _box = [[SNComposerBoxView alloc] initWithFrame:NSZeroRect];
    _box.toolbarShown = YES;
    [self addSubview:_box];

    _textView = [[SNComposerTextView alloc] initWithFrame:NSMakeRect(0, 0, 400, SNComposerLineHeight)];
    _textView.composerDelegate = self;
    _scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    _scroll.drawsBackground = NO;
    _scroll.hasVerticalScroller = YES;
    _scroll.autohidesScrollers = YES;
    _scroll.scrollerStyle = NSScrollerStyleOverlay;
    _scroll.verticalScrollElasticity = NSScrollElasticityNone;
    _scroll.documentView = _textView;
    _scroll.contentView.postsBoundsChangedNotifications = YES;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(textDidScroll:) name:NSViewBoundsDidChangeNotification object:_scroll.contentView];
    [_box addSubview:_scroll];

    NSMutableArray *format = [NSMutableArray new];
    for (size_t i = 0; i < sizeof kFormatButtons / sizeof *kFormatButtons; i++) {
        SNFormatButtonSpec spec = kFormatButtons[i];
        BOOL paragraph = !strcmp(spec.icon, "paragraph");
        SNButton *button = paragraph ? [[SNComposerMenuButton alloc] initWithFrame:NSMakeRect(0, 0, 44, kButton)] : [SNButton iconButtonNamed:@(spec.icon) size:kButton iconSize:kButtonIcon];
        if (paragraph) {
            button.icon.iconName = @(spec.icon);
            button.icon.iconSize = kButtonIcon;
        }
        button.cornerRadius = SNRadiusSmall;
        button.tooltip = SNLocalized(@(spec.tooltip));
        __weak SNComposer *weakSelf = self;
        NSInteger index = (NSInteger)i;
        button.action = ^(SNButton *sender) { [weakSelf formatButtonClicked:index sender:sender]; };
        [format addObject:button];
        [_box addSubview:button];
    }
    _formatButtons = format;

    NSArray *footerIcons = @[ @"plus", @"formatting", @"emoji", @"mentions", @"video", @"microphone", @"slash-box" ];
    NSArray *footerTips = @[ @"composer.plus", @"composer.formatting.hide", @"composer.emoji", @"composer.mention", @"composer.video", @"composer.audio", @"composer.shortcuts" ];
    NSMutableArray *footer = [NSMutableArray new];
    for (NSUInteger i = 0; i < footerIcons.count; i++) {
        Class kind = i == SNFooterEmoji ? SNComposerEmojiButton.class : i == SNFooterFormat ? SNComposerToggleButton.class : SNButton.class;
        SNButton *button = [kind iconButtonNamed:footerIcons[i] size:kButton iconSize:kButtonIcon];
        // Live: footer buttons only brighten their glyph, with no fill.
        button.hoverFillColor = 0;
        button.overlayRadius = SNRadiusLarge;
        button.tooltip = SNLocalized(footerTips[i]);
        __weak SNComposer *weakSelf = self;
        button.action = ^(SNButton *sender) { [weakSelf footerButtonClicked:(SNFooterButton)i sender:sender]; };
        [footer addObject:button];
        [_box addSubview:button];
    }
    SNButton *plus = footer[SNFooterPlus];
    plus.fillColor = SNMeasuredComposerPlusRest;
    plus.hoverFillColor = SNMeasuredComposerPlusHover;
    plus.pressedColor = 0;
    plus.cornerRadius = kButton / 2;
    plus.tooltipPlacement = SNPlacementAbove;
    ((SNComposerToggleButton *)footer[SNFooterFormat]).on = YES;
    // Clips need recording and upload, which this client does not do yet.
    ((SNButton *)footer[SNFooterVideo]).enabled = NO;
    ((SNButton *)footer[SNFooterMic]).enabled = NO;
    _footerButtons = footer;

    // The send button's icons are 16 px (Slack's "small").
    _send = [[SNComposerSendPart alloc] initWithIcon:@"send-filled" size:16 leading:YES];
    _send.tooltip = SNLocalized(@"composer.send");
    __weak SNComposer *weakSelf = self;
    _send.action = ^(SNHoverView *view) { [weakSelf send]; };
    _sendOptions = [[SNComposerSendPart alloc] initWithIcon:@"caret-down" size:16 leading:NO];
    [_box addSubview:_send];
    [_box addSubview:_sendOptions];

    _autocomplete = [[SNComposerAutocomplete alloc] initWithSource:source];
    _commands = [[SNSlashCommands alloc] initWithSource:source];
    _commands.openGifPicker = ^(NSString *query) { [weakSelf showGifPickerWithQuery:query]; };
    [self applyPreferences];
    _autocomplete.choose = ^(SNRichEntity *entity, NSString *text, NSRange range) {
        SNComposer *composer = weakSelf;
        // A command goes in as the text it is, with the space after it.
        if (entity) [composer insertEntity:entity text:text replacingRange:range];
        else [composer->_textView insertText:[text stringByAppendingString:@" "] replacementRange:range];
    };
    [self updateState];
    return self;
}

- (void)dealloc {
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [_autocomplete close];
}

- (BOOL)isFlipped { return YES; }

#pragma mark Preferences

/// The Preferences' input options: Return, spellcheck, and smart quotes and symbols. Slack always
/// sends these; without them (fixtures) the composer stays plain.
- (void)applyPreferences {
    NSDictionary *preferences = _source.preferences;
    _textView.returnStartsLine = SNPreferenceBool(preferences, @"msg_input_send_btn", NO);
    _textView.returnStartsLineInCode = SNPreferenceBool(preferences, @"enter_is_special_in_tbt", NO);
    _textView.continuousSpellCheckingEnabled = SNPreferenceBool(preferences, @"webapp_spellcheck", NO);
    BOOL smart = !SNPreferenceBool(preferences, @"disable_smart_symbols", YES);
    _textView.automaticQuoteSubstitutionEnabled = _textView.automaticDashSubstitutionEnabled = smart;
}

#pragma mark Conversation

- (SNComposerContextBar *)ensureContextBar {
    if (!_contextBar) {
        _contextBar = [[SNComposerContextBar alloc] initWithFrame:NSZeroRect];
        _contextBar.hidden = YES;
        [self addSubview:_contextBar positioned:NSWindowBelow relativeTo:_box];
    }
    return _contextBar;
}

- (SNComposerBroadcastToggle *)ensureBroadcast {
    if (!_broadcast) {
        _broadcast = [[SNComposerBroadcastToggle alloc] initWithFrame:NSZeroRect];
        _broadcast.hidden = YES;
        if (_broadcastLabel) _broadcast.label = _broadcastLabel;
        [self addSubview:_broadcast];
    }
    return _broadcast;
}

- (SNComposerAttachments *)ensureAttachments {
    if (!_attachments) {
        _attachments = [[SNComposerAttachments alloc] initWithFrame:NSZeroRect];
        _attachments.hidden = YES;
        __weak SNComposer *composer = self;
        _attachments.remove = ^(SNUpload *upload) { [composer removeUpload:upload]; };
        [_box addSubview:_attachments];
    }
    return _attachments;
}

- (void)showConversation:(NSString *)conversationID threadTS:(NSString *)threadTS {
    [self saveDraft];
    _gif = nil;
    _gifItem = nil;
    _conversationID = [conversationID copy];
    _threadTS = [threadTS copy];
    if (threadTS) {
        SNComposerBroadcastToggle *broadcast = [self ensureBroadcast];
        broadcast.hidden = NO;
        broadcast.checked = NO;
    } else if (_broadcast) {
        _broadcast.hidden = YES;
        _broadcast.checked = NO;
    }
    [_autocomplete close];
    _autocomplete.conversationID = conversationID;
    _autocomplete.threadTS = threadTS;
    _contextBar.notice = nil;
    NSString *draft = conversationID ? [_source draftInConversation:conversationID threadTS:threadTS] : nil;
    __weak id<SNSource> source = _source;
    _textView.document = draft.length ? SNRichDocumentFromDraft(draft, ^NSString *(SNRichEntityKind kind, NSString *value) {
        if (kind == SNRichEntityUser) return [source userWithID:value].visibleName;
        if (kind == SNRichEntityChannel) return [source conversationWithID:value].name;
        if (kind == SNRichEntityUsergroup) return [source usergroupHandleWithID:value];
        return nil;
    })
                                      : [NSAttributedString new];
    [self updateUploads];
    [self updatePlaceholder];
    [self updateNotice];
    [self updateState];
}

- (NSString *)noticeText { return _notice.text; }

/// The bar's runs: `template`'s text with each %@ replaced by the next name, in bold.
static NSArray<NSArray *> *Runs(NSString *template, NSArray<NSString *> *names) {
    NSMutableArray *runs = [NSMutableArray new];
    NSArray<NSString *> *parts = [template componentsSeparatedByString:@"%@"];
    for (NSUInteger i = 0; i < parts.count; i++) {
        if (parts[i].length) [runs addObject:@[ parts[i], @NO ]];
        if (i + 1 < parts.count && i < names.count) [runs addObject:@[ names[i], @YES ]];
    }
    return runs;
}

/// TypingNames: one name, two, or "several people" from three on; the offline notice wins once
/// the connection has been down past the grace (with a draft, it says sending must wait).
- (void)updateNotice {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(updateNotice) object:nil];
    BOOL connected = _source.connectionState == SNConnectionConnected;
    if (connected) _disconnectedSince = nil;
    else if (!_disconnectedSince) _disconnectedSince = NSDate.date;
    NSTimeInterval left = _disconnectedSince ? kOfflineGrace + _disconnectedSince.timeIntervalSinceNow : 0;
    if (_disconnectedSince && left > 0) [self performSelector:@selector(updateNotice) withObject:nil afterDelay:left];
    _notice.offline = _disconnectedSince && left <= 0;
    if (_notice.offline) {
        _typingUsers = nil;
        _notice.runs = Runs(SNLocalized(_textView.string.length > 2 ? @"composer.offline.draft" : @"composer.offline"), @[]);
        return [self placeNotice];
    }
    NSArray<NSString *> *userIDs = _conversationID ? [_source typingUserIDsInConversation:_conversationID threadTS:_threadTS] : @[];
    _typingUsers = [NSSet setWithArray:userIDs];
    NSMutableArray<NSString *> *names = [NSMutableArray new];
    for (NSString *userID in userIDs) [names addObject:[_source userWithID:userID].visibleName ?: @""];
    _notice.runs = names.count > 2 ? Runs(SNLocalized(@"composer.typing.several"), @[])
                 : names.count ? Runs(SNLocalized(names.count == 1 ? @"composer.typing.one" : @"composer.typing.two"), names)
                               : @[];
    [self placeNotice];
}

- (void)placeNotice {
    if (_notice.runs.count && !_notice.superview) {
        [self addSubview:_notice];
        self.needsLayout = YES;
    } else if (!_notice.runs.count && _notice.superview) [_notice removeFromSuperview];
}

- (void)updateUploads {
    _uploads = _conversationID ? [_source uploadsInConversation:_conversationID threadTS:_threadTS] : @[];
    BOOL has = _uploads.count > 0 || _gifItem != nil;
    if (has || _attachments) {
        SNComposerAttachments *attachments = has ? [self ensureAttachments] : _attachments;
        attachments.uploads = _gifItem ? [@[ _gifItem ] arrayByAddingObjectsFromArray:_uploads] : _uploads;
        attachments.hidden = !has;
    }
}

- (NSString *)draftKey { return _threadTS ? SNThreadKey(_conversationID, _threadTS) : _conversationID; }

/// Drafts keep the document's rich_text, so they come back exactly as typed.
- (void)saveDraft {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(saveDraft) object:nil];
    if (!_conversationID) return;
    [_source setDraft:SNRichDraftFromDocument(_textView.document) inConversation:_conversationID threadTS:_threadTS];
}

- (void)sourceChanged:(SNChange *)change {
    if (_conversationID && [change.uploads containsObject:self.draftKey]) {
        [self updateUploads];
        [self updateState];
    }
    // The list asked for while "/" was typed arrives later.
    if (change.commands && _textView.isFocused) [self updateAutocomplete];
    if (change.preferences) [self applyPreferences];
    if ((_conversationID && [change.typing containsObject:self.draftKey]) || [change.users intersectsSet:_typingUsers] ||
        change.preferences || change.connection)
        [self updateNotice];
    BOOL conversation = _conversationID && [change.conversations containsObject:_conversationID];
    NSSet *users = change.users;
    BOOL named = [users intersectsSet:_namedUsers] || (users.count && _waitsForPeople);
    // A DM's person pausing notifications shows or hides the bar above the box.
    BOOL snoozed = [change.presence intersectsSet:_namedUsers];
    if (!conversation && !named && !snoozed) return;
    if (conversation || named) [self updatePlaceholder];
    [self updateHeight];
}

/// The placeholder Slack shows for the conversation (pt-BR in the captures).
- (void)updatePlaceholder {
    SNConversation *conversation = _conversationID ? [_source conversationWithID:_conversationID] : nil;
    NSMutableSet *named = [NSMutableSet new];
    if (_source.me.userID) [named addObject:_source.me.userID];
    NSArray<SNUser *> *people = conversation ? SNConversationPeople(conversation, _source) : @[];
    for (SNUser *user in people) [named addObject:user.userID];
    _waitsForPeople = conversation.kind == SNConversationGroupDirect && people.count < SNGroupDMHandles(conversation, _source).count;
    if (conversation.userID) [named addObject:conversation.userID];
    _namedUsers = named;
    BOOL lock = NO;
    NSString *text = @"";
    if (_threadTS) {
        text = SNLocalized(@"composer.placeholder.thread");
    } else if (conversation.kind == SNConversationDirect && [conversation.userID isEqualToString:_source.me.userID]) {
        text = SNLocalized(@"composer.placeholder.self");
    } else if (conversation.isDirect) {
        text = SNLocalizedFormat(@"composer.placeholder.message", SNConversationTitle(conversation, _source));
    } else if (conversation.kind == SNConversationPrivateChannel) {
        text = SNLocalizedFormat(@"composer.placeholder.message", conversation.name);
        lock = YES;
    } else if (conversation) {
        text = SNLocalizedFormat(@"composer.placeholder.message", [@"#" stringByAppendingString:conversation.name]);
    }
    _textView.placeholder = text;
    _textView.placeholderLock = lock;
    NSString *to = conversation.kind == SNConversationDirect ? SNLocalized(@"composer.alsosend.dm")
                 : conversation.kind == SNConversationGroupDirect ? SNLocalized(@"composer.alsosend.group")
                 : SNLocalizedFormat(@"composer.alsosend.channel", conversation.kind == SNConversationPrivateChannel ? conversation.name ?: @""
                                                                                                                      : [@"#" stringByAppendingString:conversation.name ?: @""]);
    _broadcastLabel = to;
    _broadcast.label = to;
}

- (BOOL)showsContextBar {
    if (_contextBar.notice) return YES;
    SNConversation *conversation = _conversationID ? [_source conversationWithID:_conversationID] : nil;
    if (conversation.kind != SNConversationDirect || _threadTS) return NO;
    SNUser *user = [_source userWithID:conversation.userID ?: @""];
    return user && [_source doNotDisturbOfUser:user.userID] && ![user.userID isEqualToString:_source.me.userID];
}

#pragma mark Layout

- (CGFloat)textHeightForWidth {
    // Measured at the width the text will have, even before the next layout pass.
    CGFloat width = MAX(0, NSWidth(self.bounds) - 2 * kSideMargin - 2 * kTextInset);
    if (NSWidth(_textView.frame) != width) [_textView setFrameSize:NSMakeSize(width, NSHeight(_textView.frame))];
    CGFloat lines = _textView.contentHeight;
    CGFloat maximum = 256;
    if (self.window) maximum = MAX(SNComposerLineHeight, self.window.contentView.bounds.size.height * 0.6 - 80);
    return MIN(lines, maximum);
}

- (CGFloat)attachmentsHeight { return _uploads.count || _gifItem ? SNComposerAttachmentsHeight : 0; }

- (CGFloat)boxHeight {
    CGFloat top = _toolbarShown ? kToolbar + kTextTop : 1 + kNoToolbarTextTop;
    return top + [self textHeightForWidth] + kTextBottom + self.attachmentsHeight + kFooter + 1;
}

- (CGFloat)contextBarHeight { return (!_contextBar || _contextBar.hidden) ? 0 : [_contextBar heightForWidth:MAX(0, NSWidth(self.bounds) - 2 * kSideMargin)]; }

- (CGFloat)broadcastHeight { return (!_broadcast || _broadcast.hidden) ? 0 : kBroadcastGap + kBroadcastLine; }

- (CGFloat)preferredHeight { return self.contextBarHeight + self.boxHeight + self.broadcastHeight + kBottomMargin; }

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    self.needsLayout = YES;
}

- (void)layout {
    [super layout];
    NSSize size = self.bounds.size;
    CGFloat boxWidth = MAX(0, size.width - 2 * kSideMargin);
    CGFloat top = self.contextBarHeight;
    _contextBar.frame = NSMakeRect(kSideMargin, 0, boxWidth, top + kContextFiller);
    CGFloat boxHeight = self.boxHeight;
    _box.frame = NSMakeRect(kSideMargin, top, boxWidth, boxHeight);
    _broadcast.frame = NSMakeRect(kSideMargin + 2, top + boxHeight + kBroadcastGap, MIN(boxWidth, 400), kBroadcastLine);
    _notice.frame = NSMakeRect(kSideMargin + kNoticeInset, top + boxHeight + self.broadcastHeight, MAX(0, boxWidth - kNoticeInset - 8), kBottomMargin);

    CGFloat textTop = _toolbarShown ? kToolbar : 1;
    CGFloat textPadding = _toolbarShown ? kTextTop : kNoToolbarTextTop;
    CGFloat attachments = self.attachmentsHeight;
    NSRect scroll = NSMakeRect(kTextInset, textTop, MAX(0, boxWidth - 2 * kTextInset), boxHeight - textTop - attachments - kFooter - 1);
    // The files' row sits under the text, inside the border, reaching up over the text a little.
    _attachments.frame = NSMakeRect(1, NSMaxY(scroll) - SNComposerAttachmentsOverhang, MAX(0, boxWidth - 2), attachments + SNComposerAttachmentsOverhang);
    if (!NSEqualRects(_scroll.frame, scroll)) _scroll.frame = scroll;
    if (_textView.textContainerInset.height != textPadding) _textView.textContainerInset = NSMakeSize(0, textPadding);
    NSRect document = NSMakeRect(0, 0, scroll.size.width, MAX(_textView.contentHeight + textPadding + kTextBottom, scroll.size.height));
    if (!NSEqualRects(_textView.frame, document)) _textView.frame = document;
    if (!NSEqualSizes(_textView.minSize, scroll.size)) _textView.minSize = scroll.size;
    if (_textView.maxSize.width != scroll.size.width) _textView.maxSize = NSMakeSize(scroll.size.width, CGFLOAT_MAX);

    // Formatting bar: at wide widths (>= 425 pt box), every button keeps its measured position;
    // at narrower widths (e.g. 393 pt thread pane), trailing buttons collapse into the More button.
    NSUInteger count = _formatButtons.count, regularCount = count > 0 ? count - 1 : 0;
    CGFloat formatLimit = boxWidth - 6;
    BOOL formatOverflows = count > 0 && kFormatButtons[count - 1].centre + _formatButtons.lastObject.frame.size.width / 2 > formatLimit;
    NSUInteger visibleRegular = 0;
    CGFloat lastFormatRight = 0;
    for (NSUInteger i = 0; i < regularCount; i++) {
        SNButton *button = _formatButtons[i];
        CGFloat width = button.frame.size.width;
        CGFloat right = kFormatButtons[i].centre + width / 2;
        BOOL fits = _toolbarShown && (!formatOverflows || right + 4 + kButton <= formatLimit);
        button.frame = NSMakeRect(kFormatButtons[i].centre - width / 2, 21 - kButton / 2, width, kButton);
        button.hidden = !fits;
        if (fits) {
            visibleRegular = i + 1;
            lastFormatRight = right;
        }
    }
    if (count > 0) {
        SNButton *more = _formatButtons[count - 1];
        CGFloat width = more.frame.size.width;
        CGFloat x = formatOverflows ? MIN(formatLimit - width, lastFormatRight + (visibleRegular ? 6 : 6)) : kFormatButtons[count - 1].centre - width / 2;
        more.frame = NSMakeRect(MAX(5, x), 21 - kButton / 2, width, kButton);
        more.hidden = !_toolbarShown || (formatOverflows && x + width > boxWidth - 2);
    }
    _box.toolbarShown = _toolbarShown;
    if (_box.textBottom != NSMaxY(scroll)) {
        _box.textBottom = NSMaxY(scroll);
        _box.needsDisplay = YES;
    }
    NSMutableArray<NSNumber *> *toolbarSeps = [NSMutableArray new];
    if (_toolbarShown) {
        if (!formatOverflows || visibleRegular > 5) [toolbarSeps addObject:@(kToolbarSeparators[0])];
        if (!formatOverflows || visibleRegular > 8) [toolbarSeps addObject:@(kToolbarSeparators[1])];
    }
    _box.toolbarSeparators = toolbarSeps;
    CGFloat footer = boxHeight - 1 - kFooter / 2;
    // The split send button: a 36 pt plane and a 24 pt caret, 9 pt from the box's right edge.
    _send.frame = NSMakeRect(boxWidth - 9 - 24 - 36, footer - kButton / 2, 36, kButton);
    _sendOptions.frame = NSMakeRect(boxWidth - 9 - 24, footer - kButton / 2, 24, kButton);
    CGFloat footerLimit = NSMinX(_send.frame) - 8;
    BOOL footerVisible[7] = {NO};
    for (NSUInteger i = 0; i < _footerButtons.count; i++) {
        CGFloat right = kFooterCentres[i] + kButton / 2;
        BOOL fits = right <= footerLimit;
        if (i < 7) footerVisible[i] = fits;
        _footerButtons[i].frame = NSMakeRect(kFooterCentres[i] - kButton / 2, footer - kButton / 2, kButton, kButton);
        _footerButtons[i].hidden = !fits;
    }
    NSMutableArray<NSNumber *> *footerSeps = [NSMutableArray new];
    if (footerVisible[SNFooterVideo] || footerVisible[SNFooterMic]) [footerSeps addObject:@(kFooterSeparators[0])];
    if (footerVisible[SNFooterSlash]) [footerSeps addObject:@(kFooterSeparators[1])];
    _box.footerSeparators = footerSeps;
    [self updateOverflow];
}

- (void)updateHeight {
    BOOL bar = self.showsContextBar;
    if (bar) {
        SNComposerContextBar *contextBar = [self ensureContextBar];
        if (contextBar.hidden) {
            contextBar.hidden = NO;
            contextBar.needsDisplay = YES;
        }
    } else if (_contextBar && !_contextBar.hidden) {
        _contextBar.hidden = YES;
    }
    CGFloat height = self.preferredHeight;
    self.needsLayout = YES;
    if (height == _preferredHeight) return;
    _preferredHeight = height;
    if (self.heightDidChange) self.heightDidChange(self);
}

- (void)textDidScroll:(NSNotification *)notification { [self updateOverflow]; }

- (void)updateOverflow {
    NSRect visible = _scroll.contentView.bounds;
    BOOL above = NSMinY(visible) > 0.5, below = NSMaxY(visible) < NSHeight(_textView.frame) - 0.5;
    if (above == _box.hiddenAbove && below == _box.hiddenBelow) return;
    _box.hiddenAbove = above;
    _box.hiddenBelow = below;
    _box.needsDisplay = YES;
}

#pragma mark State

/// Focus and emptiness restyle the box and its buttons (composer-focus, send-button-enable).
- (void)updateState {
    // The offline notice says whether a draft has to wait.
    if (_notice.offline) [self updateNotice];
    // Files alone are a message: Send lights up for them as for text.
    BOOL focused = _textView.isFocused, empty = _textView.isEmpty && !_uploads.count && !_gif;
    if (focused != _styledFocus || empty != _styledEmpty) [self styleForFocus:focused empty:empty];
    [self updateHeight];
}

- (void)styleForFocus:(BOOL)focused empty:(BOOL)empty {
    _styledFocus = focused;
    _styledEmpty = empty;
    _box.focused = focused;
    for (SNButton *button in _formatButtons) {
        // Live: with the composer unfocused the bar is dimmed and its buttons do not react.
        button.contentColor = focused ? SNColorContentSec : SNMeasuredComposerFormatIconUnfocused;
        button.hoverContentColor = button.pressedContentColor = focused ? SNColorContentPry : SNMeasuredComposerFormatIconUnfocused;
        button.hoverFillColor = focused ? SNColorCtrPry : 0;
        button.pressedColor = focused ? SNOverlayPressed : 0;
    }
    _send.active = _sendOptions.active = !empty;
}

- (BOOL)isFocused { return _textView.isFocused; }

- (void)focus { [self.window makeFirstResponder:_textView]; }

- (NSString *)text { return _textView.string; }

- (void)setText:(NSString *)text {
    _textView.document = SNRichDocumentFromMrkdown(text, nil);
    [self updateState];
}

- (NSString *)notice { return _contextBar.notice; }

- (NSView *)attachmentsView { return [self ensureAttachments]; }

- (void)showNotice:(NSString *)notice {
    if (notice) [self ensureContextBar].notice = notice;
    else _contextBar.notice = nil;
    [self updateHeight];
}

#pragma mark Actions

- (void)formatButtonClicked:(NSInteger)index sender:(SNButton *)sender {
    if (!_textView.isFocused) return;
    switch (index) {
    case 0: [_textView toggleStyle:SNInlineBold]; break;
    case 1: [_textView toggleStyle:SNInlineItalic]; break;
    case 2: [_textView toggleStyle:SNInlineUnderline]; break;
    case 3: [_textView toggleStyle:SNInlineStrike]; break;
    case 4: [self showParagraphMenuFrom:sender]; break;
    case 5: [_textView beginLink]; break;
    case 6: [_textView toggleBlock:SNRichBlockOrdered]; break;
    case 7: [_textView toggleBlock:SNRichBlockBullet]; break;
    case 8: [_textView toggleBlock:SNRichBlockQuote]; break;
    case 9: [_textView toggleStyle:SNInlineCode]; break;
    case 10: [_textView toggleBlock:SNRichBlockCode]; break;
    case 11: [self showFormatOverflowMenuFrom:sender]; break;
    default: break;
    }
}

- (void)showFormatOverflowMenuFrom:(SNButton *)sender {
    NSMutableArray<SNMenuItem *> *items = [NSMutableArray new];
    __weak SNComposer *weakSelf = self;
    NSUInteger regularCount = _formatButtons.count > 0 ? _formatButtons.count - 1 : 0;
    for (NSUInteger i = 0; i < regularCount; i++) {
        if (!_formatButtons[i].hidden) continue;
        NSInteger index = (NSInteger)i;
        SNMenuItem *item = [SNMenuItem itemWithTitle:SNLocalized(@(kFormatButtons[i].tooltip)) action:^{
            SNComposer *composer = weakSelf;
            if (!composer) return;
            [composer focus];
            [composer formatButtonClicked:index sender:sender];
        }];
        item.icon = @(kFormatButtons[i].icon);
        item.iconSize = 18;
        [items addObject:item];
    }
    if (!items.count) return;
    [[[SNMenu alloc] initWithItems:items width:220] showForRect:sender.bounds inView:sender placement:SNPlacementAbove];
}

- (void)showParagraphMenuFrom:(SNButton *)sender {
    __weak SNComposerTextView *text = _textView;
    NSArray *items = @[
        [SNMenuItem itemWithTitle:SNLocalized(@"composer.format.bullet") action:^{ [text toggleBlock:SNRichBlockBullet]; }],
        [SNMenuItem itemWithTitle:SNLocalized(@"composer.format.ordered") action:^{ [text toggleBlock:SNRichBlockOrdered]; }],
        [SNMenuItem itemWithTitle:SNLocalized(@"composer.format.quote") action:^{ [text toggleBlock:SNRichBlockQuote]; }],
        [SNMenuItem itemWithTitle:SNLocalized(@"composer.format.codeblock") action:^{ [text toggleBlock:SNRichBlockCode]; }],
    ];
    [[[SNMenu alloc] initWithItems:items width:240] showForRect:sender.bounds inView:sender placement:SNPlacementAbove];
}

- (void)footerButtonClicked:(SNFooterButton)button sender:(SNButton *)sender {
    switch (button) {
    case SNFooterPlus: [self showPlusMenuFrom:sender]; break;
    case SNFooterFormat:
        _toolbarShown = !_toolbarShown;
        ((SNComposerToggleButton *)sender).on = _toolbarShown;
        sender.tooltip = SNLocalized(_toolbarShown ? @"composer.formatting.hide" : @"composer.formatting.show");
        [self updateHeight];
        break;
    case SNFooterEmoji: {
        __weak SNComposer *weakSelf = self;
        [SNEmojiPicker showForRect:sender.bounds inView:sender placement:SNPlacementAbove source:_source completion:^(NSString *name) {
            [weakSelf insertEmojiNamed:name];
        }];
        break;
    }
    case SNFooterMention: {
        [self focus];
        [_textView insertText:@"@" replacementRange:_textView.selectedRange];
        break;
    }
    case SNFooterSlash:
        // The shortcuts button starts a command: the list opens on the "/".
        [self focus];
        if (_textView.isEmpty) [_textView insertText:@"/" replacementRange:_textView.selectedRange];
        break;
    case SNFooterVideo:
    case SNFooterMic:
        // Clips need recording and upload, which this client does not do yet.
        break;
    }
}

/// The '+' menu; while it is open the '+' turns into an x (composer-footer-button-hover, live).
- (void)showPlusMenuFrom:(SNButton *)sender {
    SNMenuItem *snippet = [SNMenuItem itemWithTitle:SNLocalized(@"composer.plus.snippet") action:nil];
    snippet.icon = @"text-snippet";
    snippet.shortcut = @"⌘⇧Enter";
    snippet.disabled = YES;
    __weak SNComposer *weakSelf = self;
    SNMenuItem *upload = [SNMenuItem itemWithTitle:SNLocalized(@"composer.plus.upload") action:^{ [weakSelf chooseFiles]; }];
    upload.icon = @"laptop";
    upload.shortcut = @"⌘O";
    SNMenuItem *file = [SNMenuItem itemWithTitle:SNLocalized(@"composer.plus.file") action:nil];
    file.icon = @"canvas-browser";
    file.disabled = YES;
    id gifAllowed = SNJSONObject(_source.workspace.json, @"prefs")[@"allow_native_gif_picker"];
    BOOL gifEnabled = !([gifAllowed isKindOfClass:NSNumber.class] && ![gifAllowed boolValue]);
    SNMenuItem *gif = [SNMenuItem itemWithTitle:SNLocalized(@"composer.plus.gif") action:gifEnabled ? ^{ [weakSelf showGifPickerWithQuery:@""]; } : nil];
    gif.icon = @"gif";
    gif.disabled = !gifEnabled;
    SNMenuItem *workflow = [SNMenuItem itemWithTitle:SNLocalized(@"composer.plus.workflow") action:nil];
    workflow.icon = @"play";
    workflow.disabled = YES;
    for (SNMenuItem *item in @[ file, gif, snippet, workflow, upload ]) item.iconSize = 20;
    SNPopover *popover = [[[SNMenu alloc] initWithItems:@[ file, gif, snippet, workflow, upload ] width:0] showForRect:sender.bounds inView:sender placement:SNPlacementAbove];
    CGAffineTransform turned = CGAffineTransformMakeRotation(-135 * M_PI / 180);
    SNAnimate(SNLiveComposerPlusRotate, SNEaseLiveComposerPlusRotate(), ^{ sender.icon.affineTransform = turned; });
    popover.onClose = ^{
        SNAnimate(SNLiveComposerPlusRotate, SNEaseLiveComposerPlusRotate(), ^{ sender.icon.affineTransform = CGAffineTransformIdentity; });
    };
}

- (void)insertEmojiNamed:(NSString *)name {
    [self focus];
    NSString *unicode = SNEmojiUnicode(name);
    [_textView insertEntity:[SNRichEntity emojiWithName:name unicode:unicode ? SNCodePointsOfText(unicode) : nil] text:unicode ?: SNRichCustomEmojiText
             replacingRange:_textView.selectedRange];
    [_source noteEmojiUsed:name];
}

- (void)insertEntity:(SNRichEntity *)entity text:(NSString *)text replacingRange:(NSRange)range {
    [_textView insertEntity:entity text:text replacingRange:range];
}

- (void)send {
    if (!_conversationID) return;
    [_autocomplete close];
    if (SNRichStartsWithCommand(_textView.document)) return [self runCommand];
    SNRichMessage *message = SNRichMessageFromDocument(_textView.document);
    if (!message && !_uploads.count && !_gif) return;
    BOOL broadcast = _threadTS && _broadcast.checked;
    if (_gif) {
        // The GIF goes with the text; files picked as well follow in a message of their own.
        [_source sendText:message.text ?: @"" blocks:message.blocks attachments:@[ _gif ] inConversation:_conversationID threadTS:_threadTS broadcast:broadcast];
        _gif = nil;
        _gifItem = nil;
        message = nil;
    }
    if (message || _uploads.count)
        [_source sendText:message.text ?: @"" blocks:message.blocks uploads:_uploads inConversation:_conversationID threadTS:_threadTS broadcast:broadcast];
    [self updateUploads];
    _broadcast.checked = NO;
    _textView.document = [NSAttributedString new];
    [self saveDraft];
    [self updateState];
}

/// A slash command: the composer empties at once and gets the text back if the command asks to
/// keep it (Slack's keep_input, a /msg that could not be sent).
- (void)runCommand {
    NSAttributedString *document = _textView.document;
    NSString *string = document.string;
    NSRange space = [string rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSUInteger end = space.location == NSNotFound ? string.length : space.location;
    NSString *typed = [string substringToIndex:end];
    // The rest: what follows the command and the space after it.
    NSUInteger rest = MIN(string.length, end + (space.location == NSNotFound ? 0 : 1));
    NSString *conversationID = _conversationID;
    _textView.document = [NSAttributedString new];
    [self saveDraft];
    [self updateState];
    __weak SNComposer *weakSelf = self;
    _commands.navigator = self.navigator;
    [_commands run:typed
                  rest:[document attributedSubstringFromRange:NSMakeRange(rest, string.length - rest)]
        inConversation:conversationID
              threadTS:_threadTS
                window:self.window
               restore:^{
                   SNComposer *composer = weakSelf;
                   if (![composer.conversationID isEqualToString:conversationID] || !composer->_textView.isEmpty) return;
                   composer->_textView.document = document;
                   [composer saveDraft];
                   [composer updateState];
               }];
}

#pragma mark GIFs

- (void)showGifPickerWithQuery:(NSString *)query {
    SNButton *anchor = _footerButtons[SNFooterEmoji].hidden ? _footerButtons[SNFooterPlus] : _footerButtons[SNFooterEmoji];
    __weak SNComposer *weakSelf = self;
    [SNGifPicker showForRect:anchor.bounds inView:anchor source:_source query:query picked:^(NSDictionary *attachment, NSURL *preview) {
        SNComposer *composer = weakSelf;
        if (!composer || !preview) return;
        composer->_gif = attachment;
        composer->_gifItem = [[SNUpload uploadWithFile:preview name:@"GIF" mimeType:@"image/gif" size:0] uploadWithState:SNUploadReady progress:1 fileID:nil error:nil];
        [composer updateUploads];
        [composer updateState];
        [composer focus];
    }];
}

#pragma mark Files

- (void)chooseFiles {
    if (!_conversationID || !self.window) return;
    NSOpenPanel *panel = NSOpenPanel.openPanel;
    panel.allowsMultipleSelection = YES;
    panel.canChooseDirectories = NO;
    __weak SNComposer *weakSelf = self;
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response == NSModalResponseOK) [weakSelf attachFiles:panel.URLs];
    }];
}

- (void)attachFiles:(NSArray<NSURL *> *)files { [self attachFiles:files sendingNow:NO]; }

- (void)attachFiles:(NSArray<NSURL *> *)files sendingNow:(BOOL)now {
    if (!_conversationID || !files.count) return;
    NSMutableArray<NSURL *> *good = [NSMutableArray new], *unsupported = [NSMutableArray new], *large = [NSMutableArray new];
    for (NSURL *file in files) {
        NSDictionary *values = [file resourceValuesForKeys:@[ NSURLIsDirectoryKey, NSURLFileSizeKey ] error:nil];
        // A browser hands Slack neither folders (packages included) nor empty files.
        if ([values[NSURLIsDirectoryKey] boolValue] || [values[NSURLFileSizeKey] longLongValue] <= 0) [unsupported addObject:file];
        else if ([values[NSURLFileSizeKey] longLongValue] > kFileSizeLimit) [large addObject:file];
        else [good addObject:file];
    }
    NSUInteger room = kMaximumFiles - MIN(kMaximumFiles, now ? 0 : _uploads.count);
    if (good.count > room) {
        [good removeObjectsInRange:NSMakeRange(room, good.count - room)];
        [self showNotice:SNLocalizedFormat(@"composer.files.tooMany", @(kMaximumFiles))];
    }
    NSString *conversationID = _conversationID, *threadTS = _threadTS;
    NSArray<NSString *> *before = [_uploads valueForKey:@"uploadID"];
    if (good.count) [_source attachFiles:good inConversation:conversationID threadTS:threadTS];
    // Shift on a drop shares the files at once, in a message of their own.
    if (now && good.count) {
        NSMutableArray<SNUpload *> *added = [NSMutableArray new];
        for (SNUpload *upload in [_source uploadsInConversation:conversationID threadTS:threadTS])
            if (![before containsObject:upload.uploadID]) [added addObject:upload];
        [_source sendText:@"" blocks:nil uploads:added inConversation:conversationID threadTS:threadTS broadcast:NO];
    }
    [self explainRefused:large unsupported:unsupported attached:good.count];
}

/// Slack's dialogs for files it will not take: too large first, else unsupported.
- (void)explainRefused:(NSArray<NSURL *> *)large unsupported:(NSArray<NSURL *> *)unsupported attached:(NSUInteger)attached {
    if (!self.window || (!large.count && !unsupported.count)) return;
    NSString *title, *text;
    if (large.count) {
        title = SNLocalized(@"composer.files.large.title");
        NSString *key = large.count == 1 && !attached && !unsupported.count ? @"composer.files.large.one" : attached ? @"composer.files.large.some" : @"composer.files.large.all";
        text = SNLocalizedFormat(key, SNLocalized(@"composer.files.large.limit"));
    } else {
        BOOL all = !attached, several = unsupported.count > 1;
        title = SNLocalized(all && several ? @"composer.files.unsupported.all" : !all ? @"composer.files.unsupported.some" : @"composer.files.unsupported.title");
        text = [NSString stringWithFormat:@"%@ %@", SNLocalizedFormat(@"composer.files.unsupported.text", unsupported[0].lastPathComponent),
                                          SNLocalized(several ? @"composer.files.unsupported.zips" : @"composer.files.unsupported.zip")];
        if (attached) text = [text stringByAppendingFormat:@" %@", SNLocalized(attached > 1 ? @"composer.files.unsupported.next.many" : @"composer.files.unsupported.next")];
    }
    [SNConfirmDialog showAlertInWindow:self.window title:title text:text buttonTitle:SNLocalized(@"composer.files.ok")];
}

#pragma mark Drops

- (NSDragOperation)dragEntered:(id<NSDraggingInfo>)drag overView:(NSView *)view {
    if (!_conversationID || self.hidden || ![drag.draggingPasteboard availableTypeFromArray:SNComposerFileTypes()]) return NSDragOperationNone;
    if (_dropOverlay.superview != view) {
        [_dropOverlay removeFromSuperview];
        _dropOverlay = [[SNComposerDropOverlay alloc] initWithTitle:self.dropTitle hint:self.dropHint thread:_threadTS != nil];
        // inset: -1px 0 0, over the pane's top hairline.
        _dropOverlay.frame = NSMakeRect(0, view.isFlipped ? -1 : 0, NSWidth(view.bounds), NSHeight(view.bounds) + 1);
        _dropOverlay.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [view addSubview:_dropOverlay];
    }
    return NSDragOperationCopy;
}

- (void)dragExited {
    [_dropOverlay removeFromSuperview];
    _dropOverlay = nil;
}

- (BOOL)performDrag:(id<NSDraggingInfo>)drag {
    [self dragExited];
    NSArray<NSURL *> *files = SNComposerFilesFromPasteboard(drag.draggingPasteboard);
    if (!files.count) return NO;
    [self attachFiles:files sendingNow:(NSEvent.modifierFlags & NSEventModifierFlagShift) != 0];
    return YES;
}

/// "Upload to <workspace>" over a conversation, "Upload to thread" over a thread.
- (NSString *)dropTitle {
    return _threadTS ? SNLocalized(@"composer.drop.thread") : SNLocalizedFormat(@"composer.drop.title", _source.workspace.name ?: @"");
}

/// "Hold %@ to share immediately to #general" (with someone, in a DM), %@ where the Shift chip goes.
- (NSString *)dropHint {
    if (_threadTS) return SNLocalized(@"composer.drop.share");
    SNConversation *conversation = [_source conversationWithID:_conversationID];
    NSString *name = conversation.isDirect ? SNConversationTitle(conversation, _source)
                   : conversation.kind == SNConversationPrivateChannel ? conversation.name ?: @""
                                                                       : [@"#" stringByAppendingString:conversation.name ?: @""];
    NSString *template = SNLocalized(conversation.isDirect ? @"composer.drop.shareWith" : @"composer.drop.shareTo");
    NSRange first = [template rangeOfString:@"%@"];
    NSRange second = first.location == NSNotFound ? first : [template rangeOfString:@"%@" options:0 range:NSMakeRange(NSMaxRange(first), template.length - NSMaxRange(first))];
    return second.location == NSNotFound ? template : [template stringByReplacingCharactersInRange:second withString:name];
}

- (void)removeUpload:(SNUpload *)upload {
    if (upload == _gifItem) {
        _gif = nil;
        _gifItem = nil;
        [self updateUploads];
        [self updateState];
        [self focus];
        return;
    }
    [_source removeUpload:upload];
    // The text keeps the keyboard, as Slack's composer does after a file is removed.
    [self focus];
}

#pragma mark Text view delegate

- (void)composerTextViewDidChange:(SNComposerTextView *)textView {
    if (_contextBar.notice) _contextBar.notice = nil;
    [self updateState];
    if (_conversationID && textView.isFocused) {
        if (!textView.isEmpty) [_source userIsTypingInConversation:_conversationID threadTS:_threadTS];
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(saveDraft) object:nil];
        [self performSelector:@selector(saveDraft) withObject:nil afterDelay:0.5];
    }
    [self updateAutocomplete];
}

- (void)composerTextViewSelectionDidChange:(SNComposerTextView *)textView { [self updateAutocomplete]; }

/// The list follows the word at the caret, and closes when the caret leaves it.
- (void)updateAutocomplete {
    NSRange range;
    NSString *query = _textView.isFocused ? [self commandQueryRange:&range] ?: [_textView autocompleteQueryRange:&range] : nil;
    if (!query) return [_autocomplete close];
    // The list sits on the box as it is after this change.
    [self layoutSubtreeIfNeeded];
    [_autocomplete showQuery:query range:range aboveRect:_box.bounds inView:_box];
}

/// Slack lists commands while the whole message is "/" and a command being typed: one line,
/// none of /[~`!@#$%^&*()+=[]{}\|;:'",.<>/?], and not a known command followed by a space.
- (NSString *)commandQueryRange:(NSRangePointer)range {
    NSString *text = _textView.string;
    if (!text.length || ([text characterAtIndex:0] != '/' && [text characterAtIndex:0] != 0xff0f) || _textView.selectedRange.location == 0) return nil;
    NSCharacterSet *stops = [NSCharacterSet characterSetWithCharactersInString:@"~`!@#\uff03$%^&*()+=[]{}\\|;:'\",.<>/?\n"];
    if ([[text substringFromIndex:1] rangeOfCharacterFromSet:stops].location != NSNotFound) return nil;
    NSRange space = [text rangeOfString:@" "];
    if (space.location != NSNotFound && [_source commandNamed:[text substringToIndex:space.location]]) return nil;
    *range = NSMakeRange(0, text.length);
    return text;
}

- (void)composerTextViewFocusDidChange:(SNComposerTextView *)textView {
    [self updateState];
    if (!textView.isFocused) [_autocomplete close];
}

- (void)composerTextViewSend:(SNComposerTextView *)textView { [self send]; }

- (void)composerTextViewEditLastMessage:(SNComposerTextView *)textView {
    if (self.editLastMessage) self.editLastMessage(self);
}

- (BOOL)composerTextView:(SNComposerTextView *)textView autocompleteCommand:(SEL)command {
    return [_autocomplete performCommand:command];
}

- (BOOL)composerTextView:(SNComposerTextView *)textView pasteFilesFrom:(NSPasteboard *)pasteboard {
    NSArray<NSURL *> *files = SNComposerFilesFromPasteboard(pasteboard);
    if (!files.count) return NO;
    [self attachFiles:files];
    return YES;
}

#pragma mark Keys

// ⌘O uploads to the composer being typed in, else to the conversation's (not a thread's).
- (BOOL)performKeyEquivalent:(NSEvent *)event {
    NSEventModifierFlags flags = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    BOOL commandO = flags == NSEventModifierFlagCommand && [event.charactersIgnoringModifiers.lowercaseString isEqualToString:@"o"];
    if (!commandO || self.hidden || !_conversationID) return [super performKeyEquivalent:event];
    BOOL typingElsewhere = [self.window.firstResponder isKindOfClass:SNComposerTextView.class] && !_textView.isFocused;
    if (_textView.isFocused || (!_threadTS && !typingElsewhere)) {
        [self chooseFiles];
        return YES;
    }
    return [super performKeyEquivalent:event];
}

@end
