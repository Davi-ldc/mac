// Owns the Activity row's hover actions: their buttons, hover and tooltips.
#import "render/icon.h"
#import "render/strings.h"
#import "ui/activity/actions.h"

/// c-message_actions__button--smedium: 32 pt, radius 8, 18 pt glyph; the group pads them by 4.
static const CGFloat kButton = 32, kPadding = 4, kGlyph = 18;
/// rgba(232,232,232,.04) under the pointer, as the message actions' buttons.
static const SNColorToken kButtonHover = 0xe8e8e80a;
/// The group's 0 0 0 1px rgba(foreground_low,.13) ring.
static const SNColorToken kRing = 0xe8e8e821;

@interface SNActivityActionButton : SNHoverView
@property (nonatomic) SNActivityAction kind;
@property (nonatomic) SNIconLayer *glyph;
@end

@implementation SNActivityActionButton

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.hoverColor = self.pressedColor = kButtonHover;
    self.overlayRadius = SNRadiusLarge;
    self.transitionDuration = SNLiveActionBarIconScale;
    self.transitionTiming = SNEaseDefault();
    _glyph = [SNIconLayer iconNamed:nil size:kGlyph color:SNColorContentPry];
    [self.layer addSublayer:_glyph];
    return self;
}

- (void)layout {
    [super layout];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _glyph.bounds = CGRectMake(0, 0, kGlyph, kGlyph);
    _glyph.position = CGPointMake(NSMidX(self.bounds), NSMidY(self.bounds));
    [CATransaction commit];
}

- (void)stateDidChange {
    [super stateDidChange];
    _glyph.affineTransform = self.hovered ? CGAffineTransformMakeScale(1.2, 1.2) : CGAffineTransformIdentity;
}

@end

@implementation SNActivityActionBar {
    CALayer *_group;
    NSMutableArray<SNActivityActionButton *> *_buttons;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.wantsLayer = YES;
    _group = [CALayer layer];
    _group.backgroundColor = SNCGColor(SNColorBasePry);
    _group.borderColor = SNCGColor(kRing);
    _group.borderWidth = 1;
    _group.cornerRadius = SNRadiusXlarge;
    // 0 1px 3px rgba(0,0,0,.08) under the ring.
    _group.shadowColor = CGColorGetConstantColor(kCGColorBlack);
    _group.shadowOpacity = 0.08;
    _group.shadowRadius = 1.5;
    _group.shadowOffset = CGSizeMake(0, -1);
    [self.layer addSublayer:_group];
    _buttons = [NSMutableArray new];
    _actions = @[];
    return self;
}

- (BOOL)isFlipped { return YES; }
- (NSArray<SNHoverView *> *)buttons { return _buttons; }
- (CGFloat)width { return 2 * kPadding + _actions.count * kButton; }

- (void)showActions:(NSArray<NSNumber *> *)actions {
    if ([actions isEqualToArray:_actions]) return;
    _actions = [actions copy];
    for (NSView *button in _buttons) [button removeFromSuperview];
    [_buttons removeAllObjects];
    // XOl9: the icons and the mouse tooltips ("Mark as Read" capitalised, as Slack's).
    static NSString *const icons[] = {[SNActivityActionMarkRead] = @"mark-as-read", [SNActivityActionMarkUnread] = @"mark-as-unread",
                                      [SNActivityActionClear] = @"eraser", [SNActivityActionMore] = @"ellipsis-vertical-filled"};
    static NSString *const tips[] = {[SNActivityActionMarkRead] = @"activity.action.read", [SNActivityActionMarkUnread] = @"activity.action.unread",
                                     [SNActivityActionClear] = @"activity.action.clear", [SNActivityActionMore] = @"activity.action.more"};
    __weak SNActivityActionBar *weakSelf = self;
    for (NSNumber *action in actions) {
        SNActivityAction kind = (SNActivityAction)action.integerValue;
        SNActivityActionButton *button = [[SNActivityActionButton alloc] initWithFrame:NSMakeRect(kPadding + _buttons.count * kButton, kPadding, kButton, kButton)];
        button.kind = kind;
        button.glyph.iconName = icons[kind];
        button.tooltip = SNLocalized(tips[kind]);
        button.action = ^(SNActivityActionButton *pressed) {
            SNActivityActionBar *bar = weakSelf;
            if (bar.chosen) bar.chosen(pressed.kind, pressed.frame);
        };
        [_buttons addObject:button];
        [self addSubview:button];
    }
    self.needsLayout = YES;
}

- (void)layout {
    [super layout];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _group.frame = self.bounds;
    [CATransaction commit];
}

@end
