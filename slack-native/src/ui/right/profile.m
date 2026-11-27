// Owns the profile flexpane: its header, the one scrolling column and what each part does. The
// layout follows the web client's RimetoMemberProfileFlexpane and client-boot-styles (values in
// points, as CSS pixels):
// - .p-r_member_profile__avatar_content: at most 288 wide with 16/16/0 padding, so the square
//   photo (image_512, radius 8, #35373b under it) is at most 256;
// - each .p-r_member_profile_section: 16 padding, a 1 pt foreground_low_solid rule above it (none
//   for the bio), 24 under the last; headers 15 pt black with 16 under them;
// - the bio: the name 22 pt black on 1.25 lines, 4 pt up into the padding, with the 20 pt VIP badge
//   4 pt after it; the title 18 pt on 1.5 lines; then, 12 pt down, rows 8 pt apart (presence,
//   custom status, huddle, local time), whose 20 pt icons sit 1 pt above the 22.5 pt line; then, 12
//   pt down, the buttons;
// - the buttons (MemberProfileButtons): 36 tall, 8 apart, 2 pt in from the section's padding;
//   message and huddle share what is left (at least 48 and 68), VIP takes its content's width
//   (shrinking to 32), More is 36 square;
// - contact rows: a 36 pt ctr-sec box (radius 4) with the 20 pt icon, 8 pt before the 13 pt bold
//   content-sec label and the 15 pt link; rows 8 pt apart; the copy button shows on hover;
// - Recent DMs: 20 pt pictures, 8 pt before the 15 pt name on a 20 pt line, 6 pt padding, rows 12
//   apart; fields: 13 pt bold label over the 15 pt value, 8 pt apart.
#import "model/json.h"
#import "render/document.h"
#import "render/format.h"
#import "render/icon.h"
#import "render/images.h"
#import "render/strings.h"
#import "ui/kit/avatar.h"
#import "ui/kit/button.h"
#import "ui/kit/hoverview.h"
#import "ui/kit/label.h"
#import "ui/kit/popover.h"
#import "ui/profile/profilecard.h"
#import "ui/profile/toast.h"
#import "ui/profile/vip.h"
#import "ui/right/profile.h"
#import "ui/right/thread.h"

static const CGFloat kPhotoMax = 288, kPad = 16, kNameLine = 27.5, kTitleLine = 27, kLine = 22.5, kGroupGap = 12;
static const CGFloat kRow = 23.5, kRowGap = 8, kRowIcon = 20, kIconGap = 8, kBadge = 20;
static const CGFloat kButton = 36, kButtonGap = 8, kButtonsInset = 2, kMessageMin = 48, kHuddleMin = 68, kVIPMin = 32;
static const CGFloat kHeaderLine = 22.5, kHeaderGap = 16, kPeopleHeaderGap = 8, kLastPadding = 24;
static const CGFloat kIconBox = 36, kLabelLine = 16.25, kFieldGap = 8, kCopy = 28;
static const CGFloat kDMAvatar = 20, kDMLine = 20, kDMPadding = 6, kDMGap = 12;
static const SNColorToken kText = SNLegacyPrimaryForeground, kRule = SNLegacyForegroundLowSolid, kLink = SNColorContentHgl1;

static NSFont *Body(void) { return SNFont(SNFontSizeBase, SNFontWeightRegular); }

#pragma mark - Parts

/// The square photo: image_512 at its size, radius 8, #35373b until it loads.
@interface SNProfilePhoto : NSView
@property (nonatomic, nullable) NSURL *url;
@end

@implementation SNProfilePhoto

- (BOOL)isFlipped { return YES; }

- (void)setUrl:(NSURL *)url {
    if (url == _url || [url isEqual:_url]) return;
    _url = url;
    [self.imageHolder removeAllImages];
    self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    NSBezierPath *shape = [NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:SNRadiusLarge yRadius:SNRadiusLarge];
    [SNColor(kRule) setFill];
    [shape fill];
    CGImageRef image = _url ? [self.imageHolder imageWithURL:_url pixels:512] : NULL;
    if (!image) return;
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    CGContextSaveGState(context);
    [shape addClip];
    // Flipped view: draw the image upright.
    CGContextTranslateCTM(context, 0, NSHeight(self.bounds));
    CGContextScaleCTM(context, 1, -1);
    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
    CGContextDrawImage(context, NSRectToCGRect(self.bounds), image);
    CGContextRestoreGState(context);
}

@end

/// A SquareButton of MemberProfileButtons: the outline, a 20 pt glyph and the label (cut short),
/// a chevron for the huddle's menu, alone for More; selected (a VIP's VIP button) on ctr-sec.
@interface SNProfileButton : SNHoverView
@property (nonatomic, copy) NSString *title, *icon;
@property (nonatomic) BOOL chevron, selected;
@property (nonatomic, readonly) CGFloat contentWidth;
@end

@implementation SNProfileButton

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;
    self.hoverColor = 0;
    self.overlayRadius = SNRadiusLarge;
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)stateDidChange {
    [super stateDidChange];
    self.needsDisplay = YES;
}

- (NSFont *)font { return SNFont(SNFontSizeBase, SNFontWeightBold); }

- (CGFloat)labelWidth { return self.title.length ? ceil([self.title sizeWithAttributes:@{NSFontAttributeName : self.font}].width) : 0; }

