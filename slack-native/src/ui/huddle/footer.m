// Owns the sidebar's invitation banner and call footer, their layout and their buttons.
#import "render/document.h"
#import "render/strings.h"
#import "ui/huddle/footer.h"
#import "ui/huddle/huddle.h"
#import "ui/kit/avatar.h"
#import "ui/kit/label.h"
#import "ui/present/names.h"

/// Both sit 8 pt in from the sidebar's sides; the footer ends 8 pt above its bottom
/// (.p-huddle_sidebar_footer__container), the invitation keeps 8 pt above and below (.p-huddle_invite).
static const CGFloat kMargin = 8;
/// .p-huddle_invite__content: radius 12, padding 12; a 20 pt avatar 8 pt before 15 pt text; the
/// buttons 12 pt under it, 26 pt tall, 6 pt apart, 13 pt bold.
static const CGFloat kInvitePadding = 12, kInviteAvatar = 20, kInviteAvatarGap = 8, kInviteButtonsTop = 12, kInviteButton = 26, kInviteButtonGap = 6;
/// The footer: a 1 pt rgba(foreground_mid, .3) border, radius 12; the activity row 12 pt in (a
/// 28 pt icon with a 24 pt face, then the name in 15 pt semibold over 13 pt), the controls 12 pt
/// under it and 12 pt above the bottom: a 36 pt round microphone and the 64 pt Leave.
static const CGFloat kFooterPadding = 12, kIcon = 28, kFace = 24, kIconGap = 8, kControlsGap = 12, kControl = 36, kLeaveMinWidth = 64;
static const SNColorToken kFooterBorder = 0xe8e8e84d;
static const SNTextStyle kInviteText = {SNFontSizeBase, SNFontWeightRegular, 22, SNThemeContentInvPry};

static SNButton *InviteButton(NSString *title, BOOL accept) {
    SNButton *button = [SNButton outlineButtonWithTitle:title];
    button.font = SNFont(SNFontSizeCaption, SNFontWeightBold);
    button.fillColor = button.hoverFillColor = accept ? SNThemeBasePry : SNThemeSurfInvPry;
    button.contentColor = button.hoverContentColor = button.pressedContentColor = accept ? SNThemeContentTer : SNThemeContentInvSec;
    button.borderColor = accept ? 0 : kFooterBorder;
    button.hoverColor = SNThemeBasePryHover;
    button.pressedColor = SNThemeBasePryPressed;
    return button;
}

#pragma mark Invitation

@interface SNHuddleInviteView : NSView
@property (nonatomic, readonly) SNHuddleInvite *invite;
@property (nonatomic, readonly, nullable) SNButton *join;
@property (nonatomic, readonly) SNButton *decline;
- (void)refresh;
@end

@implementation SNHuddleInviteView {
    id<SNSource> _source;
    SNAvatarView *_avatar;
    SNRenderDocument *_text;
    SNRenderLayout *_laid;
}

- (instancetype)initWithInvite:(SNHuddleInvite *)invite source:(id<SNSource>)source {
    if (!(self = [super initWithFrame:NSZeroRect])) return nil;
    _invite = invite;
    _source = source;
    _avatar = [[SNAvatarView alloc] initWithFrame:NSMakeRect(0, 0, kInviteAvatar, kInviteAvatar)];
    _avatar.imageURL = [[source userWithID:invite.senderID] avatarURLForPixels:kInviteAvatar * 2];
    [self addSubview:_avatar];
    _text = [SNRenderDocument documentWithBlocks:@[ [self inviteText].paragraph ]];
    __weak SNHuddleInviteView *weakSelf = self;
    if (source.canJoinHuddles) {
        _join = InviteButton(SNLocalized(@"huddle.join"), YES);
        _join.action = ^(SNButton *button) {
            SNHuddleInviteView *view = weakSelf;
            [view->_source dismissHuddleInvite:view.invite];
            [view->_source joinHuddleInConversation:view.invite.conversationID];
        };
        [self addSubview:_join];
    }
    _decline = InviteButton(SNLocalized(@"huddle.decline"), NO);
    _decline.action = ^(SNButton *button) {
        SNHuddleInviteView *view = weakSelf;
        [view->_source dismissHuddleInvite:view.invite];
    };
    [self addSubview:_decline];
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)refresh {
    _avatar.imageURL = [[_source userWithID:_invite.senderID] avatarURLForPixels:kInviteAvatar * 2];
    _text = [SNRenderDocument documentWithBlocks:@[ [self inviteText].paragraph ]];
    _laid = nil;
    self.needsLayout = YES;
    self.needsDisplay = YES;
}

