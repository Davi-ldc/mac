// Owns the hover card's layout and buttons.
#import "render/document.h"
#import "render/format.h"
#import "render/icon.h"
#import "render/strings.h"
#import "ui/kit/avatar.h"
#import "ui/kit/hovercard.h"
#import "ui/kit/hoverview.h"
#import "ui/kit/label.h"
#import "ui/kit/popover.h"
#import "ui/profile/profilecard.h"
#import "ui/profile/vip.h"

// Measured on design/ref/live (hover card over a message avatar), in points from the card's
// inner top-left: a 72 pt avatar at 16,16; the name in 18 pt bold with its baseline at 49 and
// the title in 15 pt at 72, both from x 100; the divider at 109.5; the local time's baseline at
// 144 behind an 18 pt clock at x 17; three 28 pt outline buttons from x 18 to 322, 8 apart, at
// 161; 16 pt under them.
static const CGFloat kAvatar = 72, kPadding = 16, kTextLeft = 100, kNameBaseline = 49, kLine = 23, kDivider = 109.5;
static const CGFloat kTimeBaseline = 144, kButtonsTop = 161, kButtonHeight = 28, kButtonsLeft = 18, kButtonsRight = 322, kButtonGap = 8;
static const SNColorToken kNameColor = SNLegacyPrimaryForeground, kTitleColor = SNColorContentSec, kTimeColor = SNLegacyPrimaryForeground;

static long LocalDay(NSDate *date, NSTimeZone *zone) { return (long)floor((date.timeIntervalSince1970 + [zone secondsFromGMTForDate:date]) / 86400); }

/// In the person's time zone; their day is compared with the one in the zone this app shows times
/// in. One's own local time is the zone chosen for this app.
NSString *SNProfileLocalTime(id<SNSource> source, SNUser *user, NSDate *date) {
    NSTimeZone *here = NSTimeZone.defaultTimeZone;
    NSTimeZone *zone = [user.userID isEqualToString:source.me.userID] ? here
                       : (user.timeZone ? [NSTimeZone timeZoneWithName:user.timeZone] : nil) ?: [NSTimeZone timeZoneForSecondsFromGMT:user.timeZoneOffset];
    long days = LocalDay(date, zone) - LocalDay(date, here);
    return SNLocalizedFormat(days > 0 ? @"profile.time.tomorrow" : days < 0 ? @"profile.time.yesterday" : @"profile.time", SNFormatTimeInZone(date, zone));
}

/// An outline button with a glyph, a label cut short with an ellipsis and an optional caret; a
/// selected one (the VIP button of a VIP) sits on ctr-sec.
@interface SNProfileCardButton : SNHoverView
@property (nonatomic, copy) NSString *title, *icon;
@property (nonatomic) BOOL caret, selected;
@end

@implementation SNProfileCardButton

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;
    self.hoverColor = 0;
    self.overlayRadius = SNRadiusLarge;
    return self;
}

- (void)stateDidChange {
    [super stateDidChange];
    self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    CGContextSetShouldSmoothFonts(NSGraphicsContext.currentContext.CGContext, false);
    NSRect bounds = self.bounds;
    NSBezierPath *outline = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(bounds, 0.5, 0.5) xRadius:SNRadiusLarge - 0.5 yRadius:SNRadiusLarge - 0.5];
    [SNColor(self.selected ? SNColorCtrSec : SNColorBasePry) setFill];
    [outline fill];
    [SNColor(self.hovered ? SNColorOtlPry : SNColorOtlSec) setStroke];
    [outline stroke];
    NSFont *font = SNFont(SNFontSizeBase, SNFontWeightBold);
    CGFloat glyph = 16, gap = 6, caret = self.caret ? 20 : 0;
    CGFloat available = NSWidth(bounds) - 2 * 12 - glyph - gap - caret;
    CGFloat textWidth = MIN(available, ceil([self.title sizeWithAttributes:@{NSFontAttributeName : font}].width));
    CGFloat x = round((NSWidth(bounds) - caret - glyph - gap - textWidth) / 2);
    x = MAX(12, x);
    SNDrawIcon(self.icon, glyph, SNColorContentPry, NSMakeRect(x, (NSHeight(bounds) - glyph) / 2, glyph, glyph));
    SNDrawText(self.title, font, SNColorContentPry, NSHeight(bounds) - 1, NSTextAlignmentLeft, 1, NSMakeRect(x + glyph + gap, 0, textWidth, NSHeight(bounds) - 1));
    // The caret has no size of its own: it takes the small button's 13 px.
    if (self.caret) SNDrawIcon(@"caret-down", 13, SNColorContentPry, NSMakeRect(NSWidth(bounds) - 24.5, (NSHeight(bounds) - 9) / 2, 9, 9));
}