/// padding 0 12, the glyph, the label 4 pt after it, the chevron's 4 pt and 16 pt glyph.
- (CGFloat)contentWidth { return 2 * 12 + kRowIcon + (self.title.length ? 4 + self.labelWidth : 0) + (self.chevron ? 4 + 16 : 0) + 2; }

- (void)drawRect:(NSRect)dirtyRect {
    CGContextSetShouldSmoothFonts(NSGraphicsContext.currentContext.CGContext, false);
    NSRect bounds = self.bounds;
    NSBezierPath *outline = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(bounds, 0.5, 0.5) xRadius:SNRadiusLarge - 0.5 yRadius:SNRadiusLarge - 0.5];
    [SNColor(self.selected ? SNColorCtrSec : SNColorBasePry) setFill];
    [outline fill];
    [SNColor(self.hovered ? SNColorOtlPry : SNColorOtlSec) setStroke];
    [outline stroke];
    CGFloat height = NSHeight(bounds), chevron = self.chevron ? 4 + 16 : 0;
    CGFloat inner = NSWidth(bounds) - 2 * 12 - chevron;
    CGFloat label = self.title.length ? MIN(self.labelWidth, MAX(0, inner - kRowIcon - 4)) : 0;
    CGFloat body = kRowIcon + (label ? 4 + label : 0);
    // The body centres in its room, except the huddle's, which starts at the padding.
    CGFloat x = self.chevron ? 12 : round((NSWidth(bounds) - body) / 2);
    SNDrawIcon(self.icon, kRowIcon, SNColorContentPry, NSMakeRect(x, (height - kRowIcon) / 2, kRowIcon, kRowIcon));
    if (label) SNDrawText(self.title, self.font, SNColorContentPry, height - 1, NSTextAlignmentLeft, 1, NSMakeRect(x + kRowIcon + 4, 0, label, height - 1));
    if (self.chevron) SNDrawIcon(@"caret-down", 16, SNColorContentPry, NSMakeRect(NSWidth(bounds) - 12 - 16, (height - 16) / 2 + 1, 16, 16));
}

@end

/// A clickable line: a recent DM (picture and name, the name underlined under the pointer) or the
/// "See all conversations with" link.
@interface SNProfileLinkRow : SNHoverView
@property (nonatomic, copy) NSString *text;
@property (nonatomic) BOOL bold, link;
@property (nonatomic, nullable) SNAvatarView *avatar;
@end

@implementation SNProfileLinkRow

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.hoverColor = self.pressedColor = 0;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)stateDidChange {
    [super stateDidChange];
    self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    CGContextSetShouldSmoothFonts(NSGraphicsContext.currentContext.CGContext, false);
    CGFloat x = self.avatar ? kDMAvatar + 8 : 0, width = NSWidth(self.bounds) - x;
    NSFont *font = SNFont(SNFontSizeBase, self.bold ? SNFontWeightBold : SNFontWeightRegular);
    SNColorToken color = self.link ? kLink : kText;
    CGFloat top = (NSHeight(self.bounds) - kDMLine) / 2;
    SNDrawText(self.text, font, color, kDMLine, NSTextAlignmentLeft, 1, NSMakeRect(x, top, width, kDMLine));
    if (!self.hovered) return;
    CGFloat textWidth = MIN(width, ceil([self.text sizeWithAttributes:@{NSFontAttributeName : font}].width));
    [SNColor(color) setFill];
    NSRectFill(NSMakeRect(x, top + SNBaselineOffset(font, kDMLine) + 2, textWidth, 1));
}

@end

/// A field: label over value (RimetoMemberProfileField); a contact field has the icon box before it
/// and its copy button (hover) after it; a link value opens.
@interface SNProfileField : SNHoverView
@property (nonatomic, copy) NSString *label, *value;
@property (nonatomic, copy, nullable) NSString *icon;
@property (nonatomic, nullable) NSURL *url;
@property (nonatomic, nullable) SNButton *copier;
- (CGFloat)heightForWidth:(CGFloat)width;
@end

@implementation SNProfileField

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.hoverColor = self.pressedColor = 0;
    self.cursor = NSCursor.arrowCursor;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)stateDidChange {
    [super stateDidChange];
    self.copier.hidden = !self.hovered;
}

- (CGFloat)textX { return self.icon ? kIconBox + 8 : 0; }
- (CGFloat)textWidthFor:(CGFloat)width { return MAX(1, width - self.textX - (self.copier ? kCopy + 8 : 0)); }

- (CGFloat)heightForWidth:(CGFloat)width {
    CGFloat text = kLabelLine + SNLineCount(self.value, Body(), [self textWidthFor:width], 0) * kLine;
    return self.icon ? MAX(kIconBox, text) : text;
}

- (NSRect)valueRect {
    CGFloat width = [self textWidthFor:NSWidth(self.bounds)];
    CGFloat text = kLabelLine + SNLineCount(self.value, Body(), width, 0) * kLine;
    CGFloat top = (NSHeight(self.bounds) - text) / 2;
    return NSMakeRect(self.textX, top + kLabelLine, width, text - kLabelLine);
}

- (void)layout {
    [super layout];
    self.copier.frame = NSMakeRect(NSWidth(self.bounds) - kCopy, (NSHeight(self.bounds) - kCopy) / 2, kCopy, kCopy);
}

