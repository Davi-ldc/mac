// Owns the header's huddle control: its three states, their widths, the slide-in fill and the
// options menu.
#import "render/strings.h"
#import "ui/huddle/headercontrol.h"
#import "ui/huddle/huddle.h"
#import "ui/kit/popover.h"
#import "ui/present/names.h"

typedef NS_ENUM(NSInteger, SNHuddleHeaderState) {
    SNHuddleHeaderIdle,
    /// --active: a huddle goes on and the user is not in it.
    SNHuddleHeaderActive,
    /// --in_huddle.
    SNHuddleHeaderInCall,
};

/// The polish buttons are 28 tall; the options button is 20 wide; the start button pads 4 each
/// side, 2 on the left before the faces (--has_facepile), which keep 8 after them, the count 4
/// after the glyph in 15 px.
static const CGFloat kHeight = 28, kOptionsWidth = 20, kPadding = 4, kFacepilePadding = 2, kFacepileGap = 8, kCountGap = 4, kGlyph = 20;
static const NSUInteger kFaces = 3;

@interface SNHuddleHeaderButton : SNButton
@property (nonatomic) SNHuddleHeaderState huddleState;
@property (nonatomic, readonly) SNFacepileView *facepile;
@end

@implementation SNHuddleHeaderButton

- (instancetype)initWithSource:(id<SNSource>)source {
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, kHeight, kHeight)])) return nil;
    _facepile = [[SNFacepileView alloc] initWithSource:source];
    _facepile.hidden = YES;
    [self addSubview:_facepile];
    self.icon.iconName = @"headphones";
    self.icon.iconSize = kGlyph;
    self.cornerRadius = SNRadiusLarge;
    self.hoverColor = 0;
    self.spacing = kCountGap;
    self.font = SNFont(SNFontSizeBase, SNFontWeightRegular);
    self.transitionDuration = SNLiveHeaderIconButtonHover;
    return self;
}

- (CGFloat)preferredWidth {
    if (self.huddleState == SNHuddleHeaderInCall || !self.title) return kPadding + kGlyph + kPadding;
    CGFloat faces = self.facepile.hidden ? 0 : SNFacepileWidth(self.facepile.userIDs.count, SNHuddleFacepileAvatar) + kFacepileGap;
    CGFloat left = self.facepile.hidden ? kPadding : kFacepilePadding;
    return ceil(left + faces + self.fittingContentSize.width + kPadding);
}

