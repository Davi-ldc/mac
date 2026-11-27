// Owns the geometry and look of the Home sidebar's entries, measured on the live captures (a
// 311 pt column): rows 28 pt inset 8 pt from both edges, icons in a 16 pt slot at x 16 (page
// links, headings) or x 32 (conversations), names 8 pt after the slot.
#import "render/document.h"
#import "render/icon.h"
#import "render/strings.h"
#import "ui/huddle/huddle.h"
#import "ui/kit/avatar.h"
#import "ui/kit/button.h"
#import "ui/kit/label.h"
#import "ui/sidebar/row.h"

static const CGFloat kInset = 8, kRadius = 6, kSlot = 16, kGap = 8, kStatusEmoji = 13;
/// The row's text colours: theme content-inv-sec, unread #f8f8f8, muted content-inv-ter,
/// selected content-hgl-1.
static const SNColorToken kText = SNThemeContentInvSec, kUnread = SNThemeContentInvPry, kMuted = SNThemeContentInvTer,
                          kSelectedText = SNThemeContentHgl1;
/// The themed pill: 18 pt, 12 pt bold, 9 pt side padding, 2 pt from the row's 6 pt padding.
static const CGFloat kBadgeHeight = 18, kBadgePadding = 9, kBadgeRight = 8;
/// .p-huddle_sidebar_link_peer_count_badge: 20 pt, 36 wide at least, padding 2 6, 13 pt bold,
/// square on the left where HuddlesBadgeFakeMask (2.53 pt) hugs the last face of the facepile.
static const CGFloat kHuddleBadgeHeight = 20, kHuddleBadgeMinWidth = 36, kHuddleBadgePadding = 6, kHuddleGlyph = 16, kHuddleCountGap = 2,
                     kHuddleMaskWidth = 2.52782;
/// Hover action buttons: the DM row's close is 20 pt, the heading's are 24 pt, 0.5 pt apart,
/// the last one's centre 17 pt from the row's right edge.
static const CGFloat kCloseSize = 20, kActionSize = 24, kActionPitch = 24.5, kActionCentre = 17;
/// .p-channel_sidebar__close shows at opacity .64 on a hovered row and 1 under the pointer, in the
/// row's colour either way.
static const CGFloat kCloseRestOpacity = 0.64;
/// The heading's caret and action icons have no size of their own: they take the body's 15 px.
static const CGFloat kHeadingIcon = 15;
/// The section caret turns in 100 ms with CSS 'ease' (Core Animation's default curve); the
/// capture shows it moving for 60-80 ms.
static const CFTimeInterval kCaretTurn = 0.1;
/// The filter's no-results entry (TextFilterNoResultsRow, 130 px): a column centred in 32 pt of
/// padding, 15 pt text at line-height 1.5, 16 pt gap, then a small outline button (28 pt, 12 pt
/// padding, 56 pt at least, 13 pt bold).
static const CGFloat kEmptyPadding = 32, kEmptyLine = 22.5, kEmptyGap = 16, kSmallButton = 28, kSmallPadding = 12, kSmallMinWidth = 56;

@implementation SNSidebarItem
@end

@implementation SNSidebarRowState
@end

@implementation SNSidebarRowView {
    SNAvatarView *_avatar;
    SNIconLayer *_icon, *_caret;
    NSMutableDictionary<NSString *, SNButton *> *_actions;
    SNButton *_searchButton;
    BOOL _collapsed;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;
    self.canDrawSubviewsIntoLayer = YES;
    self.tracksMouse = NO;
    self.hoverColor = SNThemeSurfInvTer;
    // Pressing changes nothing (live), and both switch at once.
    self.pressedColor = SNThemeSurfInvTer;
    self.transitionDuration = SNLiveSidebarRowHover;
    self.overlayRadius = kRadius;
    self.overlayInsets = NSEdgeInsetsMake(0, kInset, 0, kInset);
    _actions = [NSMutableDictionary new];
    __weak SNSidebarRowView *weakSelf = self;
    self.action = ^(SNSidebarRowView *row) { [weakSelf.delegate sidebarRowClicked:row]; };
    return self;
}

- (BOOL)isFlipped { return YES; }