@end

@interface SNProfileCardView () <SNChangeObserver, SNCursorProvider>
@end

@implementation SNProfileCardView {
    id<SNSource> _source;
    SNAvatarView *_avatar;
    NSArray<SNProfileCardButton *> *_buttons;
    SNProfileCardButton *_vip;
    CGFloat _statusHeight;
    /// HuddleStatus replaces the custom status while the person is in a huddle.
    BOOL _inHuddle;
}

- (instancetype)initWithUser:(SNUser *)user source:(id<SNSource>)source {
    BOOL inHuddle = [source isUserInHuddle:user.userID];
    BOOL status = inHuddle || user.statusText.length || user.statusEmoji.length;
    CGFloat extra = status ? kLine : 0;
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, SNHoverCardWidth, kButtonsTop + extra + kButtonHeight + kPadding)])) return nil;
    _user = user;
    _source = source;
    _statusHeight = extra;
    _inHuddle = inHuddle;

    _avatar = [[SNAvatarView alloc] initWithFrame:NSMakeRect(kPadding, kPadding, kAvatar, kAvatar)];
    _avatar.imageURL = [user avatarURLForPixels:kAvatar * 2];
    [self addSubview:_avatar];

    __weak SNProfileCardView *weakSelf = self;
    SNProfileCardButton *message = [self buttonTitled:SNLocalized(@"profile.message") icon:@"comment"];
    message.action = ^(SNHoverView *view) { [weakSelf openDirectMessage]; };
    SNProfileCardButton *huddle = [self buttonTitled:SNLocalized(@"profile.huddle") icon:@"headphones"];
    huddle.caret = YES;
    huddle.action = ^(SNHoverView *view) {
        SNProfileCardView *card = weakSelf;
        if (card) [SNProfileCard showHuddleMenuForUser:card->_user.userID source:card->_source forRect:view.bounds inView:view];
    };
    NSMutableArray *buttons = [NSMutableArray arrayWithObjects:message, huddle, nil];
    // renderVipButton: only for someone who can be a VIP.
    if (SNCanToggleVIP(source, user)) {
        _vip = [self buttonTitled:SNLocalized(@"profile.vip") icon:@"user-add"];
        _vip.action = ^(SNHoverView *view) {
            SNProfileCardView *card = weakSelf;
            if (card) SNToggleVIP(card->_source, card->_user, card.window);
        };
        [buttons addObject:_vip];
        [self updateVIP];
        [source addChangeObserver:self];
    }
    _buttons = buttons;
    // Slack's flex row: the buttons share it.
    CGFloat width = (kButtonsRight - kButtonsLeft - (buttons.count - 1) * kButtonGap) / buttons.count;
    for (NSUInteger i = 0; i < buttons.count; i++) {
        SNProfileCardButton *button = buttons[i];
        button.frame = NSMakeRect(kButtonsLeft + i * (width + kButtonGap), kButtonsTop + extra, width, kButtonHeight);
        [self addSubview:button];
    }
    return self;
}

- (SNProfileCardButton *)buttonTitled:(NSString *)title icon:(NSString *)icon {
    SNProfileCardButton *button = [[SNProfileCardButton alloc] initWithFrame:NSZeroRect];
    button.title = title;
    button.icon = icon;
    return button;
}