- (void)drawRect:(NSRect)dirtyRect {
    CGContextSetShouldSmoothFonts(NSGraphicsContext.currentContext.CGContext, false);
    if (self.icon) {
        NSRect box = NSMakeRect(0, (NSHeight(self.bounds) - kIconBox) / 2, kIconBox, kIconBox);
        [SNColor(SNColorCtrSec) setFill];
        [[NSBezierPath bezierPathWithRoundedRect:box xRadius:SNRadiusBase yRadius:SNRadiusBase] fill];
        SNDrawIcon(self.icon, kRowIcon, kText, NSInsetRect(box, (kIconBox - kRowIcon) / 2, (kIconBox - kRowIcon) / 2));
    }
    NSRect value = [self valueRect];
    SNDrawText(self.label, SNFont(SNFontSizeCaption, SNFontWeightBold), SNColorContentSec, kLabelLine, NSTextAlignmentLeft, 1,
               NSMakeRect(value.origin.x, NSMinY(value) - kLabelLine, NSWidth(value), kLabelLine));
    SNDrawText(self.value, Body(), self.url ? kLink : kText, kLine, NSTextAlignmentLeft, 0, value);
}

- (NSCursor *)cursorAtPoint:(NSPoint)point { return self.url && NSPointInRect(point, [self valueRect]) ? NSCursor.pointingHandCursor : nil; }

- (void)mouseUp:(NSEvent *)event {
    if (self.url && NSPointInRect([self convertPoint:event.locationInWindow fromView:nil], [self valueRect])) [NSWorkspace.sharedWorkspace openURL:self.url];
}

@end

/// The column's document, laid out by the panel.
@interface SNProfileDocument : NSView
@end

/// A section's header, with the space Slack leaves under it.
@interface SNProfileSectionHeader : SNLabel
@property (nonatomic) CGFloat gap;
@end

@implementation SNProfileSectionHeader
@end

@implementation SNProfileDocument
- (BOOL)isFlipped { return YES; }
@end

/// Draws the bio's text (name, badge, title, pronouns and the rows) given by the panel.
@interface SNProfileBio : NSView
@property (nonatomic, weak) SNProfilePanel *panel;
@end

#pragma mark - The panel

@interface SNProfilePanel () <SNChangeObserver>
- (void)drawBioIn:(NSRect)bounds;
@end

@implementation SNProfileBio
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)dirtyRect { [self.panel drawBioIn:self.bounds]; }
@end

@implementation SNProfilePanel {
    id<SNSource> _source;
    NSView *_header, *_headerRule;
    NSScrollView *_scroll;
    SNProfileDocument *_document;
    SNProfilePhoto *_photo;
    SNProfileBio *_bio;
    SNProfileButton *_message, *_huddle, *_vip, *_more;
    /// The sections' parts in order: section headers (SNLabel), rules (NSView), fields and rows.
    NSMutableArray<NSView *> *_sectionViews;
    /// The people the panel names (the person, DM partners, people fields) and the DMs it lists:
    /// their changes make it again.
    NSMutableSet<NSString *> *_shownUserIDs, *_shownConversationIDs;
    NSTimer *_clock;
}

- (instancetype)initWithUserID:(NSString *)userID source:(id<SNSource>)source close:(void (^)(void))close {
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, 400, 800)])) return nil;
    _userID = [userID copy];
    _source = source;
    _header = SNMakePanelHeader(SNLocalized(@"profile.panel.title"), SNFontSizeSubtitle, close);
    // .p-flexpane--ia_details_popover: a 1 pt otl-ter line under the header once the column scrolls.
    _headerRule = [[NSView alloc] initWithFrame:NSZeroRect];
    _headerRule.wantsLayer = YES;
    _headerRule.layer.backgroundColor = SNCGColor(SNColorOtlTer);
    _headerRule.hidden = YES;
    _scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    _scroll.drawsBackground = NO;
    _scroll.hasVerticalScroller = YES;
    _scroll.scrollerStyle = NSScrollerStyleOverlay;
    _scroll.autohidesScrollers = YES;
    _scroll.contentView.postsBoundsChangedNotifications = YES;
    _document = [[SNProfileDocument alloc] initWithFrame:NSZeroRect];
    _scroll.documentView = _document;
    _photo = [[SNProfilePhoto alloc] initWithFrame:NSZeroRect];
    _bio = [[SNProfileBio alloc] initWithFrame:NSZeroRect];
    _bio.panel = self;
    _bio.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;
    __weak SNProfilePanel *weakSelf = self;
    _message = [self button:SNLocalized(@"profile.message") icon:@"comment"];
    _message.action = ^(SNHoverView *view) {
        SNProfilePanel *panel = weakSelf;
        if (panel) [SNProfileCard openDirectMessageWithUser:panel->_userID source:panel->_source];
    };
    _huddle = [self button:SNLocalized(@"profile.huddle") icon:@"headphones"];
    _huddle.chevron = YES;
    _huddle.action = ^(SNHoverView *view) {
        SNProfilePanel *panel = weakSelf;
        if (panel) [SNProfileCard showHuddleMenuForUser:panel->_userID source:panel->_source forRect:view.bounds inView:view];
    };
    _vip = [self button:SNLocalized(@"profile.vip") icon:@"user-add"];
    _vip.action = ^(SNHoverView *view) {
        SNProfilePanel *panel = weakSelf;
        SNUser *user = [panel->_source userWithID:panel->_userID];
        if (user) SNToggleVIP(panel->_source, user, panel.window);
    };
    _more = [self button:@"" icon:@"ellipsis-vertical-filled"];
    _more.action = ^(SNHoverView *view) { [weakSelf showMoreMenu]; };
    for (NSView *view in @[ _photo, _bio, _message, _huddle, _vip, _more ]) [_document addSubview:view];
    _sectionViews = [NSMutableArray new];
    for (NSView *view in @[ _scroll, _header, _headerRule ]) [self addSubview:view];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(scrolled:) name:NSViewBoundsDidChangeNotification object:_scroll.contentView];
    [source addChangeObserver:self];
    [source loadProfileOfUser:userID];
    [self reload];
    return self;
}

