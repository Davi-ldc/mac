// Owns drawing a message row and the hover of its parts.
#import "render/format.h"
#import "render/icon.h"
#import "render/strings.h"
#import "ui/channel/reaction.h"
#import "ui/channel/replybar.h"
#import "ui/channel/row.h"
#import "ui/files/fileview.h"
#import "ui/huddle/huddle.h"
#import "ui/kit/avatar.h"
#import "ui/kit/button.h"
#import "ui/kit/hoverview.h"
#import "ui/kit/label.h"
#import "ui/kit/popover.h"
#import "ui/kit/tooltip.h"
#import "ui/profile/profilecard.h"

typedef NS_ENUM(NSInteger, SNRowPart) {
    SNRowPartNone,
    SNRowPartAvatar,
    SNRowPartName,
    SNRowPartTime,
    SNRowPartBody,
    SNRowPartRetry,
    SNRowPartDiscard,
    SNRowPartVIPBadge,
};

/// The open thread's parent is tinted with base-hgl-3 (components.json message_row).
static const SNColorToken kActiveThread = SNColorBaseHgl3;
/// A message on its way shows at half strength until Slack has it.
static const CGFloat kPendingAlpha = 0.5;
/// "Only visible to you": 13 pt in the foreground at 70%.
static const SNColorToken kEphemeralLabel = 0xe8e8e8b3;
/// Its eye is the legacy font's eye-filled at the label's 13 px (c-icon--inherit), right-aligned
/// on the avatar's edge with the eye's bottom on the text's baseline, 3 pt into the 18 pt line.
/// eye-open-filled is the SVG set's drawing of the same 18x14 eye.
static const CGFloat kEphemeralIcon = 13, kEphemeralIconTop = 3;

@interface SNMessageRowView () <SNCursorProvider>
@end

@implementation SNMessageRowView {
    id<SNSource> _source;
    SNAvatarView *_avatar;
    NSMutableArray<NSView *> *_attached;
    NSMutableArray<NSView *> *_pills;
    SNRowPart _part;
    SNRenderTarget *_target;
    /// A link preview picture's More actions, while the pointer is on the picture.
    SNButton *_pictureMore;
    /// A live huddle's "Join Huddle".
    SNHuddleJoinButton *_join;
}

- (instancetype)initWithSource:(id<SNSource>)source {
    if (!(self = [super initWithFrame:NSZeroRect])) return nil;
    _source = source;
    self.wantsLayer = YES;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;
    self.canDrawSubviewsIntoLayer = YES;
    _avatar = [[SNAvatarView alloc] initWithFrame:NSMakeRect(SNMessageGutter, SNMessageAvatarTop, SNMessageAvatarSize, SNMessageAvatarSize)];
    [self addSubview:_avatar];
    _attached = [NSMutableArray new];
    _pills = [NSMutableArray new];
    _now = NSDate.date;
    return self;
}

- (BOOL)isFlipped { return YES; }
- (NSArray<NSView *> *)pills { return _pills; }

- (void)prepareForReuse {
    [self showMessage:nil layout:nil];
    _avatar.imageURL = nil;
    self.hovered = NO;
    self.highlighted = NO;
    SNReleaseViewImages(self);
}