/// The VIP button as Slack draws it for a VIP and for someone else: selected with user-hide and
/// "Remove from VIP", or user-add and "Add to VIP".
- (void)updateVIP {
    BOOL vip = SNIsVIP(_source, _user.userID);
    _vip.selected = vip;
    _vip.icon = vip ? @"user-hide" : @"user-add";
    _vip.tooltip = SNLocalized(vip ? @"profile.vip.remove" : @"profile.vip.add");
    _vip.needsDisplay = YES;
}

- (void)sourceChanged:(SNChange *)change {
    if (change.vips) [self updateVIP];
}

- (NSArray<NSString *> *)buttonTitles {
    NSMutableArray *titles = [NSMutableArray new];
    for (SNProfileCardButton *button in _buttons) [titles addObject:button == _vip ? button.tooltip : button.title];
    return titles;
}

- (void)clickButton:(NSString *)title {
    for (SNProfileCardButton *button in _buttons)
        if ([(button == _vip ? button.tooltip : button.title) isEqualToString:title] && button.action) button.action(button);
}

- (BOOL)isFlipped { return YES; }

- (void)openDirectMessage {
    [SNHoverCard close];
    [SNProfileCard openDirectMessageWithUser:_user.userID source:_source];
}

- (NSString *)localTime { return SNProfileLocalTime(_source, _user, self.date ?: [NSDate date]); }

// The picture and the name lead to the full profile, as Slack's card links them.
- (NSRect)nameRect {
    NSFont *nameFont = SNFont(SNFontSizeSubtitle, SNFontWeightBold);
    CGFloat width = MIN(NSWidth(self.bounds) - kTextLeft - kPadding, ceil([_user.visibleName sizeWithAttributes:@{NSFontAttributeName : nameFont}].width));
    return NSMakeRect(kTextLeft, kNameBaseline - SNBaselineOffset(nameFont, kLine), width, kLine);
}

- (BOOL)linksAtPoint:(NSPoint)point { return NSPointInRect(point, _avatar.frame) || NSPointInRect(point, [self nameRect]); }

- (NSCursor *)cursorAtPoint:(NSPoint)point { return [self linksAtPoint:point] ? NSCursor.pointingHandCursor : nil; }

- (void)mouseDown:(NSEvent *)event {}

- (void)mouseUp:(NSEvent *)event {
    if ([self linksAtPoint:[self convertPoint:event.locationInWindow fromView:nil]]) [SNProfileCard openProfileOfUser:_user.userID];
}

- (void)drawRect:(NSRect)dirtyRect {
    CGContextSetShouldSmoothFonts(NSGraphicsContext.currentContext.CGContext, false);
    CGFloat width = NSWidth(self.bounds);
    NSFont *nameFont = SNFont(SNFontSizeSubtitle, SNFontWeightBold), *body = SNFont(SNFontSizeBase, SNFontWeightRegular);
    // Lines are placed by their baselines, as measured.
    CGFloat nameTop = kNameBaseline - SNBaselineOffset(nameFont, kLine);
    SNDrawText(_user.visibleName, nameFont, kNameColor, kLine, NSTextAlignmentLeft, 1, NSMakeRect(kTextLeft, nameTop, width - kTextLeft - kPadding, kLine));
    CGFloat baseline = kNameBaseline + kLine;
    if (_user.title.length) {
        SNDrawText(_user.title, body, kTitleColor, kLine, NSTextAlignmentLeft, 1,
                   NSMakeRect(kTextLeft, baseline - SNBaselineOffset(body, kLine), width - kTextLeft - kPadding, kLine));
        baseline += kLine;
    }
    if (_inHuddle) {
        // .p-huddle_status_icon--no_theme: the headphones on a 20 pt rgba(foreground_low, .13) disc.
        NSRect disc = NSMakeRect(kTextLeft, baseline - 15, 20, 20);
        [SNColor(SNLegacyHairline) setFill];
        [[NSBezierPath bezierPathWithOvalInRect:disc] fill];
        SNDrawIcon(@"headphones", 14, SNColorContentPry, disc);
        CGFloat x = NSMaxX(disc) + 6;
        SNDrawText(SNLocalized(@"profile.in.huddle"), body, kNameColor, kLine, NSTextAlignmentLeft, 1, NSMakeRect(x, baseline - SNBaselineOffset(body, kLine), width - x - kPadding, kLine));
    } else if (_statusHeight) {
        CGFloat x = kTextLeft;
        NSString *emoji = [_user.statusEmoji stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@":"]];
        // A 16 pt emoji on the text's baseline.
        if (emoji.length && SNDrawEmoji(emoji, 16, NSMakeRect(x, baseline - 13.5, 16, 16), self.imageHolder)) x += 20 + 6;
        SNDrawText(_user.statusText ?: @"", body, kNameColor, kLine, NSTextAlignmentLeft, 1, NSMakeRect(x, baseline - SNBaselineOffset(body, kLine), width - x - kPadding, kLine));
    }
    [SNColor(SNMeasuredHoverCardDivider) setFill];
    NSRectFill(NSMakeRect(0, kDivider + _statusHeight, width, 1));
    CGFloat timeBaseline = kTimeBaseline + _statusHeight;
    SNDrawIcon(@"clock", 20, kTimeColor, NSMakeRect(17, timeBaseline - 14.5, 18, 18));
    SNDrawText(self.localTime, body, kTimeColor, kLine, NSTextAlignmentLeft, 1, NSMakeRect(45, timeBaseline - SNBaselineOffset(body, kLine), width - 45 - kPadding, kLine));
}