/// useHuddleInviteProps' text: "Join huddle with {senderName}" in a DM, "with {allMemberNames}"
/// in a group DM, "{senderName} is inviting you to a huddle in {channelName}" in a channel; the
/// names in bold.
- (SNInlineText *)inviteText {
    SNInlineText *text = [[SNInlineText alloc] initWithStyle:kInviteText];
    SNConversation *conversation = [_source conversationWithID:_invite.conversationID];
    NSString *sender = [_source userWithID:_invite.senderID].visibleName ?: @"";
    BOOL direct = conversation.kind == SNConversationDirect || conversation.kind == SNConversationGroupDirect;
    NSString *bold = direct ? (conversation.kind == SNConversationDirect ? sender : SNConversationTitle(conversation, _source)) : sender;
    NSString *format = SNLocalized(direct ? @"huddle.invite.with" : @"huddle.invite.channel");
    NSString *channel = conversation ? [@"#" stringByAppendingString:SNConversationTitle(conversation, _source)] : @"";
    NSArray<NSString *> *parts = [format componentsSeparatedByString:@"%@"];
    NSArray<NSString *> *fills = direct ? @[ bold ] : @[ bold, channel ];
    for (NSUInteger i = 0; i < parts.count; i++) {
        if (parts[i].length) [text appendText:parts[i] style:0];
        if (i < fills.count && i + 1 < parts.count) [text appendText:fills[i] style:SNInlineBold];
    }
    return text;
}

- (CGFloat)heightForWidth:(CGFloat)width {
    CGFloat textWidth = MAX(40, width - 2 * kInvitePadding - kInviteAvatar - kInviteAvatarGap);
    _laid = [_text layoutForWidth:textWidth];
    NSUInteger buttons = _join ? 2 : 1;
    return kMargin + kInvitePadding + MAX(kInviteAvatar, _laid.size.height) + kInviteButtonsTop + buttons * kInviteButton + (buttons - 1) * kInviteButtonGap +
           kInvitePadding + kMargin;
}

- (void)layout {
    [super layout];
    CGFloat width = NSWidth(self.bounds);
    [self heightForWidth:width];
    CGFloat inner = kMargin + kInvitePadding;
    _avatar.frame = NSMakeRect(kInvitePadding, inner + 1, kInviteAvatar, kInviteAvatar);
    CGFloat y = inner + MAX(kInviteAvatar, _laid.size.height) + kInviteButtonsTop;
    for (SNButton *button in _join ? @[ _join, _decline ] : @[ _decline ]) {
        button.frame = NSMakeRect(kInvitePadding, y, width - 2 * kInvitePadding, kInviteButton);
        y += kInviteButton + kInviteButtonGap;
    }
}

- (void)drawRect:(NSRect)dirtyRect {
    NSRect box = NSMakeRect(0, kMargin, NSWidth(self.bounds), NSHeight(self.bounds) - 2 * kMargin);
    // 0 0 0 1px rgba(foreground_low, .13), then the theme's darkest base.
    [SNColor(SNLegacyHairline) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(box, -1, -1) xRadius:SNRadiusXlarge + 1 yRadius:SNRadiusXlarge + 1] fill];
    [SNColor(SNThemeBaseInvPry) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:box xRadius:SNRadiusXlarge yRadius:SNRadiusXlarge] fill];
    [_laid drawAtPoint:CGPointMake(kInvitePadding + kInviteAvatar + kInviteAvatarGap, kMargin + kInvitePadding) hovered:nil
           images:self.imageHolder];
}

@end

#pragma mark Call

@interface SNHuddleCallView : NSView
@property (nonatomic, readonly) SNButton *mic, *leave;
@property (nonatomic, readonly, nullable) NSString *speakerID;
- (void)showCall:(SNCall *)call;
@end

@implementation SNHuddleCallView {
    id<SNSource> _source;
    SNAvatarView *_face;
    CALayer *_ring;
    SNCall *_call;
    BOOL _speaking;
}