- (void)dealloc {
    [_clock invalidate];
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (BOOL)isFlipped { return YES; }
- (void)focusForTyping {}

- (SNProfileButton *)button:(NSString *)title icon:(NSString *)icon {
    SNProfileButton *button = [[SNProfileButton alloc] initWithFrame:NSZeroRect];
    button.title = title;
    button.icon = icon;
    return button;
}

- (SNUser *)user { return [_source userWithID:_userID]; }

// The local time refreshes on each minute boundary, as useProfileMemberLocalTime.
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [_clock invalidate];
    _clock = nil;
    if (!self.window || self.date) return;
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    __weak SNProfileBio *bio = _bio;
    _clock = [[NSTimer alloc] initWithFireDate:[NSDate dateWithTimeIntervalSince1970:(floor(now / 60) + 1) * 60] interval:60 repeats:YES
                                         block:^(NSTimer *timer) { bio.needsDisplay = YES; }];
    [NSRunLoop.mainRunLoop addTimer:_clock forMode:NSRunLoopCommonModes];
}

- (void)setDate:(NSDate *)date {
    _date = [date copy];
    _bio.needsDisplay = YES;
}

- (void)scrolled:(NSNotification *)notification { _headerRule.hidden = NSMinY(_scroll.contentView.bounds) <= 0; }

- (void)sourceChanged:(SNChange *)change {
    // Joining or leaving a huddle comes as a change to the person too.
    if ([change.users intersectsSet:_shownUserIDs] || [change.profiles containsObject:_userID] ||
        [change.counts intersectsSet:_shownConversationIDs])
        return [self reload];
    if ([change.presence containsObject:_userID]) _bio.needsDisplay = YES;
    // Being a VIP adds a badge to the name, which may wrap it.
    if (change.vips && SNIsVIP(_source, _userID) != _vip.selected) {
        [self updateVIP:self.user];
        _bio.needsDisplay = YES;
        self.needsLayout = YES;
    }
}

#pragma mark Content

/// "Active", "Away", with ", notifications snoozed" while Do Not Disturb is on.
- (NSString *)presenceText:(SNUser *)user {
    BOOL active = [_source presenceOfUser:user.userID] == SNPresenceActive;
    if ([_source doNotDisturbOfUser:user.userID]) return SNLocalized(active ? @"profile.presence.active.snoozed" : @"profile.presence.away.snoozed");
    return SNLocalized(active ? @"profile.presence.active" : @"profile.presence.away");
}

- (NSString *)presenceIcon:(SNUser *)user {
    BOOL active = [_source presenceOfUser:user.userID] == SNPresenceActive;
    return [_source doNotDisturbOfUser:user.userID] ? (active ? @"status-member-dnd-filled" : @"status-member-dnd") : active ? @"status-member-filled" : @"status-member";
}

/// The HEADER section's element `key`'s text.
- (NSString *)headerElement:(NSString *)key {
    for (NSDictionary *section in [_source profileSectionsOfUser:_userID] ?: @[])
        if ([SNJSONString(section, @"type") isEqualToString:@"HEADER"])
            for (NSDictionary *element in SNJSONArray(section, @"profileElements"))
                if ([element isKindOfClass:NSDictionary.class] && [SNJSONString(element, @"elementKey") isEqualToString:key] && !SNJSONBool(element, @"isMissing"))
                    return SNJSONString(element, @"text");
    return nil;
}

/// "{pronouns} · {name pronunciation}".
- (NSString *)pronounsLine:(SNUser *)user {
    NSMutableArray *parts = [NSMutableArray new];
    NSString *pronouns = SNJSONString(SNJSONObject(user.json, @"profile"), @"pronouns");
    if (pronouns.length) [parts addObject:pronouns];
    NSString *pronunciation = [self headerElement:@"Name Pronunciation"];
    if (pronunciation.length) [parts addObject:pronunciation];
    return [parts componentsJoinedByString:@" · "];
}

- (BOOL)hasStatus:(SNUser *)user { return user.statusText.length || user.statusEmoji.length; }

- (CGFloat)nameWidthFor:(CGFloat)width user:(SNUser *)user {
    return width - 2 * kPad - (SNIsVIP(_source, user.userID) ? 4 + kBadge : 0);
}

/// The bio's height for the panel's width, from the name to the last row.
- (CGFloat)bioHeightFor:(CGFloat)width user:(SNUser *)user {
    CGFloat inner = width - 2 * kPad;
    CGFloat height = SNLineCount(user.visibleName, SNFont(SNFontSizeTitle, SNFontWeightBlack), [self nameWidthFor:width user:user], 0) * kNameLine;
    if (user.title.length) height += SNLineCount(user.title, SNFont(SNFontSizeSubtitle, SNFontWeightRegular), inner, 0) * kTitleLine;
    NSString *pronouns = [self pronounsLine:user];
    if (pronouns.length) height += SNLineCount(pronouns, Body(), inner, 0) * kLine;
    height += kGroupGap;
    // Presence, the custom status row (empty without a status, its margin still there), the
    // huddle's while in one, and the local time.
    height += kRow + kRowGap + ([self hasStatus:user] ? kRow : 0) + kRowGap;
    if ([_source isUserInHuddle:user.userID]) height += kRow + kRowGap;
    return height + kRow + kRowGap;
}