#pragma mark Content

- (void)showItem:(SNSidebarItem *)item state:(SNSidebarRowState *)state {
    BOOL sameSectionType = item.section.type == _item.section.type || [item.section.type isEqualToString:_item.section.type];
    BOOL kindChanged = item.kind != _item.kind || !sameSectionType;
    // A status emoji or faces held for another row's person go unless still shown.
    if (item != _item) [self.imageHolder removeAllImages];
    _item = item;
    _state = state;
    if (kindChanged) [self rebuildForKind];
    BOOL selected = state.selected;
    // Lines, gaps, hints and the no-results text are not clickable: no hover, no hand.
    BOOL inert = item.kind == SNSidebarItemDivider || item.kind == SNSidebarItemHint || item.kind == SNSidebarItemGap ||
                 item.kind == SNSidebarItemNoResults;
    self.enabled = !inert;
    // A selected row stays #7d3986 under the pointer.
    self.hoverColor = self.pressedColor = selected || inert ? 0 : SNThemeSurfInvTer;
    self.overlayRadius = item.kind == SNSidebarItemHeading ? SNRadiusBase : kRadius;
    SNButton *close = _actions[@"close"];
    if (close) {
        SNColorToken color = selected ? kSelectedText : kText;
        close.contentColor = SNColorWithAlpha(color, (color & 0xff) / 255.0 * kCloseRestOpacity);
        close.hoverContentColor = close.pressedContentColor = color;
    }
    if (_avatar) {
        _avatar.hidden = state.user == nil;
        _avatar.imageURL = [state.user avatarURLForPixels:kSlot * 2];
        _avatar.presence = state.presence;
        _avatar.doNotDisturb = state.doNotDisturb;
        _avatar.awayColor = [self textColor];
    }
    if (_searchButton) {
        _searchButton.title = state.buttonTitle;
        self.needsLayout = YES;
    }
    if (_icon) {
        _icon.iconName = state.icon;
        _icon.iconSize = state.iconSize ?: kSlot;
        _icon.color = kText;
        // A caret turning after a click already shows the new state.
        if (kindChanged || state.collapsed != _collapsed) [self setCollapsed:state.collapsed animated:NO];
    }
    [self stateDidChange];
    self.needsDisplay = YES;
}

- (void)rebuildForKind {
    [_avatar removeFromSuperview];
    _avatar = nil;
    [_icon removeFromSuperlayer];
    [_caret removeFromSuperlayer];
    _icon = _caret = nil;
    for (SNButton *button in _actions.allValues) [button removeFromSuperview];
    [_actions removeAllObjects];
    [_searchButton removeFromSuperview];
    _searchButton = nil;
    SNSidebarItemKind kind = _item.kind;
    if (kind == SNSidebarItemConversation) {
        _avatar = [[SNAvatarView alloc] initWithFrame:NSMakeRect(2 * kInset + kSlot, (SNSpace7 - kSlot) / 2, kSlot, kSlot)];
        [self addSubview:_avatar];
    } else if (kind == SNSidebarItemHeading) {
        _icon = [SNIconLayer iconNamed:nil size:kSlot color:kText];
        _caret = [SNIconLayer iconNamed:@"caret-right-filled" size:kHeadingIcon color:kText];
        for (SNIconLayer *layer in @[ _icon, _caret ]) {
            layer.frame = CGRectMake(kInset + kInset, (SNSpace7 - kSlot) / 2, kSlot, kSlot);
            [self.layer insertSublayer:layer below:self.overlayLayer];
        }
    } else if (kind == SNSidebarItemNoResults) {
        _searchButton = [SNButton outlineButtonWithTitle:@""];
        _searchButton.font = SNFont(SNFontSizeCaption, SNFontWeightBold);
        __weak SNSidebarRowView *weakSelf = self;
        _searchButton.action = ^(SNButton *sender) { [weakSelf.delegate sidebarRow:weakSelf action:@"search" fromView:sender]; };
        [self addSubview:_searchButton];
    }
    self.needsLayout = YES;
}