- (void)showMessage:(SNMessage *)message layout:(SNMessageLayout *)layout {
    if (layout == _layout && message == _message) return;
    SNMessage *previous = _message;
    // The pictures of the text it showed go unless another row shows them.
    if (layout.body != _layout.body) [self.imageHolder removeAllImages];
    _message = message;
    _layout = layout;
    [self setPart:SNRowPartNone target:nil];
    [self updateBackground];
    self.needsDisplay = YES;
    [self showJoinButton:layout];
    _avatar.hidden = !layout || layout.continuation || layout.isHuddle;
    if (!_avatar.hidden) {
        if (!NSEqualRects(_avatar.frame, layout.avatarRect)) _avatar.frame = layout.avatarRect;
        SNUser *user = message.userID ? [_source userWithID:message.userID] : nil;
        NSDictionary *icons = message.botIconURLs.count || !message.botID ? message.botIconURLs : [_source botWithID:message.botID].iconURLs;
        _avatar.imageURL = user ? [user avatarURLForPixels:SNMessageAvatarSize * 2] : SNBestURL(icons ?: @{}, SNMessageAvatarSize * 2);
    }
    // Same message, new width or grouping: the small views stay.
    if (previous == message && _attached.count == [self attachedCountFor:layout]) {
        [self placeAttachments];
        return;
    }
    for (NSView *view in _attached) [view removeFromSuperview];
    [_attached removeAllObjects];
    [_pills removeAllObjects];
    _replyBar = nil;
    if (!layout) return;
    __weak SNMessageRowView *weakSelf = self;
    for (SNFileLayout *file in layout.files) {
        SNFileView *view = SNMakeFileView(file.file, file.style, file.context);
        view.sizeChanged = ^{
            SNMessageRowView *row = weakSelf;
            [row.delegate messageRowNeedsLayout:row];
        };
        if (file.metaTitle) view.metaTitle = file.metaTitle;
        if (file.togglesFiles) {
            NSString *key = file.expandableKey;
            BOOL expand = file.style == SNFileStyleCollapsed;
            view.toggleFiles = ^{
                SNMessageRowView *row = weakSelf;
                [row.delegate messageRow:row setItems:@[ key ] expanded:expand];
            };
        }
        [_attached addObject:view];
    }
    NSMutableArray *reactions = [message.reactions mutableCopy];
    if (reactions.count) [reactions addObject:NSNull.null];
    for (id reaction in reactions) {
        SNReactionPill *pill = [[SNReactionPill alloc] initWithReaction:reaction == NSNull.null ? nil : reaction source:_source];
        pill.action = ^(SNReactionPill *clicked) {
            SNMessageRowView *row = weakSelf;
            if (clicked.reaction) [row.delegate messageRow:row toggleReaction:clicked.reaction.name];
            else [row.delegate messageRow:row addReactionFromView:clicked];
        };
        [_pills addObject:pill];
        [_attached addObject:pill];
    }
    if (!NSIsEmptyRect(layout.replyBarRect)) {
        SNReplyBar *bar = [[SNReplyBar alloc] initWithMessage:message source:_source now:self.now];
        bar.action = ^(SNReplyBar *clicked) {
            SNMessageRowView *row = weakSelf;
            [row.delegate messageRowOpenThread:row];
        };
        _replyBar = bar;
        [_attached addObject:bar];
    }
    for (NSView *view in _attached) {
        view.alphaValue = message.sendState == SNMessagePending ? kPendingAlpha : 1;
        [self addSubview:view];
    }
    [self placeAttachments];
}

- (void)showJoinButton:(SNMessageLayout *)layout {
    if (NSIsEmptyRect(layout.joinRect)) {
        [_join removeFromSuperview];
        _join = nil;
        return;
    }
    if (!_join) {
        _join = [[SNHuddleJoinButton alloc] initWithSource:_source];
        _join.title = SNLocalized(@"channel.huddle.join");
        [self addSubview:_join];
    }
    _join.userIDs = layout.huddleFaces ?: @[];
    _join.frame = layout.joinRect;
    __weak SNMessageRowView *weakSelf = self;
    _join.action = ^(SNButton *button) {
        SNMessageRowView *row = weakSelf;
        if (row.message.conversationID) [row->_source joinHuddleInConversation:row.message.conversationID];
    };
}

- (NSUInteger)attachedCountFor:(SNMessageLayout *)layout {
    return layout.files.count + layout.reactionFrames.count + (NSIsEmptyRect(layout.replyBarRect) ? 0 : 1);
}

- (void)placeAttachments {
    NSUInteger i = 0;
    for (SNFileLayout *file in self.layout.files) _attached[i++].frame = file.frame;
    for (NSValue *frame in self.layout.reactionFrames) _attached[i++].frame = frame.rectValue;
    if (_replyBar) _replyBar.frame = self.layout.replyBarRect;
}

- (void)setHovered:(BOOL)hovered {
    if (hovered == _hovered) return;
    _hovered = hovered;
    if (!hovered) [self setPart:SNRowPartNone target:nil];
    [self updateBackground];
    // The continuation's time in the gutter appears with the hover.
    if (self.layout.continuation) self.needsDisplay = YES;
}