- (void)layout {
    [super layout];
    if (!self.title) return;
    // Laid out from the left like the web client's flex row, not centred as other buttons.
    CGFloat x = self.facepile.hidden ? kPadding : kFacepilePadding, middle = NSHeight(self.bounds) / 2;
    if (!self.facepile.hidden) {
        CGFloat width = SNFacepileWidth(self.facepile.userIDs.count, SNHuddleFacepileAvatar);
        self.facepile.frame = NSMakeRect(x, middle - SNHuddleFacepileAvatar / 2, width, SNHuddleFacepileAvatar);
        x += width + kFacepileGap;
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.icon.position = CGPointMake(x + kGlyph / 2, middle);
    [CATransaction commit];
    // SNButton keeps its label to itself: it is the subview that is not the facepile.
    NSView *label = nil;
    for (NSView *view in self.subviews)
        if (view != self.facepile) label = view;
    NSRect frame = label.frame;
    frame.origin.x = x + kGlyph + kCountGap;
    label.frame = frame;
}

- (void)stateDidChange {
    [super stateDidChange];
    // The leave button's glyph is the close glyph under the pointer.
    self.icon.iconName = self.huddleState == SNHuddleHeaderInCall && self.hovered ? @"close" : @"headphones";
}

@end

@interface SNHuddleHeaderControl () <SNChangeObserver>
@end

@implementation SNHuddleHeaderControl {
    id<SNSource> _source;
    CALayer *_fill, *_slider;
    SNHuddleHeaderState _state;
}

- (instancetype)initWithSource:(id<SNSource>)source {
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, kHeight + kOptionsWidth, kHeight)])) return nil;
    _source = source;
    self.wantsLayer = YES;
    _fill = [SNLayer layer];
    _fill.cornerRadius = SNRadiusLarge;
    _slider = [SNLayer layer];
    _slider.cornerRadius = SNRadiusLarge;
    _slider.backgroundColor = SNCGColor(SNPaletteJade50);
    _slider.anchorPoint = CGPointMake(0, 0.5);
    _slider.affineTransform = CGAffineTransformMakeScale(0, 1);
    [self.layer addSublayer:_fill];
    [self.layer addSublayer:_slider];
    SNHuddleHeaderButton *button = [[SNHuddleHeaderButton alloc] initWithSource:source];
    _button = button;
    _button.tooltipPlacement = SNPlacementBelow;
    _options = [SNButton iconButtonNamed:@"caret-down" size:kHeight iconSize:kGlyph];
    _options.hoverColor = 0;
    _options.transitionDuration = SNLiveHeaderIconButtonHover;
    _options.tooltip = SNLocalized(@"channel.header.huddle.options");
    _options.tooltipPlacement = SNPlacementBelow;
    [self addSubview:_button];
    [self addSubview:_options];
    __weak SNHuddleHeaderControl *weakSelf = self;
    _button.action = ^(SNButton *sender) { [weakSelf buttonClicked]; };
    _options.action = ^(SNButton *sender) { [weakSelf showOptions]; };
    [source addChangeObserver:self];
    [self update:NO];
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)setConversationID:(NSString *)conversationID {
    if (conversationID == _conversationID || [conversationID isEqualToString:_conversationID]) return;
    _conversationID = [conversationID copy];
    [self update:NO];
}

- (CGFloat)preferredWidth { return ((SNHuddleHeaderButton *)_button).preferredWidth + kOptionsWidth; }

- (void)sourceChanged:(SNChange *)change {
    SNHuddle *huddle = SNActiveHuddle(_source, _conversationID);
    BOOL faces = huddle && [change.users intersectsSet:[NSSet setWithArray:SNFacepileUserIDs(huddle, kFaces)]];
    if (faces) ((SNHuddleHeaderButton *)_button).facepile.needsDisplay = YES;
    if ([change.huddles containsObject:_conversationID ?: @""] || change.call) [self update:YES];
}

/// Slack's toggleHuddle: leaves the huddle the user is in here, else joins the one going on, else
/// starts one.
- (void)buttonClicked {
    if (!_conversationID) return;
    if (_state == SNHuddleHeaderInCall) [_source leaveCall];
    else if (_source.canJoinHuddles) [_source joinHuddleInConversation:_conversationID];
}

/// HuddleButtonMenu: "Start Huddle" or "Join Huddle" unless the user is in it; its other items
/// (copy the huddle's link, schedule, other calling apps) need what this client does not have, so
/// in a huddle there is nothing to offer.
- (void)showOptions {
    if (!_conversationID || _state == SNHuddleHeaderInCall || !_source.canJoinHuddles) return;
    __weak SNHuddleHeaderControl *weakSelf = self;
    SNMenuItem *item = [SNMenuItem itemWithTitle:SNLocalized(_state == SNHuddleHeaderActive ? @"huddle.menu.join" : @"huddle.menu.start")
                                          action:^{ [weakSelf buttonClicked]; }];
    item.icon = @"headphones";
    item.iconSize = 18;
    SNMenu *menu = [[SNMenu alloc] initWithItems:@[ item ] width:0];
    // position "bottom", offsetX 5, offsetY -5: centred under the caret, the popover's 4 pt gap included.
    NSRect caret = _options.frame;
    CGFloat width = menu.frame.size.width;
    [menu showForRect:NSMakeRect(NSMidX(caret) - width / 2 + 5, NSMaxY(caret) - 5 - 4, width, 0) inView:self placement:SNPlacementBelow];
}