- (void)addAction:(NSString *)name icon:(NSString *)icon size:(CGFloat)size iconSize:(CGFloat)iconSize {
    SNButton *button = [SNButton iconButtonNamed:icon size:size iconSize:iconSize];
    button.contentColor = kText;
    button.hoverContentColor = button.pressedContentColor = SNThemeContentInvPry;
    button.hoverFillColor = 0;
    button.hoverColor = SNThemeSurfInvTer;
    button.pressedColor = SNThemeSurfInvTer;
    button.cornerRadius = SNRadiusBase;
    button.transitionDuration = 0;
    button.hidden = YES;
    __weak SNSidebarRowView *weakSelf = self;
    button.action = ^(SNButton *sender) { [weakSelf.delegate sidebarRow:weakSelf action:name fromView:sender]; };
    [button stateDidChange];
    _actions[name] = button;
    [self addSubview:button];
}

- (SNHoverView *)actionButton:(NSString *)action { return [action isEqualToString:@"search"] ? _searchButton : _actions[action]; }

- (void)performPrimaryAction {
    if (_searchButton) _searchButton.action(_searchButton);
    else if (self.enabled && self.action) self.action(self);
}

/// The no-results column's top: its 66.5 pt of text, gap and button centred in the padding.
- (CGFloat)emptyTop {
    CGFloat content = kEmptyLine + kEmptyGap + kSmallButton;
    return kEmptyPadding + (self.bounds.size.height - 2 * kEmptyPadding - content) / 2;
}

/// Hover action buttons are built only when a row is hovered, so unhovered rows keep no hidden button layers.
- (void)ensureActions {
    if (_actions.count) return;
    if (_item.kind == SNSidebarItemConversation && (_state.user || _state.memberCount)) {
        [self addAction:@"close" icon:@"close" size:kCloseSize iconSize:16];
        SNButton *close = _actions[@"close"];
        SNColorToken color = _state.selected ? kSelectedText : kText;
        close.contentColor = SNColorWithAlpha(color, (color & 0xff) / 255.0 * kCloseRestOpacity);
        close.hoverContentColor = close.pressedContentColor = color;
        [self layoutActions];
    } else if (_item.kind == SNSidebarItemHeading) {
        SNSectionType type = _item.section.type;
        if (![type isEqualToString:SNSectionStarred])
            [self addAction:@"add" icon:@"plus" size:kActionSize iconSize:kHeadingIcon];
        if ([type isEqualToString:SNSectionChannels])
            [self addAction:@"filter" icon:@"quick-switch" size:kActionSize iconSize:kHeadingIcon];
        [self addAction:@"menu" icon:@"ellipsis-vertical-filled" size:kActionSize iconSize:kHeadingIcon];
        [self layoutActions];
    }
}

- (void)layoutActions {
    CGFloat right = self.bounds.size.width - kInset, middle = SNSpace7 / 2;
    SNButton *close = _actions[@"close"];
    close.frame = NSMakeRect(right - kActionCentre - kCloseSize / 2 + 2, middle - kCloseSize / 2, kCloseSize, kCloseSize);
    NSUInteger index = 0;
    for (NSString *name in @[ @"menu", @"filter", @"add" ]) {
        SNButton *button = _actions[name];
        if (!button) continue;
        CGFloat centre = right - kActionCentre - index++ * kActionPitch;
        button.frame = NSMakeRect(centre - kActionSize / 2, middle - kActionSize / 2, kActionSize, kActionSize);
    }
}

- (void)layout {
    [super layout];
    [self layoutActions];
    if (_searchButton) {
        CGFloat width = MIN(self.bounds.size.width - 2 * kEmptyPadding, MAX(kSmallMinWidth, ceil(_searchButton.fittingContentSize.width) + 2 * kSmallPadding));
        _searchButton.frame = NSMakeRect(round((self.bounds.size.width - width) / 2), [self emptyTop] + kEmptyLine + kEmptyGap, width, kSmallButton);
    }
}

#pragma mark State

