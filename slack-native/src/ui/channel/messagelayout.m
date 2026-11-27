// Owns the geometry of a message row.
#import <CoreText/CoreText.h>

#import "render/expandable.h"
#import "render/format.h"
#import "render/strings.h"
#import "ui/channel/messagelayout.h"
#import "ui/files/fileview.h"
#import "ui/huddle/huddle.h"
#import "ui/kit/label.h"

/// Slack groups a sender's messages sent within this many seconds of each other.
static const NSTimeInterval kGroupInterval = 5 * 60;
/// The gap after the text before files, the 6 pt above the reaction pills, the 4 pt spacer that
/// ends the row (measured on the captures).
static const CGFloat kAfterText = 4, kAboveReactions = 6, kPillGap = 4;
/// .c-file_gallery__mixed_file_format: 40 pt grid columns 8 pt apart, a card spanning 7; one
/// column at 664 pt and narrower; 1000 pt at most.
static const CGFloat kGalleryColumn = 40, kGalleryGap = 8, kGalleryCompact = 664, kGalleryMaxWidth = 1000;
static const NSUInteger kGalleryColumns = 7;
/// .c-message_kit__labels__label in the message pane: 4 pt down, 13 pt text, 4 pt into the message.
static const CGFloat kLabelTop = 4, kLabelLine = 18, kLabelOverlap = 4;
/// .p-huddle_msg_join_button__container: 8 pt above and below a medium (36 pt) button; the LIVE
/// badge 4 pt after the status.
static const CGFloat kJoinPadding = 8, kJoinHeight = 36, kLiveGap = 4;
@implementation SNFileLayout

+ (instancetype)file:(SNFile *)file style:(SNFileStyle)style frame:(NSRect)frame context:(NSString *)context {
    SNFileLayout *layout = [self new];
    layout->_file = file;
    layout->_style = style;
    layout->_frame = frame;
    layout->_context = context;
    return layout;
}

- (void)setExpandableKey:(NSString *)key title:(NSString *)title {
    _expandableKey = [key copy];
    _metaTitle = [title copy];
    _togglesFiles = _style == SNFileStyleImage || _style == SNFileStyleSnippet || _style == SNFileStyleCollapsed;
}

@end

BOOL SNMessageGroupsWith(SNMessage *message, SNMessage *previous) {
    if (!previous || !message.userID || ![message.userID isEqualToString:previous.userID]) return NO;
    // Each message only the user sees carries its own label.
    if (message.isEphemeral || previous.isEphemeral) return NO;
    for (NSString *subtype in @[ message.subtype ?: @"", previous.subtype ?: @"" ])
        if ([subtype hasSuffix:@"_join"] || [subtype hasSuffix:@"_leave"] || [subtype isEqualToString:@"thread_broadcast"] || [subtype isEqualToString:@"huddle_thread"])
            return NO;
    NSTimeInterval gap = message.ts.doubleValue - previous.ts.doubleValue;
    return gap >= 0 && gap < kGroupInterval && [NSCalendar.currentCalendar isDate:message.date inSameDayAsDate:previous.date];
}

static CGFloat ExactWidth(NSString *text, NSFont *font) { return SNTextWidth(text, font); }

static CGFloat TextWidth(NSString *text, NSFont *font) { return ceil(SNTextWidth(text, font)); }

CGFloat SNReactionWidth(SNReaction *reaction, BOOL mine) {
    NSFont *font = SNFont(SNFontSizeMicro, mine ? SNFontWeightBold : SNFontWeightRegular);
    return 8 + 16 + 4 + TextWidth(@(reaction.count).stringValue, font) + 8;
}

@implementation SNMessageLayout