/// getStartHuddleTip's "Start huddle in #channel" / "Start huddle with <people>", and the join
/// tip's first line.
- (NSString *)tipStarting:(BOOL)starting {
    SNConversation *conversation = [_source conversationWithID:_conversationID];
    if (!conversation) return SNLocalized(starting ? @"channel.header.huddle" : @"huddle.join.huddle");
    NSString *name = SNConversationTitle(conversation, _source);
    BOOL people = conversation.kind == SNConversationDirect || conversation.kind == SNConversationGroupDirect;
    if (conversation.kind == SNConversationChannel) name = [@"#" stringByAppendingString:name];
    return SNLocalizedFormat(starting ? (people ? @"huddle.start.with" : @"huddle.start.in") : (people ? @"huddle.join.with" : @"huddle.join.in"), name);
}

- (void)update:(BOOL)animated {
    SNHuddle *huddle = SNActiveHuddle(_source, _conversationID);
    SNHuddleHeaderState state = SNInCallInConversation(_source, _conversationID ?: @"") ? SNHuddleHeaderInCall : huddle ? SNHuddleHeaderActive : SNHuddleHeaderIdle;
    SNHuddleHeaderButton *button = (SNHuddleHeaderButton *)_button;
    CGFloat oldWidth = self.preferredWidth;
    SNHuddleHeaderState old = _state;
    _state = state;
    button.huddleState = state;
    NSUInteger people = huddle.participantIDs.count;
    button.title = state == SNHuddleHeaderActive && people ? @(people).stringValue : nil;
    button.facepile.userIDs = SNFacepileUserIDs(huddle, kFaces);
    button.facepile.hidden = state != SNHuddleHeaderActive || !people;
    // Idle keeps the header's measured icon-button look; the jade states colour both buttons.
    SNColorToken content = state == SNHuddleHeaderActive ? SNPaletteJade100 : SNColorContentInvPry;
    SNColorToken hoverFill = state == SNHuddleHeaderActive ? SNPaletteJade10 : SNColorSurfInv;
    for (SNButton *each in @[ button, _options ]) {
        each.contentColor = state == SNHuddleHeaderIdle ? SNColorContentSec : content;
        each.hoverContentColor = each.pressedContentColor = state == SNHuddleHeaderIdle ? SNColorContentPry : content;
        each.hoverFillColor = state == SNHuddleHeaderIdle ? SNMeasuredHeaderHuddleHover : hoverFill;
    }
    button.tooltip = state == SNHuddleHeaderInCall ? SNLocalized(@"huddle.leave.tip") : [self tipStarting:state == SNHuddleHeaderIdle];
    // Without libwebrtc the control still shows the huddle; it only cannot join it.
    button.enabled = state != SNHuddleHeaderActive || _source.canJoinHuddles;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _fill.backgroundColor = state == SNHuddleHeaderActive ? SNCGColor(SNPaletteJade5) : NULL;
    [CATransaction commit];
    if ((state == SNHuddleHeaderInCall) != (old == SNHuddleHeaderInCall) || !animated) {
        SNAnimate(animated ? SNDuration200 : 0, [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionDefault], ^{
            self->_slider.affineTransform = CGAffineTransformMakeScale(state == SNHuddleHeaderInCall ? 1 : 0, 1);
        });
    }
    [button stateDidChange];
    [_options stateDidChange];
    self.needsLayout = YES;
    if (self.preferredWidth != oldWidth && self.widthChanged) self.widthChanged();
}

- (void)layout {
    [super layout];
    CGFloat width = ((SNHuddleHeaderButton *)_button).preferredWidth, total = width + kOptionsWidth;
    _button.frame = NSMakeRect(0, 0, width, kHeight);
    _options.frame = NSMakeRect(width, 0, kOptionsWidth, kHeight);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _fill.frame = CGRectMake(0, 0, total, kHeight);
    _slider.bounds = CGRectMake(0, 0, total, kHeight);
    _slider.position = CGPointMake(0, kHeight / 2);
    [CATransaction commit];
}

@end