- (void)setHighlighted:(BOOL)highlighted {
    if (highlighted == _highlighted) return;
    _highlighted = highlighted;
    [self updateBackground];
}

- (void)updateBackground {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    // .c-message--ephemeral: foreground_min_solid under it, hovered or not.
    // .c-message_kit__background--huddle: a live huddle's message stays jade-0, hovered or not.
    SNColorToken color = self.highlighted ? kActiveThread : self.message.isEphemeral ? SNLegacyForegroundMinSolid : self.layout.huddleLive ? SNPaletteJade0
                       : self.hovered ? SNMeasuredMessageRowHover : 0;
    self.layer.backgroundColor = color ? SNCGColor(color) : NULL;
    [CATransaction commit];
}

#pragma mark Pointer

/// The part under `point`; SNRowPartNone over the background.
- (SNRowPart)partAtPoint:(NSPoint)point target:(SNRenderTarget **)target {
    SNMessageLayout *layout = self.layout;
    *target = nil;
    // A huddle's square and status are no one's profile.
    if (!layout.isHuddle && NSPointInRect(point, layout.avatarRect)) return SNRowPartAvatar;
    if (!layout.isHuddle && NSPointInRect(point, layout.nameRect)) return SNRowPartName;
    if (NSPointInRect(point, layout.timeRect) || (layout.continuation && NSPointInRect(point, layout.compactTimeBox))) return SNRowPartTime;
    if (NSPointInRect(point, layout.vipBadgeRect)) return SNRowPartVIPBadge;
    if (NSPointInRect(point, layout.retryRect)) return SNRowPartRetry;
    if (NSPointInRect(point, layout.discardRect)) return SNRowPartDiscard;
    *target = [layout.body targetAtPoint:NSMakePoint(point.x - layout.bodyOrigin.x, point.y - layout.bodyOrigin.y)];
    return *target ? SNRowPartBody : SNRowPartNone;
}

- (void)pointerMovedTo:(NSPoint)point {
    SNRenderTarget *target;
    SNRowPart part = [self partAtPoint:point target:&target];
    [self setPart:part target:target];
}

/// Slack links the avatar, the name and the time, as it does every target in the text.
- (NSCursor *)cursorAtPoint:(NSPoint)point {
    SNRenderTarget *target;
    SNRowPart part = [self partAtPoint:point target:&target];
    return part == SNRowPartNone || part == SNRowPartVIPBadge ? nil : NSCursor.pointingHandCursor;
}

- (void)setPart:(SNRowPart)part target:(SNRenderTarget *)target {
    if (part == _part && (target == _target || [target isEqual:_target])) return;
    SNRowPart old = _part;
    _part = part;
    _target = target;
    self.needsDisplay = YES;
    [self placePictureMore];
    BOOL person = part == SNRowPartAvatar || part == SNRowPartName;
    if ((old == SNRowPartAvatar || old == SNRowPartName) && !person) [SNProfileCard hoverEnded];
    if (person && old != SNRowPartAvatar && old != SNRowPartName && self.message.userID)
        [SNProfileCard hoverBeganOverRect:self.layout.avatarRect.size.width ? self.layout.avatarRect : self.layout.nameRect inView:self
                                   userID:self.message.userID
                                   source:_source];
    if (part == SNRowPartTime && old != SNRowPartTime) {
        NSRect rect = self.layout.continuation ? self.layout.compactTimeBox : self.layout.timeRect;
        [SNTooltip showText:SNFormatTimeTooltip(self.message.date) forRect:rect inView:self placement:SNPlacementAbove delay:SNTooltipDelay];
    } else if (part == SNRowPartVIPBadge && old != SNRowPartVIPBadge) {
        [SNTooltip showText:SNLocalized(@"channel.vip") forRect:self.layout.vipBadgeRect inView:self placement:SNPlacementAbove delay:SNTooltipDelay];
    } else if ((old == SNRowPartTime || old == SNRowPartVIPBadge) && part != SNRowPartTime && part != SNRowPartVIPBadge) {
        [SNTooltip hide];
    }
}

- (void)mouseDown:(NSEvent *)event {}
- (void)mouseUp:(NSEvent *)event {
    // A double click is one action: one Retry, one link opened.
    if (event.clickCount > 1) return;
    [self clickAt:[self convertPoint:event.locationInWindow fromView:nil]];
}