- (void)stateDidChange {
    [super stateDidChange];
    BOOL hovered = self.hovered || self.pressed;
    BOOL show = hovered && (_item.kind == SNSidebarItemHeading || _state.user || _state.memberCount);
    if (show) [self ensureActions];
    for (SNButton *button in _actions.allValues) {
        if (button.hidden == show) {
            button.hidden = !show;
            // A DM's close takes the badge's place and pushes the draft pencil and the name left.
            if (_item.kind == SNSidebarItemConversation) self.needsDisplay = YES;
        }
    }
    // The heading's icon gives way to the caret under the pointer.
    _icon.hidden = hovered && _caret;
    _caret.hidden = !hovered;
}

- (void)setCollapsed:(BOOL)collapsed animated:(BOOL)animated {
    _collapsed = collapsed;
    SNAnimate(animated ? kCaretTurn : 0, [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionDefault], ^{
        // CSS: rotate(90deg) open, rotate(0) translateY(1px) closed.
        self->_caret.affineTransform = collapsed ? CGAffineTransformMakeTranslation(0, 1) : CGAffineTransformMakeRotation(M_PI / 2);
    });
}

#pragma mark Drawing

- (SNColorToken)textColor {
    if (_state.selected) return kSelectedText;
    if (_state.muted) return kMuted;
    return _state.unread ? kUnread : kText;
}

- (void)drawRect:(NSRect)dirty {
    SNSidebarItemKind kind = _item.kind;
    NSRect bounds = self.bounds;
    CGFloat width = bounds.size.width;
    if (kind == SNSidebarItemGap) return;
    if (kind == SNSidebarItemDivider) {
        [SNColor(SNLegacyHairline) setFill];
        NSRectFillUsingOperation(NSMakeRect(kInset + SNSpace1, bounds.size.height / 2, width - 2 * (kInset + SNSpace1), 1), NSCompositingOperationSourceOver);
        return;
    }
    if (kind == SNSidebarItemNoResults) {
        SNDrawText(_state.title, SNFont(SNFontSizeBase, SNFontWeightRegular), kText, kEmptyLine, NSTextAlignmentCenter, 1,
                   NSMakeRect(kEmptyPadding, [self emptyTop], width - 2 * kEmptyPadding, kEmptyLine));
        return;
    }
    if (kind == SNSidebarItemHint) {
        SNDrawText(_state.title, SNFont(SNFontSizeCaption, SNFontWeightRegular), kMuted, SNSpace7, NSTextAlignmentLeft, 1,
                   NSMakeRect(2 * kInset + kSlot, 0, width - 3 * kInset - kSlot, SNSpace7));
        return;
    }
    if (_state.selected) {
        [SNColor(SNThemeBaseHgl1) setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(kInset, 0, width - 2 * kInset, bounds.size.height) xRadius:kRadius yRadius:kRadius] fill];
    }
    SNColorToken color = [self textColor];
    BOOL conversation = kind == SNSidebarItemConversation || kind == SNSidebarItemAdd;
    CGFloat slotX = conversation ? 2 * kInset + kSlot : 2 * kInset, textX = slotX + kSlot + kGap;
    NSRect slot = NSMakeRect(slotX, (SNSpace7 - kSlot) / 2, kSlot, kSlot);
    if (kind == SNSidebarItemAdd) {
        [self drawAddIconInRect:slot color:color];
    } else if (kind != SNSidebarItemHeading && _state.icon) {
        SNDrawIcon(_state.icon, _state.iconSize ?: kSlot, color, slot);
    } else if (_state.memberCount) {
        [self drawMemberCount:_state.memberCount color:color inRect:slot];
    }

    CGFloat right = width - kInset - kInset;
    BOOL hoverActions = (self.hovered || self.pressed) && (_state.user || _state.memberCount);
    if (_state.mentions && !hoverActions) right = [self drawBadge:_state.mentions right:width - kInset - kBadgeRight] - SNSpace1;
    else if (hoverActions) right = width - kInset - kActionCentre - kCloseSize / 2 - SNSpace1;
    if (_state.huddleCount && !hoverActions) right = [self drawHuddleRight:_state.mentions ? right : width - kInset - kBadgeRight] - SNSpace1;
    if (_state.draft && !_state.selected) {
        SNDrawIcon(@"edit", kSlot, color, NSMakeRect(right - kSlot, slot.origin.y, kSlot, kSlot));
        right -= kSlot + SNSpace1;
    }

    BOOL bold = _state.unread && !_state.muted;
    if (kind == SNSidebarItemHeading) bold = _state.collapsed && _state.unread;
    NSFont *font = SNFont(SNFontSizeBase, bold ? SNFontWeightBlack : SNFontWeightRegular);
    NSString *emoji = [_state.user.statusEmoji stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@":"]];
    if (!emoji.length) emoji = nil;
    // HuddleStatus takes the custom status's place while the person is in a huddle.
    if (_state.userInHuddle) emoji = @"";
    CGFloat titleWidth = MAX(0, right - textX);
    if (emoji) {
        CGFloat used = MIN(titleWidth - kSlot - SNSpace1, ceil([_state.title sizeWithAttributes:@{NSFontAttributeName : font}].width));
        titleWidth = MAX(0, used);
    }
    SNDrawText(_state.title, font, color, SNSpace7, NSTextAlignmentLeft, 1, NSMakeRect(textX, 0, titleWidth, SNSpace7));
    NSRect status = NSMakeRect(textX + titleWidth + SNSpace1, slot.origin.y, kSlot, kSlot);
    if (_state.userInHuddle) SNDrawIcon(@"headphones", kSlot, color, status);
    else if (emoji) [self drawEmoji:emoji inRect:status];
}