- (void)drawBioIn:(NSRect)bounds {
    SNUser *user = self.user;
    if (!user) return;
    CGContextSetShouldSmoothFonts(NSGraphicsContext.currentContext.CGContext, false);
    CGFloat width = NSWidth(bounds) + 2 * kPad, inner = NSWidth(bounds), y = 0;
    NSFont *nameFont = SNFont(SNFontSizeTitle, SNFontWeightBlack);
    CGFloat nameWidth = [self nameWidthFor:width user:user];
    NSUInteger lines = SNLineCount(user.visibleName, nameFont, nameWidth, 0);
    SNDrawText(user.visibleName, nameFont, kText, kNameLine, NSTextAlignmentLeft, 0, NSMakeRect(0, y, nameWidth, lines * kNameLine));
    if (SNIsVIP(_source, user.userID)) {
        // The badge follows the name's last line, centred on it.
        CGFloat last = lines == 1 ? MIN(nameWidth, ceil([user.visibleName sizeWithAttributes:@{NSFontAttributeName : nameFont}].width)) : nameWidth;
        SNDrawIcon(@"vip-filled", kBadge, SNColorContentPry, NSMakeRect(last + 4, y + (lines - 1) * kNameLine + (kNameLine - kBadge) / 2, kBadge, kBadge));
    }
    y += lines * kNameLine;
    if (user.title.length) {
        NSFont *font = SNFont(SNFontSizeSubtitle, SNFontWeightRegular);
        CGFloat height = SNLineCount(user.title, font, inner, 0) * kTitleLine;
        SNDrawText(user.title, font, kText, kTitleLine, NSTextAlignmentLeft, 0, NSMakeRect(0, y, inner, height));
        y += height;
    }
    NSString *pronouns = [self pronounsLine:user];
    if (pronouns.length) {
        CGFloat height = SNLineCount(pronouns, Body(), inner, 0) * kLine;
        SNDrawText(pronouns, Body(), kText, kLine, NSTextAlignmentLeft, 0, NSMakeRect(0, y, inner, height));
        y += height;
    }
    y += kGroupGap;
    SNColorToken presence = [_source presenceOfUser:user.userID] == SNPresenceActive ? SNColorContentHgl2 : SNLegacyForegroundMaxSolid;
    [self drawRowAt:y icon:[self presenceIcon:user] color:presence text:[self presenceText:user] width:inner];
    y += kRow + kRowGap;
    if ([self hasStatus:user]) {
        CGFloat x = 0;
        NSString *emoji = [user.statusEmoji stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@":"]];
        __weak SNProfileBio *bio = _bio;
        if (emoji.length && SNDrawEmoji(emoji, kRowIcon, NSMakeRect(0, y, kRowIcon, kRowIcon), bio.imageHolder)) x = kRowIcon + kIconGap;
        SNDrawText(user.statusText ?: @"", Body(), kText, kLine, NSTextAlignmentLeft, 1, NSMakeRect(x, y + kRow - kLine, inner - x, kLine));
        y += kRow;
    }
    y += kRowGap;
    if ([_source isUserInHuddle:user.userID]) {
        [self drawRowAt:y icon:@"headphones" color:kText text:SNLocalized(@"profile.in.huddle") width:inner];
        y += kRow + kRowGap;
    }
    [self drawRowAt:y icon:@"clock" color:kText text:SNProfileLocalTime(_source, user, self.date ?: [NSDate date]) width:inner];
}

/// A row: the 20 pt icon at its top, the text on the 22.5 pt line under its first point.
- (void)drawRowAt:(CGFloat)y icon:(NSString *)icon color:(SNColorToken)color text:(NSString *)text width:(CGFloat)width {
    SNDrawIcon(icon, kRowIcon, color, NSMakeRect(0, y, kRowIcon, kRowIcon));
    CGFloat x = kRowIcon + kIconGap;
    SNDrawText(text, Body(), kText, kLine, NSTextAlignmentLeft, 1, NSMakeRect(x, y + kRow - kLine, width - x, kLine));
}

- (void)updateVIP:(SNUser *)user {
    BOOL vip = SNIsVIP(_source, _userID);
    _vip.hidden = !user || !SNCanToggleVIP(_source, user);
    _vip.selected = vip;
    _vip.icon = vip ? @"user-hide" : @"user-add";
    _vip.tooltip = SNLocalized(vip ? @"profile.vip.remove" : @"profile.vip.add");
    _vip.needsDisplay = YES;
}

/// Makes the sections' parts again from what the source holds.
- (void)reload {
    SNUser *user = self.user;
    _photo.url = [user avatarURLForPixels:512];
    [self updateVIP:user];
    for (NSView *view in _sectionViews) [view removeFromSuperview];
    [_sectionViews removeAllObjects];
    _shownUserIDs = [NSMutableSet setWithObject:_userID];
    _shownConversationIDs = [NSMutableSet new];
    for (NSDictionary *section in [_source profileSectionsOfUser:_userID] ?: @[]) {
        NSString *type = SNJSONString(section, @"type");
        if ([type isEqualToString:@"HEADER"]) continue;
        if ([type isEqualToString:@"CONTACT"]) {
            [self addContactSection:section];
            [self addRecentDMs];
        } else [self addFieldsSection:section people:[type isEqualToString:@"PEOPLE"]];
    }
    _bio.needsDisplay = YES;
    self.needsLayout = YES;
}