- (void)clickAt:(NSPoint)point {
    [self pointerMovedTo:point];
    if (_part == SNRowPartBody && _target) [self.delegate messageRow:self activateTarget:_target];
    // Slack opens the person's full profile beside the conversation; hovering shows the card.
    else if ((_part == SNRowPartAvatar || _part == SNRowPartName) && self.message.userID) [SNProfileCard openProfileOfUser:self.message.userID];
    else if (_part == SNRowPartRetry) [self.delegate messageRowRetrySend:self];
    else if (_part == SNRowPartDiscard) [self.delegate messageRowDiscardSend:self];
}

#pragma mark Link preview pictures

/// The picture toolbar's More actions (UvHM), whose "Hide image" collapses the picture: a 28 pt
/// button on base-modal 8 pt in from the picture's top right, as the file pictures' buttons.
- (void)placePictureMore {
    NSString *key = _part == SNRowPartBody && _target.kind == SNRenderTargetImage ? _target.detail : nil;
    NSRect picture = key ? [self.layout.body rectForTarget:_target] : NSZeroRect;
    if (NSIsEmptyRect(picture)) {
        _pictureMore.hidden = YES;
        return;
    }
    if (!_pictureMore) {
        _pictureMore = [SNButton iconButtonNamed:@"ellipsis-vertical-filled" size:28 iconSize:16];
        _pictureMore.fillColor = SNColorBaseModal;
        _pictureMore.hoverFillColor = SNColorBaseInvPry;
        _pictureMore.borderColor = SNColorOtlInvTer;
        _pictureMore.cornerRadius = SNRadiusBase;
        _pictureMore.contentColor = SNColorContentInvSec;
        _pictureMore.hoverContentColor = _pictureMore.pressedContentColor = SNColorContentInvPry;
        _pictureMore.tooltip = SNLocalized(@"channel.picture.more");
        [self addSubview:_pictureMore];
    }
    __weak SNMessageRowView *weakSelf = self;
    _pictureMore.action = ^(SNButton *button) {
        SNMenuItem *hide = [SNMenuItem itemWithTitle:SNLocalized(@"channel.picture.hide") action:^{
            SNMessageRowView *row = weakSelf;
            [row.delegate messageRow:row setItems:@[ key ] expanded:NO];
        }];
        [[[SNMenu alloc] initWithItems:@[ hide ] width:0] showForRect:button.bounds inView:button placement:SNPlacementBelow];
    };
    NSPoint origin = self.layout.bodyOrigin;
    _pictureMore.frame = NSMakeRect(origin.x + NSMaxX(picture) - 8 - 28, origin.y + NSMinY(picture) + 8, 28, 28);
    _pictureMore.hidden = NO;
}

#pragma mark Drawing