- (instancetype)initWithSource:(id<SNSource>)source {
    if (!(self = [super initWithFrame:NSZeroRect])) return nil;
    _source = source;
    self.wantsLayer = YES;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;
    _face = [[SNAvatarView alloc] initWithFrame:NSMakeRect(0, 0, kFace, kFace)];
    [self addSubview:_face];
    // .p-huddle_activity__border: 1.5 pt of theme content-inv-pry, radius 8, breathing
    // (huddle_active_speaker: .8 s ease-out, alternate, scale .9091 to 1, opacity .4 to 1).
    _ring = [CALayer layer];
    _ring.borderWidth = 1.5;
    _ring.borderColor = SNCGColor(SNThemeContentInvPry);
    _ring.cornerRadius = SNRadiusLarge;
    _ring.hidden = YES;
    [self.layer addSublayer:_ring];
    _mic = [SNButton iconButtonNamed:@"microphone-off" size:kControl iconSize:20];
    _mic.cornerRadius = kControl / 2;
    _mic.hoverColor = SNThemeSurfInvPryHover;
    _mic.pressedColor = SNThemeSurfInvPryPressed;
    __weak SNHuddleCallView *weakSelf = self;
    _mic.action = ^(SNButton *button) {
        SNHuddleCallView *view = weakSelf;
        if (view->_call) [view->_source setCallMuted:!view->_call.muted];
    };
    _leave = [SNButton primaryButtonWithTitle:SNLocalized(@"huddle.leave")];
    _leave.font = SNFont(SNFontSizeCaption, SNFontWeightBold);
    _leave.fillColor = _leave.hoverFillColor = SNColorBaseInvImp;
    _leave.hoverColor = SNColorBaseInvImpHover;
    _leave.pressedColor = SNColorBaseInvImpPressed;
    _leave.contentColor = _leave.hoverContentColor = _leave.pressedContentColor = SNColorContentInvPry;
    _leave.tooltip = SNLocalized(@"huddle.leave.tip");
    _leave.action = ^(SNButton *button) {
        SNHuddleCallView *view = weakSelf;
        [view->_source leaveCall];
    };
    [self addSubview:_mic];
    [self addSubview:_leave];
    return self;
}

- (BOOL)isFlipped { return YES; }

+ (CGFloat)height { return 1 + kFooterPadding + kIcon + kControlsGap + kControl + kFooterPadding + 1 + kMargin; }

- (void)showCall:(SNCall *)call {
    _call = call;
    NSString *me = _source.me.userID ?: @"";
    SNHuddle *huddle = [_source huddleInConversation:call.conversationID];
    // The person heard now; else someone else in the huddle; else the user.
    NSString *speaker = nil;
    for (NSString *userID in [call.speakingUserIDs.allObjects sortedArrayUsingSelector:@selector(compare:)])
        if (!speaker || [speaker isEqualToString:me]) speaker = userID;
    _speaking = speaker != nil;
    for (NSString *userID in huddle.participantIDs)
        if (!speaker && ![userID isEqualToString:me]) speaker = userID;
    _speakerID = speaker ?: me;
    _face.imageURL = [[_source userWithID:_speakerID] avatarURLForPixels:kFace * 2];
    BOOL wasHidden = _ring.hidden;
    _ring.hidden = !_speaking;
    if (_speaking && wasHidden) [self breathe];
    // --mic-unmuted: theme base-pry under content-ter; muted: surf-inv-pry under content-inv-sec.
    _mic.icon.iconName = call.muted ? @"microphone-off" : @"microphone";
    _mic.fillColor = _mic.hoverFillColor = call.muted ? SNThemeSurfInvPry : SNThemeBasePry;
    _mic.contentColor = _mic.hoverContentColor = _mic.pressedContentColor = call.muted ? SNThemeContentInvSec : SNThemeContentTer;
    _mic.tooltip = SNLocalized(call.muted ? @"huddle.unmute" : @"huddle.mute");
    BOOL connecting = call.state == SNCallJoining || call.state == SNCallReconnecting;
    _mic.enabled = call.state != SNCallLeaving;
    _mic.alphaValue = connecting ? 0.7 : 1;
    _leave.enabled = call.state != SNCallLeaving;
    self.needsDisplay = YES;
    self.needsLayout = YES;
}

- (void)breathe {
    CABasicAnimation *scale = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    scale.fromValue = @0.9091;
    scale.toValue = @1;
    CABasicAnimation *opacity = [CABasicAnimation animationWithKeyPath:@"opacity"];
    opacity.fromValue = @0.4;
    opacity.toValue = @1;
    CAAnimationGroup *group = [CAAnimationGroup animation];
    group.animations = @[ scale, opacity ];
    group.duration = 0.8;
    group.autoreverses = YES;
    group.repeatCount = HUGE_VALF;
    group.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    [_ring addAnimation:group forKey:@"speaking"];
}

- (void)layout {
    [super layout];
    CGFloat width = NSWidth(self.bounds), top = 1 + kFooterPadding;
    CGRect icon = CGRectMake(1 + kFooterPadding, top, kIcon, kIcon);
    _face.frame = NSInsetRect(icon, (kIcon - kFace) / 2, (kIcon - kFace) / 2);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _ring.frame = icon;
    [CATransaction commit];
    CGFloat controls = top + kIcon + kControlsGap;
    _mic.frame = NSMakeRect(1 + kFooterPadding, controls, kControl, kControl);
    CGFloat leaveWidth = MAX(kLeaveMinWidth, _leave.fittingContentSize.width + 24);
    _leave.frame = NSMakeRect(width - 1 - kFooterPadding - leaveWidth, controls, leaveWidth, kControl);
}