- (void)addSectionHeader:(NSString *)title gap:(CGFloat)gap {
    NSView *rule = [[NSView alloc] initWithFrame:NSZeroRect];
    rule.wantsLayer = YES;
    rule.layer.backgroundColor = SNCGColor(kRule);
    SNProfileSectionHeader *label = [SNProfileSectionHeader labelWithText:title font:SNFont(SNFontSizeBase, SNFontWeightBlack) color:kText];
    label.lineHeight = kHeaderLine;
    label.maximumLines = 0;
    label.gap = gap;
    for (NSView *view in @[ rule, label ]) {
        [_sectionViews addObject:view];
        [_document addSubview:view];
    }
}

- (void)addPart:(NSView *)view {
    [_sectionViews addObject:view];
    [_document addSubview:view];
}

static NSString *ElementLabel(NSDictionary *element) { return SNJSONString(element, @"label") ?: @""; }

/// ContactInformationSection: email and phone elements only, each a mailto: or tel: link.
- (void)addContactSection:(NSDictionary *)section {
    NSMutableArray *fields = [NSMutableArray new];
    for (NSDictionary *element in SNJSONArray(section, @"profileElements")) {
        if (![element isKindOfClass:NSDictionary.class] || SNJSONBool(element, @"isMissing")) continue;
        NSString *key = SNJSONString(element, @"elementKey") ?: @"", *text = SNJSONString(element, @"text");
        BOOL phone = [@[ @"phone", @"primaryPhone", @"mobilePhone", @"Alternate Phone" ] containsObject:key];
        if (!text.length || (!phone && ![@[ @"email", @"secondEmail" ] containsObject:key])) continue;
        SNProfileField *field = [[SNProfileField alloc] initWithFrame:NSZeroRect];
        field.label = ElementLabel(element);
        field.value = text;
        field.icon = phone ? @"call" : @"email";
        NSString *scheme = phone ? @"tel:" : @"mailto:";
        NSString *target = phone ? [[text componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet] componentsJoinedByString:@""] : text;
        field.url = [NSURL URLWithString:[scheme stringByAppendingString:[target stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet] ?: @""]];
        field.copier = [self copierFor:text label:field.label];
        [field addSubview:field.copier];
        [fields addObject:field];
    }
    if (!fields.count) return;
    [self addSectionHeader:SNJSONString(section, @"label") ?: @"" gap:kHeaderGap];
    for (SNProfileField *field in fields) [self addPart:field];
}

/// A small outline icon button with "Copy", then "Copied!" for 2 s.
- (SNButton *)copierFor:(NSString *)text label:(NSString *)label {
    SNButton *button = [SNButton iconButtonNamed:@"copy" size:kCopy iconSize:16];
    button.borderColor = SNColorOtlSec;
    button.tooltip = SNLocalized(@"profile.copy");
    button.hidden = YES;
    button.action = ^(SNButton *sender) {
        [NSPasteboard.generalPasteboard clearContents];
        [NSPasteboard.generalPasteboard setString:text forType:NSPasteboardTypeString];
        sender.tooltip = SNLocalized(@"profile.copied");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ sender.tooltip = SNLocalized(@"profile.copy"); });
    };
    return button;
}

/// RecentDmsSection: the DMs and group DMs shared with the person that this client knows, after the
/// contact information; hidden for oneself and without any.
- (void)addRecentDMs {
    BOOL more = NO;
    NSArray<NSString *> *ids = [_source recentConversationsWithUser:_userID more:&more];
    if ([_userID isEqualToString:_source.me.userID] || [_userID isEqualToString:@"USLACKBOT"]) return;
    NSMutableArray<SNProfileLinkRow *> *rows = [NSMutableArray new];
    for (NSString *conversationID in ids ?: @[]) {
        SNConversation *conversation = [_source conversationWithID:conversationID];
        if (!conversation.isDirect) continue;
        [_shownConversationIDs addObject:conversationID];
        SNProfileLinkRow *row = [[SNProfileLinkRow alloc] initWithFrame:NSZeroRect];
        row.text = [self nameOfConversation:conversation];
        row.bold = conversation.hasUnreads;
        SNUser *picture = [_source userWithID:conversation.userID ?: _userID];
        if (conversation.userID) [_shownUserIDs addObject:conversation.userID];
        row.avatar = [[SNAvatarView alloc] initWithFrame:NSMakeRect(0, kDMPadding, kDMAvatar, kDMAvatar)];
        row.avatar.imageURL = [picture avatarURLForPixels:kDMAvatar * 2];
        [row addSubview:row.avatar];
        __weak id<SNNavigator> navigator = SNProfileCard.navigator;
        row.action = ^(SNHoverView *view) { [navigator openConversation:conversationID]; };
        [rows addObject:row];
    }
    if (!rows.count) return;
    [self addSectionHeader:SNLocalized(@"profile.recent") gap:kHeaderGap];
    for (SNProfileLinkRow *row in rows) [self addPart:row];
    if (!more) return;
    SNUser *user = self.user;
    SNProfileLinkRow *all = [[SNProfileLinkRow alloc] initWithFrame:NSZeroRect];
    all.text = [SNLocalized(@"profile.recent.all") stringByAppendingString:user.visibleName ?: @""];
    all.link = YES;
    __weak id<SNNavigator> navigator = SNProfileCard.navigator;
    NSString *handle = user.handle;
    all.action = ^(SNHoverView *view) { [navigator openSearchWithQuery:[@"with:@" stringByAppendingString:handle ?: @""]]; };
    [self addPart:all];
}