- (void)drawRect:(NSRect)dirtyRect {
    SNMessageLayout *layout = self.layout;
    if (!layout) return;
    if (self.message.sendState == SNMessagePending) CGContextSetAlpha(NSGraphicsContext.currentContext.CGContext, kPendingAlpha);
    if (!NSIsEmptyRect(layout.ephemeralRect)) {
        NSRect label = layout.ephemeralRect;
        SNDrawIcon(@"eye-open-filled", kEphemeralIcon, kEphemeralLabel,
                   NSMakeRect(NSMaxX(layout.avatarRect) - kEphemeralIcon, NSMinY(label) + kEphemeralIconTop, kEphemeralIcon, kEphemeralIcon));
        SNDrawText(SNLocalized(@"channel.ephemeral"), SNFont(SNFontSizeCaption, SNFontWeightRegular), kEphemeralLabel, NSHeight(label), NSTextAlignmentLeft, 1,
                   NSMakeRect(SNMessageTextLeft, NSMinY(label), NSMaxX(label) - SNMessageTextLeft, NSHeight(label)));
    }
    if (!layout.continuation) {
        if (layout.isHuddle) SNDrawHuddleAvatar(layout.avatarRect, layout.huddleLive);
        if (!NSIsEmptyRect(layout.liveBadgeRect)) SNDrawLiveBadge(NSMinX(layout.liveBadgeRect), NSMidY(layout.liveBadgeRect));
        NSFont *nameFont = SNFont(SNFontSizeBase, SNFontWeightBlack);
        SNDrawText(layout.senderName, nameFont, SNColorContentPry, SNMessageLineHeight, NSTextAlignmentLeft, 1, layout.nameRect);
        if (_part == SNRowPartName) [self underline:layout.nameRect font:nameFont color:SNColorContentPry];
        if (!NSIsEmptyRect(layout.vipBadgeRect)) SNDrawIcon(@"vip-filled", 18, SNColorContentPry, layout.vipBadgeRect);
        if (!NSIsEmptyRect(layout.badgeRect)) {
            [SNColor(SNColorSurfSec) setFill];
            [[NSBezierPath bezierPathWithRoundedRect:layout.badgeRect xRadius:2 yRadius:2] fill];
            SNDrawText(@"APP", SNFont(10, SNFontWeightBold), SNLegacyForegroundMaxSolid, layout.badgeRect.size.height, NSTextAlignmentCenter, 1, layout.badgeRect);
        }
        NSFont *timeFont = SNFont(SNFontSizeMicro, SNFontWeightRegular);
        // The time shares the name's baseline.
        CGFloat shift = SNBaselineOffset(nameFont, SNMessageLineHeight) - SNBaselineOffset(timeFont, SNMessageLineHeight);
        NSRect timeRect = NSOffsetRect(layout.timeRect, 0, shift);
        SNDrawText(layout.time, timeFont, SNLegacyForegroundMaxSolid, SNMessageLineHeight, NSTextAlignmentLeft, 1, timeRect);
        if (_part == SNRowPartTime) [self underline:timeRect font:timeFont color:SNLegacyForegroundMaxSolid];
    } else if (self.hovered) {
        NSFont *font = SNFont(SNFontSizeMicro, SNFontWeightRegular);
        SNDrawText(layout.time, font, SNLegacyForegroundMaxSolid, SNMessageLineHeight, NSTextAlignmentRight, 1, layout.compactTimeRect);
        if (_part == SNRowPartTime) [self underline:layout.compactTimeBox font:font color:SNLegacyForegroundMaxSolid];
    }
    [layout.body drawAtPoint:layout.bodyOrigin hovered:_target images:self.imageHolder];
    if (!NSIsEmptyRect(layout.failedRect)) [self drawFailedLine:layout];
}

- (void)drawFailedLine:(SNMessageLayout *)layout {
    NSFont *font = SNFont(SNFontSizeCaption, SNFontWeightRegular);
    NSRect failed = layout.failedRect;
    SNDrawIcon(@"warning-filled", 14, SNColorContentImp, NSMakeRect(NSMinX(failed), NSMidY(failed) - 7, 14, 14));
    SNDrawText(SNLocalized(@"channel.failed"), font, SNColorContentImp, SNMessageLineHeight, NSTextAlignmentLeft, 1,
               NSMakeRect(NSMinX(failed) + SNFailedIconWidth, NSMinY(failed), failed.size.width - SNFailedIconWidth, SNMessageLineHeight));
    SNDrawText(@" · ", font, SNColorContentSec, SNMessageLineHeight, NSTextAlignmentLeft, 1,
               NSMakeRect(NSMaxX(layout.retryRect), NSMinY(failed), NSMinX(layout.discardRect) - NSMaxX(layout.retryRect), SNMessageLineHeight));
    for (NSNumber *part in @[ @(SNRowPartRetry), @(SNRowPartDiscard) ]) {
        BOOL retry = part.integerValue == SNRowPartRetry;
        NSRect rect = retry ? layout.retryRect : layout.discardRect;
        SNDrawText(SNLocalized(retry ? @"channel.failed.retry" : @"channel.failed.delete"), font, SNLegacyHighlight, SNMessageLineHeight,
                   NSTextAlignmentLeft, 1, rect);
        if (_part == part.integerValue) [self underline:rect font:font color:SNLegacyHighlight];
    }
}

- (void)underline:(NSRect)rect font:(NSFont *)font color:(SNColorToken)color {
    CGFloat baseline = NSMinY(rect) + SNBaselineOffset(font, rect.size.height);
    [SNColor(color) setFill];
    NSRectFill(NSMakeRect(NSMinX(rect), baseline + 2, rect.size.width, 1));
}

@end