@end

@implementation SNProfileCard

static __weak id<SNNavigator> navigator;

+ (id<SNNavigator>)navigator { return navigator; }
+ (void)setNavigator:(id<SNNavigator>)newNavigator { navigator = newNavigator; }

+ (void)openProfileOfUser:(NSString *)userID {
    [SNHoverCard close];
    id<SNNavigator> here = navigator;
    [here go:[here.location locationWithPanel:SNPanelProfile(userID)]];
}

+ (void)openDirectMessageWithUser:(NSString *)userID source:(id<SNSource>)source {
    [source openDirectMessageWithUsers:@[ userID ] completion:^(NSString *conversationID) {
        if (conversationID) [navigator openConversation:conversationID];
    }];
}

// startHuddleByMemberId: the huddle happens in the DM, opened first when needed; it is joined when
// one goes on there, else started.
+ (void)startHuddleWithUser:(NSString *)userID source:(id<SNSource>)source {
    [source openDirectMessageWithUsers:@[ userID ] completion:^(NSString *conversationID) {
        if (conversationID) [source joinHuddleInConversation:conversationID];
    }];
}

+ (void)showHuddleMenuForUser:(NSString *)userID source:(id<SNSource>)source forRect:(NSRect)rect inView:(NSView *)view {
    NSString *dm = nil;
    for (SNConversation *conversation in source.directMessages)
        if (conversation.kind == SNConversationDirect && [conversation.userID isEqualToString:userID]) dm = conversation.conversationID;
    BOOL inCall = dm && [source.call.conversationID isEqualToString:dm];
    BOOL going = dm && [source huddleInConversation:dm].isActive;
    NSString *title = SNLocalized(inCall ? @"profile.huddle.leave" : going ? @"profile.huddle.join" : @"profile.huddle.start");
    SNMenuItem *item = [SNMenuItem itemWithTitle:title action:^{
        [SNHoverCard close];
        if (inCall) [source leaveCall];
        else [SNProfileCard startHuddleWithUser:userID source:source];
    }];
    item.icon = @"headphones";
    item.iconSize = 18;
    SNMenu *menu = [[SNMenu alloc] initWithItems:@[ item ] width:305];
    [menu showForRect:rect inView:view placement:SNPlacementBelow];
}

+ (void)hoverBeganOverRect:(NSRect)rect inView:(NSView *)view userID:(NSString *)userID source:(id<SNSource>)source {
    SNUser *user = [source userWithID:userID];
    if (!user) return;
    [SNHoverCard hoverBeganOverRect:rect inView:view key:userID content:^NSView * { return [[SNProfileCardView alloc] initWithUser:user source:source]; }];
}

+ (void)hoverEnded { [SNHoverCard hoverEnded]; }

@end