/// A DM by the person's name, a group DM by its other people's names.
- (NSString *)nameOfConversation:(SNConversation *)conversation {
    if (conversation.kind == SNConversationDirect) return [_source userWithID:conversation.userID].visibleName ?: conversation.userID ?: @"";
    NSMutableArray *names = [NSMutableArray new];
    NSString *me = _source.me.handle;
    for (NSString *handle in [[conversation.name stringByReplacingOccurrencesOfString:@"mpdm-" withString:@""] componentsSeparatedByString:@"--"]) {
        NSString *bare = [handle hasSuffix:@"-1"] ? [handle substringToIndex:handle.length - 2] : handle;
        if ([bare isEqualToString:me]) continue;
        [names addObject:[_source userWithHandle:bare].visibleName ?: bare];
    }
    return [names componentsJoinedByString:@", "];
}

/// What an element shows: its text, link, date, tags or people.
- (NSString *)valueOf:(NSDictionary *)element url:(NSURL **)url {
    NSString *kind = SNJSONString(element, @"__typename") ?: @"";
    if ([kind isEqualToString:@"ProfileLinkElement"]) {
        NSString *uri = SNJSONString(element, @"uri");
        *url = uri ? [NSURL URLWithString:uri] : nil;
        return SNJSONString(element, @"displayText") ?: uri;
    }
    if ([kind isEqualToString:@"ProfileDateElement"]) {
        NSString *date = SNJSONString(element, @"date");
        NSDateFormatter *parser = [NSDateFormatter new];
        parser.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        parser.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
        parser.dateFormat = @"yyyy-MM-dd";
        NSDate *parsed = date.length >= 10 ? [parser dateFromString:[date substringToIndex:10]] : nil;
        if (!parsed) return date;
        NSDateFormatter *formatter = [NSDateFormatter new];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:SNLanguage()];
        formatter.timeZone = parser.timeZone;
        formatter.dateStyle = NSDateFormatterLongStyle;
        return [formatter stringFromDate:parsed];
    }
    if ([kind isEqualToString:@"ProfileTagsElement"]) {
        NSMutableArray *tags = [NSMutableArray new];
        for (id tag in SNJSONArray(element, @"tags")) {
            NSString *text = [tag isKindOfClass:NSString.class] ? tag : SNJSONString(tag, @"label") ?: SNJSONString(tag, @"text");
            if (text.length) [tags addObject:text];
        }
        return [tags componentsJoinedByString:@", "];
    }
    if ([kind isEqualToString:@"ProfilePersonElement"]) {
        NSMutableArray *names = [NSMutableArray new];
        for (id person in SNJSONArray(element, @"persons")) {
            NSString *userID = [person isKindOfClass:NSString.class] ? person : SNJSONString(person, @"id") ?: SNJSONString(person, @"userId");
            SNUser *user = userID ? [_source userWithID:userID] : nil;
            if (!userID) continue;
            [_shownUserIDs addObject:userID];
            [names addObject:user.visibleName ?: userID];
        }
        return [names componentsJoinedByString:@", "];
    }
    NSString *text = SNJSONString(element, @"text");
    if (text.length || ![kind isEqualToString:@"ProfileLongTextElement"]) return text;
    // A long text without its plain text: the words of its rich_text blocks.
    NSMutableString *words = [NSMutableString new];
    __block void (^visit)(id) = nil;
    void (^walk)(id) = ^(id node) {
        if ([node isKindOfClass:NSArray.class]) for (id child in node) visit(child);
        else if ([node isKindOfClass:NSDictionary.class]) {
            NSString *piece = SNJSONString(node, @"text");
            if (piece && [SNJSONString(node, @"type") isEqualToString:@"text"]) [words appendString:piece];
            visit(node[@"elements"]);
        }
    };
    visit = walk;
    walk(element[@"blocks"]);
    visit = nil;
    return words;
}

/// The generic list of a section's elements (About me, the workspace's own sections, people).
- (void)addFieldsSection:(NSDictionary *)section people:(BOOL)people {
    NSMutableArray *fields = [NSMutableArray new];
    for (NSDictionary *element in SNJSONArray(section, @"profileElements")) {
        if (![element isKindOfClass:NSDictionary.class] || SNJSONBool(element, @"isMissing")) continue;
        NSURL *url = nil;
        NSString *value = [self valueOf:element url:&url];
        if (!value.length) continue;
        SNProfileField *field = [[SNProfileField alloc] initWithFrame:NSZeroRect];
        field.label = ElementLabel(element);
        field.value = value;
        field.url = url;
        [fields addObject:field];
    }
    if (!fields.count) return;
    [self addSectionHeader:SNJSONString(section, @"label") ?: @"" gap:people ? kPeopleHeaderGap : kHeaderGap];
    for (SNProfileField *field in fields) [self addPart:field];
}

#pragma mark Layout