- (void)drawRect:(NSRect)dirtyRect {
    NSRect box = NSMakeRect(0.5, 0.5, NSWidth(self.bounds) - 1, NSHeight(self.bounds) - kMargin - 1);
    NSBezierPath *border = [NSBezierPath bezierPathWithRoundedRect:box xRadius:SNRadiusXlarge yRadius:SNRadiusXlarge];
    [SNColor(kFooterBorder) setStroke];
    border.lineWidth = 1;
    [border stroke];
    if (!_call) return;
    SNConversation *conversation = [_source conversationWithID:_call.conversationID];
    NSString *title = conversation ? SNConversationTitle(conversation, _source) : @"";
    if (conversation && conversation.kind != SNConversationDirect && conversation.kind != SNConversationGroupDirect) title = [@"#" stringByAppendingString:title];
    NSUInteger people = [_source huddleInConversation:_call.conversationID].participantIDs.count;
    NSString *subtext = _call.state == SNCallJoining ? SNLocalized(@"huddle.joining")
                      : people > 1                   ? SNLocalizedFormat(@"huddle.people", @(people).stringValue)
                                                     : SNLocalized(@"huddle.alone");
    CGFloat x = 1 + kFooterPadding + kIcon + kIconGap, right = NSWidth(self.bounds) - 1 - kFooterPadding;
    CGFloat top = 1 + kFooterPadding;
    SNDrawText(title, SNFont(SNFontSizeBase, SNFontWeightSemibold), SNThemeContentInvPry, 16, NSTextAlignmentLeft, 1, NSMakeRect(x, top - 1, right - x, 16));
    SNDrawText(subtext, SNFont(SNFontSizeCaption, SNFontWeightRegular), SNThemeContentInvPry, 16, NSTextAlignmentLeft, 1, NSMakeRect(x, top + 13, right - x, 16));
}

@end

#pragma mark Footer

@interface SNHuddleSidebarFooter () <SNChangeObserver>
@end

@implementation SNHuddleSidebarFooter {
    id<SNSource> _source;
    SNHuddleInviteView *_inviteView;
    SNHuddleCallView *_callView;
}

- (instancetype)initWithSource:(id<SNSource>)source {
    if (!(self = [super initWithFrame:NSZeroRect])) return nil;
    _source = source;
    [source addChangeObserver:self];
    [self update];
    return self;
}

- (BOOL)isFlipped { return YES; }

- (SNButton *)joinButton { return _inviteView.join; }
- (SNButton *)declineButton { return _inviteView.decline; }
- (SNButton *)micButton { return _callView.mic; }
- (SNButton *)leaveButton { return _callView.leave; }
- (NSString *)speakerID { return _callView.speakerID; }

- (void)sourceChanged:(SNChange *)change {
    if (change.huddleInvites || change.call || change.huddles || change.users) [self update];
}

- (CGFloat)preferredHeight {
    CGFloat width = NSWidth(self.bounds) - 2 * kMargin;
    return (_inviteView ? [_inviteView heightForWidth:MAX(width, 100)] : 0) + (_callView ? SNHuddleCallView.height : 0);
}

- (void)update {
    CGFloat old = self.preferredHeight;
    // The newest invitation shows; the others wait behind it until it goes.
    SNHuddleInvite *invite = _source.huddleInvites.lastObject;
    if (invite != _inviteView.invite) {
        [_inviteView removeFromSuperview];
        _inviteView = invite ? [[SNHuddleInviteView alloc] initWithInvite:invite source:_source] : nil;
        if (_inviteView) [self addSubview:_inviteView];
    } else if (_inviteView) {
        [_inviteView refresh];
    }
    SNCall *call = _source.call;
    if (call && !_callView) {
        _callView = [[SNHuddleCallView alloc] initWithSource:_source];
        [self addSubview:_callView];
    } else if (!call && _callView) {
        [_callView removeFromSuperview];
        _callView = nil;
    }
    if (call) [_callView showCall:call];
    self.needsLayout = YES;
    if (self.preferredHeight != old && self.heightChanged) self.heightChanged();
}

- (void)layout {
    [super layout];
    CGFloat width = NSWidth(self.bounds) - 2 * kMargin, y = 0;
    if (_inviteView) {
        CGFloat height = [_inviteView heightForWidth:width];
        _inviteView.frame = NSMakeRect(kMargin, y, width, height);
        y += height;
    }
    if (_callView) _callView.frame = NSMakeRect(kMargin, y, width, SNHuddleCallView.height);
}

@end