/// BaseChannelSuffixHuddleIcon ending at `right`: two faces, the fake mask and the badge with the
/// headphones and how many are in the huddle; returns its left edge. A selected row's badge is
/// base-pry (surf-inv for the user's own huddle).
- (CGFloat)drawHuddleRight:(CGFloat)right {
    BOOL selected = _state.selected, mine = _state.myHuddle;
    SNColorToken fill = !selected ? SNThemeBaseInvHgl1 : mine ? SNColorSurfInv : SNColorBasePry;
    SNColorToken text = !selected ? SNColorContentInvPry : mine ? SNThemeContentHgl1 : SNColorContentPry;
    NSString *count = @(_state.huddleCount).stringValue;
    NSFont *font = SNFont(SNFontSizeCaption, SNFontWeightBold);
    CGFloat textWidth = ceil([count sizeWithAttributes:@{NSFontAttributeName : font}].width);
    CGFloat width = MAX(kHuddleBadgeMinWidth, kHuddleBadgePadding + kHuddleGlyph + kHuddleCountGap + textWidth + kHuddleBadgePadding);
    NSRect badge = NSMakeRect(right - width, (SNSpace7 - kHuddleBadgeHeight) / 2, width, kHuddleBadgeHeight);
    [SNColor(fill) setFill];
    NSBezierPath *pill = [NSBezierPath bezierPath];
    CGFloat r = SNRadiusBase, minX = NSMinX(badge), maxX = NSMaxX(badge), minY = NSMinY(badge), maxY = NSMaxY(badge);
    [pill moveToPoint:NSMakePoint(minX, minY)];
    [pill appendBezierPathWithArcFromPoint:NSMakePoint(maxX, minY) toPoint:NSMakePoint(maxX, maxY) radius:r];
    [pill appendBezierPathWithArcFromPoint:NSMakePoint(maxX, maxY) toPoint:NSMakePoint(minX, maxY) radius:r];
    [pill lineToPoint:NSMakePoint(minX, maxY)];
    [pill closePath];
    [pill fill];
    // The mask's path in its 2.53 x 20 box (y down): flat on the right, hollowed on the left where
    // the face before it is rounded.
    CGFloat x = minX - kHuddleMaskWidth, y = minY;
    NSBezierPath *mask = [NSBezierPath bezierPath];
    [mask moveToPoint:NSMakePoint(x, y + 20)];
    [mask lineToPoint:NSMakePoint(x + kHuddleMaskWidth, y + 20)];
    [mask lineToPoint:NSMakePoint(x + kHuddleMaskWidth, y)];
    [mask lineToPoint:NSMakePoint(x, y)];
    [mask curveToPoint:NSMakePoint(x + 1.52779, y + 4) controlPoint1:NSMakePoint(x + 0.95008, y + 1.06151) controlPoint2:NSMakePoint(x + 1.52779, y + 2.46329)];
    [mask lineToPoint:NSMakePoint(x + 1.52779, y + 16)];
    [mask curveToPoint:NSMakePoint(x, y + 20) controlPoint1:NSMakePoint(x + 1.52779, y + 17.5367) controlPoint2:NSMakePoint(x + 0.95008, y + 18.9385)];
    [mask closePath];
    [mask fill];
    SNDrawIcon(@"headphones", kHuddleGlyph, text, NSMakeRect(minX + kHuddleBadgePadding, NSMidY(badge) - kHuddleGlyph / 2, kHuddleGlyph, kHuddleGlyph));
    CGFloat textX = minX + kHuddleBadgePadding + kHuddleGlyph + kHuddleCountGap;
    SNDrawText(count, font, text, kHuddleBadgeHeight, NSTextAlignmentLeft, 1, NSMakeRect(textX, minY, maxX - textX, kHuddleBadgeHeight));
    CGFloat faces = SNFacepileWidth(_state.huddleFaces.count, SNHuddleFacepileAvatar);
    SNDrawFacepile(_state.huddleFaces ?: @[], SNHuddleFacepileAvatar, NSMakePoint(x - faces, minY), self.imageHolder);
    return x - faces;
}