/// The buttons' widths as Slack's flex row gives them: message and huddle share what VIP and More
/// leave, at least their minimums; VIP shrinks down to 32 when that is not enough.
- (void)layoutButtonsAt:(CGFloat)y width:(CGFloat)width {
    CGFloat left = kPad + kButtonsInset, available = width - 2 * left;
    BOOL vip = !_vip.hidden;
    CGFloat gaps = (vip ? 3 : 2) * kButtonGap, more = kButton;
    CGFloat vipWidth = vip ? _vip.contentWidth : 0;
    CGFloat rest = available - gaps - more - vipWidth;
    CGFloat message, huddle;
    if (rest >= kMessageMin + kHuddleMin) {
        message = huddle = rest / 2;
        if (huddle < kHuddleMin) {
            huddle = kHuddleMin;
            message = rest - huddle;
        }
    } else {
        message = kMessageMin;
        huddle = kHuddleMin;
        if (vip) vipWidth = MAX(kVIPMin, available - gaps - more - message - huddle);
    }
    CGFloat x = left;
    for (NSArray *part in @[ @[ _message, @(message) ], @[ _huddle, @(huddle) ], @[ _vip, @(vipWidth) ], @[ _more, @(more) ] ]) {
        SNProfileButton *button = part[0];
        if (button.hidden) continue;
        button.frame = NSMakeRect(round(x), y, round([part[1] doubleValue]), kButton);
        x += [part[1] doubleValue] + kButtonGap;
    }
}

- (void)layout {
    [super layout];
    CGFloat width = NSWidth(self.bounds), height = NSHeight(self.bounds);
    _header.frame = NSMakeRect(0, 0, width, SNThreadHeaderHeight);
    _headerRule.frame = NSMakeRect(0, SNThreadHeaderHeight, width, 1);
    _scroll.frame = NSMakeRect(0, SNThreadHeaderHeight, width, MAX(0, height - SNThreadHeaderHeight));
    SNUser *user = self.user;
    CGFloat container = MIN(width, kPhotoMax), side = MAX(0, container - 2 * kPad);
    _photo.frame = NSMakeRect(round((width - container) / 2 + kPad), kPad, side, side);
    CGFloat y = kPad + side + kPad - 4;
    CGFloat bio = user ? [self bioHeightFor:width user:user] : 0;
    _bio.frame = NSMakeRect(kPad, y, width - 2 * kPad, bio);
    y += bio + kGroupGap;
    for (NSView *button in @[ _message, _huddle, _vip, _more ]) button.hidden = !user || (button == _vip && !SNCanToggleVIP(_source, user));
    if (user) {
        [self layoutButtonsAt:y width:width];
        y += kButton;
    }
    y += kPad;
    CGFloat inner = width - 2 * kPad;
    NSView *previous = nil;
    for (NSView *view in _sectionViews) {
        if ([view isKindOfClass:SNProfileSectionHeader.class]) {
            // A section: its rule, padding, header and the header's gap.
            SNProfileSectionHeader *label = (SNProfileSectionHeader *)view;
            CGFloat headerHeight = [label heightForWidth:inner];
            label.frame = NSMakeRect(kPad, y + kPad, inner, headerHeight);
            y += kPad + headerHeight + label.gap;
            previous = label;
            continue;
        }
        if (![view isKindOfClass:SNHoverView.class]) {
            // The rule closes the section before it: its bottom padding, then the 1 pt line.
            if (previous) y += kPad;
            view.frame = NSMakeRect(0, y, width, 1);
            y += 1;
            previous = nil;
            continue;
        }
        BOOL first = [previous isKindOfClass:SNProfileSectionHeader.class];
        if ([view isKindOfClass:SNProfileField.class]) {
            if (!first) y += kFieldGap * 2;
            CGFloat fieldHeight = [(SNProfileField *)view heightForWidth:inner];
            view.frame = NSMakeRect(kPad, y, inner, fieldHeight);
            y += fieldHeight;
        } else {
            if (!first) y += kDMGap;
            CGFloat rowHeight = kDMLine + 2 * kDMPadding;
            view.frame = NSMakeRect(kPad, y, inner, rowHeight);
            y += rowHeight;
        }
        previous = view;
    }
    y += previous ? kLastPadding : 0;
    _document.frame = NSMakeRect(0, 0, width, MAX(y, NSHeight(_scroll.contentView.bounds)));
}

#pragma mark More

/// RimetoMemberProfileOverflowMenu, with what this client can do: copy the display name, the member
/// ID and the link to the profile.
- (void)showMoreMenu {
    SNUser *user = self.user;
    if (!user) return;
    NSString *display = user.displayName.length ? user.displayName : user.realName;
    void (^copy)(NSString *) = ^(NSString *text) {
        [NSPasteboard.generalPasteboard clearContents];
        [NSPasteboard.generalPasteboard setString:text forType:NSPasteboardTypeString];
    };
    NSString *link = [NSString stringWithFormat:@"https://%@.slack.com/team/%@", _source.workspace.domain, user.userID];
    NSArray *items = @[
        [SNMenuItem itemWithTitle:SNLocalizedFormat(@"profile.more.copyName", display) action:^{ copy(display); }], [SNMenuItem separator],
        [SNMenuItem itemWithTitle:SNLocalized(@"profile.more.copyID") action:^{ copy(user.userID); }],
        [SNMenuItem itemWithTitle:SNLocalized(@"profile.more.copyLink") action:^{ copy([link stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet] ?: link); }],
    ];
    SNMenu *menu = [[SNMenu alloc] initWithItems:items width:300];
    // position "bottom-right": under the button, its right edge at the button's.
    NSRect anchor = NSMakeRect(NSMaxX(_more.bounds) - menu.frame.size.width, 0, menu.frame.size.width, NSHeight(_more.bounds));
    [menu showForRect:anchor inView:_more placement:SNPlacementBelow];
}

@end
