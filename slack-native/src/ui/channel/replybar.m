// Owns the reply bar's pieces and its hover fade.
#import "render/format.h"
#import "render/icon.h"
#import "render/strings.h"
#import "ui/channel/replybar.h"
#import "ui/kit/avatar.h"
#import "ui/kit/label.h"

/// components.json thread_reply_bar: 4 pt padding inside a 1 pt border, 24 pt avatars 4 pt
/// apart (at most 5), the count 3 pt after them, the description 8 pt after the count, an 18 pt
/// caret at the right.
static const CGFloat kInset = 5, kAvatar = 24, kAvatarGap = 4, kCountGap = 3, kDescriptionGap = 8, kCaret = 18;
static const NSUInteger kMaxAvatars = 5;

@implementation SNReplyBar {
    SNLayer *_frameLayer;
    SNIconLayer *_caret;
    NSArray<SNAvatarView *> *_avatars;
    SNLabel *_count, *_description;
}

- (instancetype)initWithMessage:(SNMessage *)message source:(id<SNSource>)source now:(NSDate *)now {
    if (!(self = [super initWithFrame:NSZeroRect])) return nil;
    self.canDrawSubviewsIntoLayer = YES;
    self.hoverColor = self.pressedColor = 0;
    self.transitionDuration = SNLiveReplyBarHover;
    self.transitionTiming = SNEaseLiveReplyBarHover();
    _frameLayer = [SNLayer layer];
    _frameLayer.cornerRadius = 6;
    _frameLayer.borderWidth = 1;
    [self.layer addSublayer:_frameLayer];
    NSMutableArray *avatars = [NSMutableArray new];
    for (NSString *userID in message.replyUserIDs) {
        if (avatars.count == kMaxAvatars) break;
        SNAvatarView *avatar = [[SNAvatarView alloc] initWithFrame:NSMakeRect(0, 0, kAvatar, kAvatar)];
        avatar.imageURL = [[source userWithID:userID] avatarURLForPixels:72];
        [self addSubview:avatar];
        [avatars addObject:avatar];
    }
    _avatars = avatars;
    _count = [SNLabel labelWithText:SNFormatReplyCount(message.replyCount) font:SNFont(SNFontSizeCaption, SNFontWeightBold) color:SNColorContentHgl1];
    [self addSubview:_count];
    NSDate *latest = message.latestReply ? [NSDate dateWithTimeIntervalSince1970:message.latestReply.doubleValue] : nil;
    NSString *description = latest ? SNLocalizedFormat(@"channel.reply.last", SNFormatAgo(latest, now)) : SNLocalized(@"channel.reply.view");
    _description = [SNLabel labelWithText:description font:SNFont(SNFontSizeCaption, SNFontWeightRegular) color:SNLegacyForegroundMaxSolid];
    [self addSubview:_description];
    _caret = [SNIconLayer iconNamed:@"caret-right" size:kCaret color:SNLegacyForegroundHighSolid];
    [self.layer addSublayer:_caret];
    [self stateDidChange];
    return self;
}

- (void)layout {
    [super layout];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    NSSize size = self.bounds.size;
    _frameLayer.frame = self.bounds;
    CGFloat x = kInset;
    for (SNAvatarView *avatar in _avatars) {
        avatar.frame = NSMakeRect(x, kInset, kAvatar, kAvatar);
        x += kAvatar + kAvatarGap;
    }
    x += kCountGap - (_avatars.count ? kAvatarGap : 0);
    CGFloat countWidth = ceil(_count.textWidth);
    _count.frame = NSMakeRect(x, 0, countWidth, size.height);
    _count.lineHeight = size.height;
    x += countWidth + kDescriptionGap;
    CGFloat caretX = size.width - kInset - kCaret;
    _description.frame = NSMakeRect(x, 0, MAX(0, caretX - 4 - x), size.height);
    _description.lineHeight = size.height;
    _caret.frame = CGRectMake(caretX, (size.height - kCaret) / 2, kCaret, kCaret);
    [CATransaction commit];
}

- (void)stateDidChange {
    [super stateDidChange];
    BOOL on = self.hovered;
    _frameLayer.backgroundColor = on ? SNCGColor(SNColorBasePry) : SNCGColor(SNColorWithAlpha(SNColorBasePry, 0));
    _frameLayer.borderColor = on ? SNCGColor(SNMeasuredReplyBarHoverBorder) : SNCGColor(SNColorWithAlpha(SNMeasuredReplyBarHoverBorder, 0));
    _caret.opacity = on;
    _description.hidden = !on;
    self.needsDisplay = YES;
}

@end