+ (instancetype)layoutForMessage:(SNMessage *)message
                    continuation:(BOOL)continuation
                           style:(SNMessageRowStyle)style
                           width:(CGFloat)width
                        renderer:(SNRenderer *)renderer {
    SNMessageLayout *layout = [self new];
    layout->_continuation = continuation;
    layout->_style = style;
    layout->_width = width;
    CGFloat textWidth = MAX(40, width - SNMessageTextLeft - SNMessageTextRight), y = SNMessageTextTop;
    CGFloat label = 0;
    if (message.isEphemeral) {
        layout->_ephemeralRect = NSMakeRect(SNMessageGutter, kLabelTop, width - SNMessageGutter - SNMessageTextRight, kLabelLine);
        label = kLabelTop + kLabelLine - kLabelOverlap;
        y += label;
    }
    layout->_time = style == SNMessageRowThreadParent ? SNFormatDayAndTime(message.date, renderer.now) : SNFormatTime(message.date);
    if (continuation) {
        // The 56 pt gutter box right-aligned against the avatar's column.
        NSRect box = layout->_compactTimeRect = NSMakeRect(SNMessageGutter - 20, y, 56, SNMessageLineHeight);
        CGFloat timeWidth = TextWidth(layout->_time, SNFont(SNFontSizeMicro, SNFontWeightRegular));
        layout->_compactTimeBox = NSMakeRect(NSMaxX(box) - timeWidth, NSMinY(box), timeWidth, box.size.height);
    } else {
        layout->_isHuddle = [message.subtype isEqualToString:@"huddle_thread"];
        SNHuddle *huddle = layout->_isHuddle ? [renderer huddleOfMessage:message] : nil;
        layout->_huddleLive = huddle.isActive;
        layout->_senderName = layout->_isHuddle ? [renderer huddleStatusOfMessage:message] : [renderer senderOfMessage:message];
        layout->_avatarRect = NSMakeRect(SNMessageGutter, SNMessageAvatarTop + label, SNMessageAvatarSize, SNMessageAvatarSize);
        CGFloat nameWidth = MIN(textWidth - 60, ExactWidth(layout->_senderName, SNFont(SNFontSizeBase, SNFontWeightBlack)));
        layout->_nameRect = NSMakeRect(SNMessageTextLeft, y, ceil(nameWidth), SNMessageLineHeight);
        // The time follows after a 4 pt margin and a space (measured: 7.75 pt after the name).
        CGFloat x = SNMessageTextLeft + nameWidth + 3.75;
        id<SNSource> source = renderer.source;
        if (!layout->_isHuddle && message.userID && source.offersVIPs && [source.vipUserIDs containsObject:message.userID] && ![message.conversationID hasPrefix:@"D"]) {
            layout->_vipBadgeRect = NSMakeRect(SNMessageTextLeft + nameWidth + 4, y + (SNMessageLineHeight - 18) / 2, 18, 18);
            x = NSMaxX(layout->_vipBadgeRect) + 3.75;
        }
        if (layout->_huddleLive) {
            layout->_liveBadgeRect = NSMakeRect(x + kLiveGap, y, SNLiveBadgeWidth(), SNMessageLineHeight);
            x = NSMaxX(layout->_liveBadgeRect);
        } else if (message.botID && !message.userID && !layout->_isHuddle) {
            layout->_badgeRect = NSMakeRect(x + 4, y + 5, TextWidth(@"APP", SNFont(10, SNFontWeightBold)) + 6, 14);
            x = NSMaxX(layout->_badgeRect);
        }
        layout->_timeRect = NSMakeRect(x + 4, y, TextWidth(layout->_time, SNFont(SNFontSizeMicro, SNFontWeightRegular)), SNMessageLineHeight);
        y += SNMessageLineHeight;
    }
    SNRenderDocument *document = [renderer documentForMessage:message inThread:style != SNMessageRowInConversation];
    layout->_body = [document layoutForWidth:textWidth];
    layout->_bodyOrigin = NSMakePoint(SNMessageTextLeft, y);
    y += layout->_body.size.height;
    // shouldAddJoinButton: a live huddle the user is not in; this build must be able to join.
    if (layout->_huddleLive && renderer.source.canJoinHuddles && ![[renderer huddleOfMessage:message].participantIDs containsObject:renderer.source.me.userID ?: @""]) {
        NSArray<NSString *> *faces = SNFacepileUserIDs([renderer huddleOfMessage:message], 3);
        layout->_huddleFaces = faces;
        y += kJoinPadding;
        layout->_joinRect = NSMakeRect(SNMessageTextLeft, y, [SNHuddleJoinButton widthForTitle:SNLocalized(@"channel.huddle.join") faces:faces.count], kJoinHeight);
        y += kJoinHeight + kJoinPadding;
    }

    NSMutableArray<SNFileLayout *> *files = [NSMutableArray new];
    // A snippet expands per message and column, as Slack keys it.
    NSString *context = [NSString stringWithFormat:@"%@/%@/%@", message.conversationID ?: @"", message.ts, style == SNMessageRowInConversation ? @"channel" : @"thread"];
    NSMutableArray<SNFile *> *visual = [NSMutableArray new], *others = [NSMutableArray new];
    for (SNFile *file in message.files) {
        if ([file.mode isEqualToString:@"tombstone"]) continue;
        SNFileStyle fileStyle = SNFileStyleOf(file);
        [fileStyle == SNFileStyleImage || fileStyle == SNFileStyleVideo ? visual : others addObject:file];
    }
    NSString *viewContext = style == SNMessageRowInConversation ? SNViewContextChannel : SNViewContextThread;
    NSString *filesKey = SNExpandableFilesKey(message, viewContext);
    NSUInteger shownFiles = visual.count + others.count;
    if (shownFiles && !SNFilesAreExpanded(message, viewContext, renderer.source)) {
        // Only the meta line stays: the name of the one file, or how many there are.
        SNFile *first = visual.firstObject ?: others.firstObject;
        NSString *title = shownFiles == 1 ? (first.title.length ? first.title : first.name) : SNLocalizedFormat(@"channel.file.count", @(shownFiles));
        y += !document.isEmpty ? kAfterText : 0;
        NSRect frame = {{SNMessageTextLeft, y}, SNCollapsedFilesSize(title, textWidth)};
        SNFileLayout *line = [SNFileLayout file:first style:SNFileStyleCollapsed frame:frame context:context];
        [line setExpandableKey:filesKey title:title];
        [files addObject:line];
        y = NSMaxY(frame);
        [visual removeAllObjects];
        [others removeAllObjects];
    }
    // FileGallery: one file shows whole; with others, pictures and videos come first and the
    // rest follow as plain cards (no first page, no code) in 328 pt cells 8 pt apart, as many
    // per row as fit past 664 pt, else one column of 426.
    BOOL mixed = others.count && visual.count + others.count > 1;
    for (SNFile *file in visual) {
        y += files.count || !document.isEmpty ? kAfterText : 0;
        SNFileStyle fileStyle = SNFileStyleOf(file);
        NSRect frame = {{SNMessageTextLeft, y}, SNFileViewSize(file, fileStyle, textWidth, context)};
        SNFileLayout *fileLayout = [SNFileLayout file:file style:fileStyle frame:frame context:context];
        [fileLayout setExpandableKey:filesKey title:nil];
        [files addObject:fileLayout];
        y = NSMaxY(frame);
    }
    CGFloat gallery = MIN(textWidth, kGalleryMaxWidth);
    NSUInteger perRow = mixed && gallery > kGalleryCompact ? MAX(1, (NSUInteger)floor((gallery + kGalleryGap) / (kGalleryColumn + kGalleryGap)) / kGalleryColumns) : 1;
    CGFloat cell = perRow > 1 ? kGalleryColumns * kGalleryColumn + (kGalleryColumns - 1) * kGalleryGap : textWidth;
    CGFloat rowTop = 0, rowBottom = 0;
    for (NSUInteger i = 0; i < others.count; i++) {
        SNFile *file = others[i];
        SNFileStyle fileStyle = SNFileStyleOf(file);
        if (mixed && (fileStyle == SNFileStyleDocument || fileStyle == SNFileStyleSnippet)) fileStyle = SNFileStyleCard;
        if (i % perRow == 0) {
            y = i ? rowBottom + kGalleryGap : y + (files.count ? (mixed ? kGalleryGap : kAfterText) : !document.isEmpty ? kAfterText : 0);
            rowTop = y;
        }
        NSSize size = SNFileViewSize(file, fileStyle, cell, context);
        NSRect frame = NSMakeRect(SNMessageTextLeft + (i % perRow) * (cell + kGalleryGap), rowTop, size.width, size.height);
        SNFileLayout *fileLayout = [SNFileLayout file:file style:fileStyle frame:frame context:context];
        [fileLayout setExpandableKey:filesKey title:nil];
        [files addObject:fileLayout];
        rowBottom = MAX(rowBottom, NSMaxY(frame));
        y = rowBottom;
    }
    layout->_files = files;

    if (message.sendState == SNMessageFailed) {
        y += kAfterText;
        NSFont *font = SNFont(SNFontSizeCaption, SNFontWeightRegular);
        CGFloat label = TextWidth(SNLocalized(@"channel.failed"), font), separator = TextWidth(@" · ", font);
        layout->_failedRect = NSMakeRect(SNMessageTextLeft, y, SNFailedIconWidth + label, SNMessageLineHeight);
        layout->_retryRect = NSMakeRect(NSMaxX(layout->_failedRect) + 4, y, TextWidth(SNLocalized(@"channel.failed.retry"), font), SNMessageLineHeight);
        layout->_discardRect = NSMakeRect(NSMaxX(layout->_retryRect) + separator, y, TextWidth(SNLocalized(@"channel.failed.delete"), font), SNMessageLineHeight);
        y += SNMessageLineHeight;
    }

    NSMutableArray<NSValue *> *pills = [NSMutableArray new];
    if (message.reactions.count) {
        y += kAboveReactions;
        CGFloat x = SNMessageTextLeft, right = SNMessageTextLeft + textWidth;
        NSString *me = renderer.source.me.userID ?: @"";
        NSMutableArray<NSNumber *> *widths = [NSMutableArray new];
        for (SNReaction *reaction in message.reactions) [widths addObject:@(SNReactionWidth(reaction, [reaction.userIDs containsObject:me]))];
        // The add-reaction pill: 8 pt padding around an 18 pt glyph.
        [widths addObject:@(8 + 18 + 8)];
        for (NSNumber *pillWidth in widths) {
            CGFloat w = pillWidth.doubleValue;
            if (x > SNMessageTextLeft && x + w > right) x = SNMessageTextLeft, y += SNReactionHeight + kPillGap;
            [pills addObject:[NSValue valueWithRect:NSMakeRect(x, y, w, SNReactionHeight)]];
            x += w + kPillGap;
        }
        y += SNReactionHeight;
    }
    layout->_reactionFrames = pills;

    if (style == SNMessageRowInConversation && message.replyCount > 0) {
        // components.json thread_reply_bar: it hangs 5 pt left so the avatars line up with the
        // text, at most 600 wide, and overlaps what follows by 2 pt.
        layout->_replyBarRect = NSMakeRect(SNMessageTextLeft - 5, y, MIN(600, textWidth + 5), SNReplyBarHeight);
        y += SNReplyBarHeight - 2;
    }
    y += kAfterText;
    layout->_height = ceil(MAX(y, continuation ? 0 : NSMaxY(layout->_avatarRect) + 8));
    return layout;
}

@end