/// "Adicionar canais": a 1 pt plus, 8.5 pt across, on a radius-4 square of the sidebar's
/// surface (measured live).
- (void)drawAddIconInRect:(NSRect)rect color:(SNColorToken)color {
    [SNColor(SNThemeSurfInvSec) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:rect xRadius:SNRadiusBase yRadius:SNRadiusBase] fill];
    [SNColor(color) setFill];
    CGFloat arm = 8.5, midX = NSMidX(rect), midY = NSMidY(rect);
    NSRectFillUsingOperation(NSMakeRect(midX - arm / 2, midY - 0.5, arm, 1), NSCompositingOperationSourceOver);
    NSRectFillUsingOperation(NSMakeRect(midX - 0.5, midY - arm / 2, 1, arm), NSCompositingOperationSourceOver);
}

/// A group DM's icon: the number of other members in a rounded square, as Slack draws it when
/// the avatars are off.
- (void)drawMemberCount:(NSInteger)count color:(SNColorToken)color inRect:(NSRect)rect {
    NSRect box = NSInsetRect(rect, 0.5, 0.5);
    [SNColor(color) setStroke];
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:box xRadius:SNRadiusBase yRadius:SNRadiusBase];
    path.lineWidth = 1;
    [path stroke];
    SNDrawText([NSString stringWithFormat:@"%ld", (long)count], SNFont(SNFontSizeMicro - 1, SNFontWeightBold), color, kSlot,
               NSTextAlignmentCenter, 1, rect);
}

/// Draws the pill ending at `right`; returns its left edge.
- (CGFloat)drawBadge:(NSInteger)count right:(CGFloat)right {
    NSString *text = count > 99 ? @"99+" : [NSString stringWithFormat:@"%ld", (long)count];
    NSFont *font = SNFont(SNFontSizeMicro, SNFontWeightBold);
    CGFloat textWidth = ceil([text sizeWithAttributes:@{NSFontAttributeName : font}].width);
    // Two digits and more use the narrower padding of c-badge's max form.
    CGFloat padding = text.length > 1 ? 7 : kBadgePadding;
    CGFloat width = MAX(kBadgeHeight, textWidth + 2 * padding);
    NSRect pill = NSMakeRect(right - width, (SNSpace7 - kBadgeHeight) / 2, width, kBadgeHeight);
    [SNColor(SNThemeBaseImp) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:pill xRadius:kBadgeHeight / 2 yRadius:kBadgeHeight / 2] fill];
    SNDrawText(text, font, SNThemeContentImp, kBadgeHeight, NSTextAlignmentCenter, 1, pill);
    return pill.origin.x;
}

/// The DM person's status emoji after the name, drawn again once a custom picture loads.
- (void)drawEmoji:(NSString *)name inRect:(NSRect)rect {
    SNDrawEmoji(name, kStatusEmoji, rect, self.imageHolder);
}

@end
