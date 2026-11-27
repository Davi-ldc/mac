// Owns parsing rich_text, mrkdwn, Block Kit and attachments into documents.
#import "model/json.h"
#import "render/emoji.h"
#import "render/expandable.h"
#import "render/format.h"
#import "render/message.h"
#import "render/strings.h"

/// Slack draws emoji-only messages of up to this many emoji at the large size.
static const NSUInteger kJumboLimit = 23;
static const SNTextStyle kContextStyle = {SNFontSizeCaption, SNFontWeightRegular, 18, SNLegacyForegroundMaxSolid};
static const SNTextStyle kHeaderStyle = {SNFontSizeSubtitle, SNFontWeightBlack, 24, SNColorContentPry};
static const SNTextStyle kFooterStyle = {SNFontSizeMicro, SNFontWeightRegular, 15, SNColorContentTer};
static const SNTextStyle kCodeStyle = {12, SNFontWeightRegular, 18, SNLegacyPrimaryForeground};
static const SNTextStyle kEditedStyle = {SNFontSizeCaption, SNFontWeightRegular, 22, SNLegacyForegroundHighSolid};
/// Joins, leaves, topic and other changes to the conversation, and deleted parents.
static const SNTextStyle kSystemStyle = {SNFontSizeBase, SNFontWeightRegular, 22, SNLegacyForegroundMaxSolid};

/// Slack's bar colours for the named attachment colours.
static SNColorToken BarColor(NSString *color) {
    if ([color isEqualToString:@"good"]) return 0x2eb67dff;
    if ([color isEqualToString:@"warning"]) return 0xdaa038ff;
    if ([color isEqualToString:@"danger"]) return 0xa30200ff;
    NSString *hex = [color hasPrefix:@"#"] ? [color substringFromIndex:1] : color;
    unsigned value = 0;
    if (hex.length == 6 && [[NSScanner scannerWithString:hex] scanHexInt:&value]) return value << 8 | 0xFF;
    return SNColorBaseTer;
}

/// The preferences that decide which pictures and files show (render/expandable.h).
static NSString *MediaPreferences(NSDictionary *preferences) {
    NSMutableString *values = [NSMutableString new];
    for (NSString *name in @[ @"expand_inline_imgs", @"expand_internal_inline_imgs", @"obey_inline_img_limit" ])
        [values appendFormat:@"%@;", SNPreferenceString(preferences, name) ?: @""];
    return values;
}

/// How a custom, alias or unknown emoji name renders now: its picture, its glyph or nothing.
static NSString *EmojiForm(NSString *name) { return SNCustomEmojiURL(name).absoluteString ?: SNEmojiUnicode(name) ?: @""; }

/// Builds a document's blocks from what the walker reads (text/walk.h), naming mentions through
/// the renderer. A sink made into a text appends pieces to it and has no blocks; a flat one (a
/// preview) runs every block on in that one paragraph, a space apart.
@interface SNDocumentSink : SNTextSink {
  @public
    __unsafe_unretained SNRenderer *_renderer;
    SNTextStyle _style;
    BOOL _jumbo, _flat;
    NSMutableArray<SNRenderBlock *> *_blocks;
    SNInlineText *_text;
    SNTextBlockKind _kind;
    NSInteger _indent, _number;
    /// A preview's preformatted text, which has no block of its own to be code in.
    SNInlineStyle _blockStyle;
    /// Where a preview's text starts, after "You: ".
    NSUInteger _start;
}
- (NSArray<SNRenderBlock *> *)finish;
@end

@interface SNRenderer ()
- (void)appendWebLink:(NSURL *)url text:(nullable NSString *)label style:(SNInlineStyle)style to:(SNInlineText *)text;
- (void)noteEmoji:(NSString *)name;
- (void)appendUser:(NSString *)userID label:(nullable NSString *)label to:(SNInlineText *)text;
- (void)appendChannel:(NSString *)channelID label:(nullable NSString *)label style:(SNInlineStyle)style to:(SNInlineText *)text;
- (void)appendUsergroup:(NSString *)groupID label:(nullable NSString *)label to:(SNInlineText *)text;
- (void)appendBroadcast:(NSString *)range to:(SNInlineText *)text;
- (void)appendDate:(NSTimeInterval)timestamp format:(nullable NSString *)format link:(nullable NSString *)link fallback:(nullable NSString *)fallback
             style:(SNInlineStyle)style
                to:(SNInlineText *)text;
@end

@implementation SNRenderer {
    NSDate *_now;
    /// What the documents show for each ID or emoji name they used, to tell when they go stale.
    NSMutableDictionary<NSString *, NSString *> *_users, *_bots, *_usergroups, *_channels, *_emoji;
    /// The Preferences' "Underline links to websites" (underline_links) the documents were made with.
    BOOL _underlinesLinks;
    /// The inline media preferences they were made with.
    NSString *_mediaPreferences;
    /// The message being rendered and its column's view context, which key its collapsible
    /// pictures; nil outside documentForMessage:.
    NSString *_messageTS, *_viewContext;
}

- (instancetype)initWithSource:(id<SNSource>)source {
    if (!(self = [super init])) return nil;
    _source = source;
    _users = [NSMutableDictionary new];
    _bots = [NSMutableDictionary new];
    _usergroups = [NSMutableDictionary new];
    _channels = [NSMutableDictionary new];
    _emoji = [NSMutableDictionary new];
    _underlinesLinks = SNPreferenceBool(source.preferences, @"underline_links", NO);
    _mediaPreferences = MediaPreferences(source.preferences);
    return self;
}

/// A link to a website, underlined when the reader asked for it.
- (void)appendWebLink:(NSURL *)url text:(NSString *)label style:(SNInlineStyle)style to:(SNInlineText *)text {
    [text appendLink:url text:label style:style | (_underlinesLinks ? SNInlineUnderline : 0)];
}

- (NSDate *)now { return _now ?: NSDate.date; }
- (void)setNow:(NSDate *)now { _now = now; }

#pragma mark Names

- (NSString *)nameOfUser:(NSString *)userID fallback:(NSString *)fallback {
    NSString *name = [self.source userWithID:userID].visibleName ?: fallback ?: userID;
    _users[userID] = name;
    return name;
}

- (NSString *)senderOfMessage:(SNMessage *)message {
    if (message.userID) return [self nameOfUser:message.userID fallback:message.username];
    if (message.username.length || !message.botID) return message.username ?: @"";
    NSString *name = [self.source botWithID:message.botID].name ?: @"";
    _bots[message.botID] = name;
    return name;
}

/// A shown name is stale when the source now knows a different one; one it still lacks keeps
/// the fallback that was shown.
static BOOL Renamed(NSDictionary<NSString *, NSString *> *shown, NSSet<NSString *> *changed, NSString * (^current)(NSString *ID)) {
    for (NSString *ID in changed) {
        NSString *was = shown[ID], *now = was ? current(ID) : nil;
        if (now && ![now isEqualToString:was]) return YES;
    }
    return NO;
}

- (BOOL)isStaleAfterChange:(SNChange *)change {
    id<SNSource> source = self.source;
    BOOL stale = Renamed(_users, change.users, ^NSString *(NSString *ID) { return [source userWithID:ID].visibleName; }) ||
                 Renamed(_bots, change.users, ^NSString *(NSString *ID) { return [source botWithID:ID].name; }) ||
                 Renamed(_usergroups, change.usergroups, ^NSString *(NSString *ID) { return [source usergroupHandleWithID:ID]; }) ||
                 Renamed(_channels, change.conversations, ^NSString *(NSString *ID) { return [source conversationWithID:ID].name; });
    if (!stale && change.emoji)
        for (NSString *name in _emoji)
            if (![EmojiForm(name) isEqualToString:_emoji[name]]) {
                stale = YES;
                break;
            }
    // A VIP's name has its badge.
    if (change.vips) stale = YES;
    BOOL underlines = SNPreferenceBool(source.preferences, @"underline_links", NO);
    if (change.preferences && underlines != _underlinesLinks) {
        _underlinesLinks = underlines;
        stale = YES;
    }
    NSString *media = MediaPreferences(source.preferences);
    if (change.preferences && ![media isEqualToString:_mediaPreferences ?: @""]) {
        _mediaPreferences = media;
        stale = YES;
    }
    // Dates inside messages (<!date^...>) and every time beside them.
    if (change.timeZone) stale = YES;
    if (stale)
        for (NSMutableDictionary *shown in @[ _users, _bots, _usergroups, _channels, _emoji ]) [shown removeAllObjects];
    return stale;
}

/// Standard names never change; the workspace's emoji and unknown names may.
- (void)noteEmoji:(NSString *)name {
    if (!SNEmojiNamed(name)) _emoji[name] = EmojiForm(name);
}

- (void)appendUser:(NSString *)userID label:(NSString *)label to:(SNInlineText *)text {
    NSString *name = [self nameOfUser:userID fallback:label];
    if (![name hasPrefix:@"@"]) name = [@"@" stringByAppendingString:name];
    [text appendMention:name target:[SNRenderTarget targetWithKind:SNRenderTargetUser value:userID] own:[userID isEqualToString:self.source.me.userID]];
}

- (void)appendChannel:(NSString *)channelID label:(NSString *)label style:(SNInlineStyle)style to:(SNInlineText *)text {
    NSString *name = [self.source conversationWithID:channelID].name ?: label ?: channelID;
    _channels[channelID] = name;
    [text appendText:[@"#" stringByAppendingString:name] style:style target:[SNRenderTarget targetWithKind:SNRenderTargetChannel value:channelID]];
}

- (void)appendUsergroup:(NSString *)groupID label:(NSString *)label to:(SNInlineText *)text {
    NSString *name = [self.source usergroupHandleWithID:groupID] ?: (label.length ? label : groupID);
    _usergroups[groupID] = name;
    if (![name hasPrefix:@"@"]) name = [@"@" stringByAppendingString:name];
    [text appendMention:name target:[SNRenderTarget targetWithKind:SNRenderTargetUsergroup value:groupID] own:NO];
}

- (void)appendBroadcast:(NSString *)range to:(SNInlineText *)text {
    [text appendMention:[@"@" stringByAppendingString:range] target:[SNRenderTarget targetWithKind:SNRenderTargetBroadcast value:range] own:YES];
}

- (void)appendDate:(NSTimeInterval)timestamp format:(NSString *)format link:(NSString *)link fallback:(NSString *)fallback
             style:(SNInlineStyle)style
                to:(SNInlineText *)text {
    NSString *shown = format.length && timestamp > 0 ? SNFormatSlackDate(timestamp, format, self.now) : fallback ?: @"";
    NSURL *url = link.length ? [NSURL URLWithString:link] : nil;
    if (url) [self appendWebLink:url text:shown style:style to:text];
    else [text appendText:shown style:style];
}

#pragma mark rich_text

static BOOL IsEmojiOnly(NSArray *elements) {
    NSUInteger emoji = 0;
    for (NSDictionary *element in elements) {
        if (![SNJSONString(element, @"type") isEqualToString:@"rich_text_section"]) return NO;
        for (NSDictionary *inline_ in SNJSONArray(element, @"elements") ?: @[]) {
            NSString *type = SNJSONString(inline_, @"type");
            if ([type isEqualToString:@"emoji"]) emoji++;
            else if (![type isEqualToString:@"text"] || [SNJSONString(inline_, @"text") stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length) return NO;
        }
    }
    return emoji > 0 && emoji <= kJumboLimit;
}

/// Bullets by nesting level: Slack's disc, circle and square glyphs.
static NSString *BulletMarker(NSInteger indent) { return @[ @"•", @"◦", @"▪" ][(NSUInteger)(indent % 3)]; }

static NSString *Roman(NSInteger number) {
    static const int values[] = {1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1};
    static NSString *const symbols[] = {@"m", @"cm", @"d", @"cd", @"c", @"xc", @"l", @"xl", @"x", @"ix", @"v", @"iv", @"i"};
    NSMutableString *text = [NSMutableString new];
    for (int i = 0; i < 13; i++)
        while (number >= values[i]) [text appendString:symbols[i]], number -= values[i];
    return text;
}

/// Ordered lists cycle decimal, lower-alpha and lower-roman by nesting level.
static NSString *NumberMarker(NSInteger number, NSInteger indent) {
    switch (indent % 3) {
    case 1: {
        NSMutableString *letters = [NSMutableString new];
        for (NSInteger n = number; n > 0; n = (n - 1) / 26) [letters insertString:[NSString stringWithFormat:@"%c", (char)('a' + (n - 1) % 26)] atIndex:0];
        return [letters stringByAppendingString:@"."];
    }
    case 2: return [Roman(number) stringByAppendingString:@"."];
    default: return [NSString stringWithFormat:@"%ld.", (long)number];
    }
}

- (SNDocumentSink *)sinkWithStyle:(SNTextStyle)style {
    SNDocumentSink *sink = [SNDocumentSink new];
    sink->_renderer = self;
    sink->_style = style;
    sink->_blocks = [NSMutableArray new];
    return sink;
}

- (SNDocumentSink *)sinkInto:(SNInlineText *)text {
    SNDocumentSink *sink = [SNDocumentSink new];
    sink->_renderer = self;
    sink->_text = text;
    return sink;
}

- (NSArray<SNRenderBlock *> *)blocksForRichText:(NSDictionary *)block {
    NSArray *elements = SNJSONArray(block, @"elements") ?: @[];
    NSDictionary *only = elements.count == 1 ? elements.firstObject : nil;
    NSArray *onlyInline = SNJSONArray(only, @"elements");
    if ([SNJSONString(only, @"type") isEqualToString:@"rich_text_section"] && onlyInline.count == 1 &&
        [SNJSONString(onlyInline.firstObject, @"type") isEqualToString:@"link"] && !SNJSONString(onlyInline.firstObject, @"text").length) {
        // A message that is only a bare link shows it as a chip.
        NSURL *url = [NSURL URLWithString:SNJSONString(onlyInline.firstObject, @"url") ?: @""];
        if (url) {
            SNInlineText *text = [[SNInlineText alloc] initWithStyle:SNTextStyleBody];
            [text appendLinkChip:url];
            return @[ text.paragraph ];
        }
    }
    SNDocumentSink *sink = [self sinkWithStyle:SNTextStyleBody];
    sink->_jumbo = IsEmojiOnly(elements);
    SNWalkRichText(elements, sink);
    return [sink finish];
}

#pragma mark mrkdwn

- (void)appendMrkdwn:(NSString *)source style:(SNInlineStyle)style to:(SNInlineText *)text {
    SNWalkMrkdwnInline(source, style, [self sinkInto:text]);
}

- (SNParagraphBlock *)paragraphForMrkdwn:(NSString *)source style:(SNTextStyle)style inline:(SNInlineStyle)inlineStyle {
    SNInlineText *text = [[SNInlineText alloc] initWithStyle:style];
    [self appendMrkdwn:source style:inlineStyle to:text];
    return text.paragraph;
}

- (NSArray<SNRenderBlock *> *)blocksForMrkdwn:(NSString *)source style:(SNTextStyle)style {
    return [self blocksForMrkdwn:source style:style inline:0];
}

- (NSArray<SNRenderBlock *> *)blocksForMrkdwn:(NSString *)source style:(SNTextStyle)style inline:(SNInlineStyle)inlineStyle {
    SNDocumentSink *sink = [self sinkWithStyle:style];
    SNWalkMrkdwn(source, inlineStyle, sink);
    return [sink finish];
}

#pragma mark Block Kit

/// A Block Kit text object: mrkdwn is parsed, plain_text shown as it is.
- (SNParagraphBlock *)paragraphForTextObject:(NSDictionary *)object style:(SNTextStyle)style {
    NSString *source = SNJSONString(object, @"text") ?: @"";
    if ([SNJSONString(object, @"type") isEqualToString:@"mrkdwn"]) return [self paragraphForMrkdwn:source style:style inline:0];
    SNInlineText *text = [[SNInlineText alloc] initWithStyle:style];
    [text appendText:source style:0];
    return text.paragraph;
}

- (NSArray<SNRenderBlock *> *)blocksForTextObject:(NSDictionary *)object style:(SNTextStyle)style {
    if ([SNJSONString(object, @"type") isEqualToString:@"mrkdwn"]) return [self blocksForMrkdwn:SNJSONString(object, @"text") ?: @"" style:style];
    return @[ [self paragraphForTextObject:object style:style] ];
}

- (NSArray<SNRenderBlock *> *)blocksForBlockKit:(NSArray<NSDictionary *> *)source {
    NSMutableArray<SNRenderBlock *> *blocks = [NSMutableArray new];
    for (NSDictionary *block in source) {
        if (![block isKindOfClass:NSDictionary.class]) continue;
        NSString *type = SNJSONString(block, @"type");
        if ([type isEqualToString:@"rich_text"]) {
            [blocks addObjectsFromArray:[self blocksForRichText:block]];
        } else if ([type isEqualToString:@"section"]) {
            NSMutableArray<SNRenderBlock *> *section = [NSMutableArray new];
            NSDictionary *text = SNJSONObject(block, @"text");
            if (text) [section addObjectsFromArray:[self blocksForTextObject:text style:SNTextStyleBody]];
            NSMutableArray<SNParagraphBlock *> *fields = [NSMutableArray new];
            for (NSDictionary *field in SNJSONArray(block, @"fields") ?: @[]) [fields addObject:[self paragraphForTextObject:field style:SNTextStyleBody]];
            if (fields.count) [section addObject:[SNColumnsBlock columnsWithCells:fields]];
            NSDictionary *accessory = SNJSONObject(block, @"accessory");
            NSURL *image = [SNJSONString(accessory, @"type") isEqualToString:@"image"] ? SNJSONURL(accessory, @"image_url") : nil;
            if (image && _messageTS && !SNMediaIsExpanded(SNExpandableBlockImageKey(_messageTS, SNJSONString(block, @"block_id") ?: @"undefined"), 0, self.source)) image = nil;
            if (image) {
                SNGroupBlock *group = [SNGroupBlock sectionWithBlocks:section];
                group.sideImage = image;
                group.sideImageSize = 88;
                [blocks addObject:group];
            } else {
                [blocks addObjectsFromArray:section];
            }
            NSArray<SNButtonItem *> *buttons = [self buttonsFor:accessory ? @[ accessory ] : @[]];
            if (buttons.count) [blocks addObject:[SNButtonsBlock buttonsWithItems:buttons]];
        } else if ([type isEqualToString:@"header"]) {
            SNParagraphBlock *header = [self paragraphForTextObject:SNJSONObject(block, @"text") style:kHeaderStyle];
            header.spaceBefore = 8;
            [blocks addObject:header];
        } else if ([type isEqualToString:@"context"]) {
            SNInlineText *text = [[SNInlineText alloc] initWithStyle:kContextStyle];
            for (NSDictionary *element in SNJSONArray(block, @"elements") ?: @[]) {
                if (text.length) [text appendText:@" " style:0];
                NSURL *image = SNJSONURL(element, @"image_url");
                if (image) [text appendImage:image size:20 radius:SNRadiusBase];
                else if ([SNJSONString(element, @"type") isEqualToString:@"mrkdwn"]) [self appendMrkdwn:SNJSONString(element, @"text") ?: @"" style:0 to:text];
                else [text appendText:SNJSONString(element, @"text") ?: @"" style:0];
            }
            SNParagraphBlock *context = text.paragraph;
            context.spaceBefore = 4;
            [blocks addObject:context];
        } else if ([type isEqualToString:@"image"]) {
            NSDictionary *title = SNJSONObject(block, @"title");
            NSURL *url = SNJSONURL(block, @"image_url");
            if (!_messageTS) {
                if (title) [blocks addObject:[self paragraphForTextObject:title style:kContextStyle]];
                if (url) [blocks addObject:[SNImageBlock imageWithURL:url size:CGSizeMake(SNJSONDouble(block, @"image_width"), SNJSONDouble(block, @"image_height"))]];
                continue;
            }
            // ImageBlock: the title, the size and the caret that collapses the picture above it.
            NSString *key = SNExpandableBlockImageKey(_messageTS, SNJSONString(block, @"block_id") ?: @"undefined");
            long long bytes = (long long)SNJSONDouble(block, @"image_bytes");
            BOOL expanded = SNMediaIsExpanded(key, bytes, self.source);
            SNInlineText *line = [[SNInlineText alloc] initWithStyle:kContextStyle];
            if (title) [line appendText:SNMrkdwnDecode(SNJSONString(title, @"text") ?: @"") style:0];
            if (bytes > 0) [line appendText:[NSString stringWithFormat:@" (%@)", SNFormatFileSize(bytes)] style:0];
            [line appendText:@" " style:0];
            [line appendIcon:expanded ? @"caret-down-filled" : @"caret-right-filled" size:SNFontSizeBase color:SNColorContentHgl1
                      target:[SNRenderTarget targetWithKind:expanded ? SNRenderTargetCollapse : SNRenderTargetExpand value:key]];
            [blocks addObject:line.paragraph];
            if (url && expanded) [blocks addObject:[SNImageBlock imageWithURL:url size:CGSizeMake(SNJSONDouble(block, @"image_width"), SNJSONDouble(block, @"image_height"))]];
        } else if ([type isEqualToString:@"actions"]) {
            NSArray<SNButtonItem *> *buttons = [self buttonsFor:SNJSONArray(block, @"elements") ?: @[]];
            if (buttons.count) [blocks addObject:[SNButtonsBlock buttonsWithItems:buttons]];
        } else if ([type isEqualToString:@"divider"]) {
            [blocks addObject:[SNDividerBlock new]];
        } else if ([type isEqualToString:@"table"]) {
            [blocks addObject:[self tableFor:block]];
        } else if ([type isEqualToString:@"call"]) {
            [blocks addObjectsFromArray:[self callBlocks:block]];
        }
    }
    return blocks;
}

/// A call block (PlatformCallSubtype, a call from an app such as Zoom): "Call", then a card with
/// the call's title and status, its people's faces, how many joined and Join while it goes on.
- (NSArray<SNRenderBlock *> *)callBlocks:(NSDictionary *)block {
    NSDictionary *call = SNJSONObject(SNJSONObject(block, @"call"), @"v1") ?: SNJSONObject(block, @"call");
    if (!call) return @[];
    NSTimeInterval start = SNJSONDouble(call, @"date_start"), end = SNJSONDouble(call, @"date_end");
    BOOL ended = end > 0;
    NSArray *people = SNJSONArray(call, ended ? @"all_participants" : @"active_participants") ?: @[];
    SNInlineText *label = [[SNInlineText alloc] initWithStyle:kSystemStyle];
    [label appendText:SNLocalized(@"render.call") style:0];
    SNInlineText *title = [[SNInlineText alloc] initWithStyle:SNTextStyleBody];
    // .p-call_subtype__icon: the call glyph on #0b4c8c, grey once the call ended.
    [title appendIcon:@"call" size:20 color:ended ? 0x868686ff : 0x1d9bd1ff target:nil];
    [title appendText:@" " style:0];
    NSString *name = SNJSONString(call, @"name");
    [title appendText:name.length ? name : SNLocalized(ended ? @"render.call.ended" : @"render.call.started") style:SNInlineBold];
    SNInlineText *status = [[SNInlineText alloc] initWithStyle:SNTextStyleBody];
    NSInteger minutes = (NSInteger)floor(((ended ? end : self.now.timeIntervalSince1970) - start) / 60);
    NSString *lasted = minutes >= 60 ? SNLocalizedFormat(@"render.call.hours", @(minutes / 60).stringValue, @(minutes % 60).stringValue)
                                     : SNLocalizedFormat(minutes == 1 ? @"render.call.minute" : @"render.call.minutes", @(minutes).stringValue);
    if (ended) [status appendText:SNLocalizedFormat(@"render.call.lasted", SNFormatSlackDate(end, @"{time}", self.now), lasted) style:0];
    else [status appendText:minutes > 0 ? SNLocalizedFormat(@"render.call.since", lasted) : SNLocalized(@"render.call.now") style:0];
    NSMutableArray<SNRenderBlock *> *inside = [NSMutableArray arrayWithArray:@[ title.paragraph, status.paragraph ]];
    SNInlineText *footer = [[SNInlineText alloc] initWithStyle:kSystemStyle];
    NSUInteger faces = 0;
    for (NSDictionary *person in people) {
        if (faces == 5 || ![person isKindOfClass:NSDictionary.class]) break;
        NSString *userID = SNJSONString(person, @"slack_id");
        NSURL *avatar = userID ? [[self.source userWithID:userID] avatarURLForPixels:72] : SNJSONURL(person, @"avatar_url");
        if (!avatar) continue;
        [footer appendImage:avatar size:36 radius:SNRadiusIaIcon(36)];
        [footer appendText:@" " style:0];
        faces++;
    }
    NSString *description = ended ? SNLocalizedFormat(people.count == 1 ? @"render.call.joined.1" : @"render.call.joined", @(people.count).stringValue)
                          : people.count == 0 ? SNLocalized(@"render.call.waiting") : people.count == 1 ? SNLocalized(@"render.call.waiting.others") : nil;
    if (description) [footer appendText:description style:0];
    if (faces || description) [inside addObject:footer.paragraph];
    NSString *join = SNJSONString(call, @"join_url");
    if (!ended && join.length)
        [inside addObject:[SNButtonsBlock buttonsWithItems:@[ [SNButtonItem buttonWithTitle:SNLocalized(@"render.call.join") style:SNButtonStylePrimary
                                                                                   target:[SNRenderTarget targetWithKind:SNRenderTargetLink value:join]] ]]];
    SNGroupBlock *card = [SNGroupBlock cardWithBlocks:inside];
    card.maximumWidth = 440;
    return @[ label.paragraph, card ];
}

/// Buttons as buttons; selects, overflow menus and pickers as a button with their placeholder.
- (NSArray<SNButtonItem *> *)buttonsFor:(NSArray<NSDictionary *> *)elements {
    NSMutableArray<SNButtonItem *> *items = [NSMutableArray new];
    for (NSDictionary *element in elements) {
        NSString *type = SNJSONString(element, @"type");
        if ([type isEqualToString:@"image"]) continue;
        NSString *title = SNJSONString(SNJSONObject(element, @"text"), @"text") ?: SNJSONString(SNJSONObject(element, @"placeholder"), @"text");
        if ([type isEqualToString:@"overflow"]) title = @"⋯";
        if (!title.length) continue;
        NSString *style = SNJSONString(element, @"style");
        NSString *value = SNJSONString(element, @"url") ?: SNJSONString(element, @"action_id") ?: title;
        [items addObject:[SNButtonItem buttonWithTitle:title
                                                 style:[style isEqualToString:@"primary"] ? SNButtonStylePrimary : [style isEqualToString:@"danger"] ? SNButtonStyleDanger : SNButtonStyleDefault
                                                target:[SNRenderTarget targetWithKind:SNRenderTargetButton value:value]]];
    }
    return items;
}

- (SNTableBlock *)tableFor:(NSDictionary *)block {
    NSMutableArray<NSArray<NSAttributedString *> *> *rows = [NSMutableArray new];
    for (NSArray *row in SNJSONArray(block, @"rows") ?: @[]) {
        if (![row isKindOfClass:NSArray.class]) continue;
        NSMutableArray<NSAttributedString *> *cells = [NSMutableArray new];
        for (NSDictionary *cell in row) {
            SNInlineText *text = [[SNInlineText alloc] initWithStyle:SNTextStyleBody];
            SNInlineStyle header = rows.count == 0 ? SNInlineBold : 0;
            if ([SNJSONString(cell, @"type") isEqualToString:@"rich_text"]) {
                for (NSDictionary *section in SNJSONArray(cell, @"elements") ?: @[]) SNWalkRichInline(SNJSONArray(section, @"elements") ?: @[], 0, [self sinkInto:text]);
            } else {
                [text appendText:SNJSONString(cell, @"text") ?: @"" style:header];
            }
            [cells addObject:text.attributedText];
        }
        [rows addObject:cells];
    }
    return [SNTableBlock tableWithRows:rows];
}

#pragma mark Attachments

/// Attachment bodies set text on 22.5 pt lines (line-height 1.5), not the message's 22.
static NSArray<SNRenderBlock *> *OnAttachmentLines(NSArray<SNRenderBlock *> *blocks) {
    NSMutableArray<SNRenderBlock *> *result = [NSMutableArray new];
    for (SNRenderBlock *block in blocks) {
        SNParagraphBlock *paragraph = [block isKindOfClass:SNParagraphBlock.class] ? (SNParagraphBlock *)block : nil;
        if (!paragraph || paragraph.style.lineHeight != SNTextStyleBody.lineHeight) {
            [result addObject:block];
            continue;
        }
        SNTextStyle style = paragraph.style;
        style.lineHeight = 22.5;
        SNParagraphBlock *copy = [SNParagraphBlock paragraphWithText:paragraph.text style:style];
        copy.indent = paragraph.indent, copy.marker = paragraph.marker, copy.spaceBefore = paragraph.spaceBefore, copy.spaceAfter = paragraph.spaceAfter;
        [result addObject:copy];
    }
    return result;
}

- (NSArray<SNRenderBlock *> *)blocksForAttachments:(NSArray<NSDictionary *> *)attachments {
    NSMutableArray<SNRenderBlock *> *blocks = [NSMutableArray new];
    for (NSDictionary *attachment in attachments) {
        if (![attachment isKindOfClass:NSDictionary.class]) continue;
        NSString *pretext = SNJSONString(attachment, @"pretext");
        if (pretext.length) [blocks addObjectsFromArray:[self blocksForMrkdwn:pretext style:SNTextStyleBody]];
        NSArray *shared = SNJSONArray(attachment, @"message_blocks");
        if (SNJSONBool(attachment, @"is_share") || SNJSONBool(attachment, @"is_msg_unfurl") || shared.count) {
            [blocks addObject:[self sharedMessage:attachment]];
            continue;
        }
        NSMutableArray<SNRenderBlock *> *inside = [NSMutableArray new];
        SNParagraphBlock *author = [self authorRow:attachment];
        if (author) [inside addObject:author];
        NSString *title = SNJSONString(attachment, @"title");
        if (title.length) {
            SNInlineText *text = [[SNInlineText alloc] initWithStyle:SNTextStyleBody];
            NSURL *link = SNJSONURL(attachment, @"title_link");
            if (link) [text appendLink:link text:SNMrkdwnDecode(title) style:SNInlineBold];
            else [text appendText:SNMrkdwnDecode(title) style:SNInlineBold];
            [inside addObject:text.paragraph];
        }
        NSString *body = SNJSONString(attachment, @"text");
        if (body.length) [inside addObjectsFromArray:[self blocksForMrkdwn:body style:SNTextStyleBody]];
        NSArray *kit = SNJSONArray(attachment, @"blocks");
        if (kit.count) [inside addObjectsFromArray:[self blocksForBlockKit:kit]];
        NSMutableArray<SNParagraphBlock *> *fields = [NSMutableArray new];
        for (NSDictionary *field in SNJSONArray(attachment, @"fields") ?: @[]) {
            SNInlineText *text = [[SNInlineText alloc] initWithStyle:SNTextStyleBody];
            [text appendText:SNJSONString(field, @"title") ?: @"" style:SNInlineBold];
            [text appendText:@"\n" style:0];
            [self appendMrkdwn:SNJSONString(field, @"value") ?: @"" style:0 to:text];
            [fields addObject:text.paragraph];
        }
        if (fields.count) [inside addObject:[SNColumnsBlock columnsWithCells:fields]];
        NSURL *image = SNJSONURL(attachment, @"image_url");
        NSString *key = _messageTS ? SNExpandableAttachmentKey(attachment, _messageTS, _viewContext) : nil;
        // Collapsed (Hide image, /collapse), the preview keeps its words and loses its picture.
        if (key && !SNMediaIsExpanded(key, (long long)SNJSONDouble(attachment, @"image_bytes"), self.source)) image = nil;
        if (image) {
            SNImageBlock *picture = [SNImageBlock imageWithURL:image size:CGSizeMake(SNJSONDouble(attachment, @"image_width"), SNJSONDouble(attachment, @"image_height"))];
            picture.hideKey = key;
            [inside addObject:picture];
        }
        SNParagraphBlock *footer = [self footer:attachment];
        if (footer) [inside addObject:footer];
        if (!inside.count) continue;
        SNGroupBlock *group = [SNGroupBlock attachmentWithBlocks:OnAttachmentLines(inside) barColor:BarColor(SNJSONString(attachment, @"color"))];
        group.sideImage = SNJSONURL(attachment, @"thumb_url");
        [blocks addObject:group];
    }
    return blocks;
}

/// The author or service line: a 16 pt icon and the name in bold white.
- (SNParagraphBlock *)authorRow:(NSDictionary *)attachment {
    NSString *name = SNJSONString(attachment, @"author_name") ?: SNJSONString(attachment, @"service_name");
    if (!name.length) return nil;
    SNInlineText *text = [[SNInlineText alloc] initWithStyle:(SNTextStyle){SNFontSizeBase, SNFontWeightBlack, 22, SNColorContentPry}];
    NSURL *icon = SNJSONURL(attachment, @"author_icon") ?: SNJSONURL(attachment, @"service_icon");
    if (icon) {
        [text appendImage:icon size:16 radius:SNRadiusSmall];
        [text appendText:@"  " style:0];
    }
    [text appendText:SNMrkdwnDecode(name) style:0];
    return text.paragraph;
}

- (SNParagraphBlock *)footer:(NSDictionary *)attachment {
    NSString *footer = SNJSONString(attachment, @"footer");
    NSTimeInterval ts = SNJSONDouble(attachment, @"ts");
    if (!footer.length && ts <= 0) return nil;
    SNInlineText *text = [[SNInlineText alloc] initWithStyle:kFooterStyle];
    NSURL *icon = SNJSONURL(attachment, @"footer_icon");
    if (icon) {
        [text appendImage:icon size:16 radius:SNRadiusSmall];
        [text appendText:@" " style:0];
    }
    if (footer.length) [self appendMrkdwn:footer style:0 to:text];
    if (ts > 0) {
        if (footer.length) [text appendText:@" | " style:0];
        [text appendText:SNFormatSlackDate(ts, @"{date_short_pretty}", self.now) style:0];
    }
    SNParagraphBlock *paragraph = text.paragraph;
    paragraph.spaceBefore = 4;
    return paragraph;
}

/// A shared or unfurled message: a bordered card with its author and its blocks; the card ends
/// with the message's text (measured on the captures).
- (SNRenderBlock *)sharedMessage:(NSDictionary *)attachment {
    NSMutableArray<SNRenderBlock *> *inside = [NSMutableArray new];
    SNParagraphBlock *author = [self authorRow:attachment];
    if (author) [inside addObject:author];
    // Unfurls of a message link carry its blocks in message_blocks; shares and forwards in blocks.
    NSArray *messageBlocks = SNJSONArray(SNJSONObject(SNJSONArray(attachment, @"message_blocks").firstObject, @"message"), @"blocks") ?: SNJSONArray(attachment, @"blocks");
    if (messageBlocks.count) [inside addObjectsFromArray:[self blocksForBlockKit:messageBlocks]];
    else if (SNJSONString(attachment, @"text").length) [inside addObjectsFromArray:[self blocksForMrkdwn:SNJSONString(attachment, @"text") style:SNTextStyleBody]];
    return [SNGroupBlock cardWithBlocks:OnAttachmentLines(inside)];
}

#pragma mark Messages

/// Slack words what happened to the conversation in the reader's language, from the event's
/// fields; "text" holds an English sentence.
- (nullable SNRenderDocument *)systemDocumentForMessage:(SNMessage *)message {
    NSString *subtype = message.subtype ?: @"";
    NSDictionary *json = message.json;
    NSString *key = @{@"channel_join" : @"render.joined", @"group_join" : @"render.joined", @"channel_leave" : @"render.left", @"group_leave" : @"render.left",
                      @"channel_purpose" : @"render.purpose", @"group_purpose" : @"render.purpose", @"channel_topic" : @"render.topic",
                      @"group_topic" : @"render.topic", @"channel_name" : @"render.renamed", @"group_name" : @"render.renamed",
                      @"channel_archive" : @"render.archived", @"group_archive" : @"render.archived", @"channel_unarchive" : @"render.unarchived",
                      @"group_unarchive" : @"render.unarchived", @"bot_add" : @"render.bot.added", @"bot_remove" : @"render.bot.removed",
                      @"tombstone" : @"render.deleted", @"huddle_thread" : @"render.huddle"}[subtype];
    if (!key) return nil;
    SNInlineText *text = [[SNInlineText alloc] initWithStyle:kSystemStyle];
    if ([subtype hasSuffix:@"_name"]) {
        [text appendText:SNLocalizedFormat(key, SNJSONString(json, @"old_name") ?: @"", SNJSONString(json, @"name") ?: @"") style:0];
        return [SNRenderDocument documentWithBlocks:@[ text.paragraph ]];
    }
    if ([subtype isEqualToString:@"huddle_thread"]) return [self huddleDocumentForMessage:message];
    [text appendText:SNLocalized(key) style:0];
    NSString *detail = [subtype hasSuffix:@"_purpose"] ? SNJSONString(json, @"purpose") : [subtype hasSuffix:@"_topic"] ? SNJSONString(json, @"topic")
                     : [subtype hasPrefix:@"bot_"] ? SNJSONString(json, @"bot_link") : nil;
    if (detail.length) {
        [text appendText:@" " style:0];
        [self appendMrkdwn:detail style:0 to:text];
    }
    return [SNRenderDocument documentWithBlocks:@[ text.paragraph ]];
}

#pragma mark Huddles

- (SNHuddle *)huddleOfMessage:(SNMessage *)message {
    SNHuddle *own = [SNHuddle huddleWithJSON:SNJSONObject(message.json, @"room") ?: @{}];
    SNHuddle *live = message.conversationID ? [self.source huddleInConversation:message.conversationID] : nil;
    return live && [live.identifier isEqualToString:own.identifier] ? live : own;
}

- (NSString *)huddleStatusOfMessage:(SNMessage *)message {
    SNHuddle *huddle = [self huddleOfMessage:message];
    NSString *name = [huddle.name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (name.length) return SNLocalizedFormat(huddle.isActive ? @"render.huddle.named" : @"render.huddle.named.ended", name);
    return SNLocalized(huddle.isActive ? @"render.huddle" : @"render.huddle.ended");
}

/// The huddle duration component: "{hours}h {minutes}m" or "{minutes}m".
static NSString *HuddleDuration(SNHuddle *huddle) {
    NSInteger minutes = (NSInteger)floor(MAX(0, huddle.dateEnd - huddle.dateStart) / 60);
    if (minutes >= 60) return SNLocalizedFormat(@"render.huddle.hours", @(minutes / 60).stringValue, @(minutes % 60).stringValue);
    return SNLocalizedFormat(@"render.huddle.minutes", @(minutes).stringValue);
}

/// The plural forms of Slack's participant sentences: one name, two names, or the first name and
/// how many others; `prefix` picks the sentence ("render.huddle.there").
- (NSString *)people:(NSArray<NSString *> *)userIDs sentence:(NSString *)prefix duration:(nullable NSString *)duration {
    NSString *first = [self nameOfUser:userIDs[0] fallback:nil];
    NSString *second = userIDs.count == 2 ? [self nameOfUser:userIDs[1] fallback:nil] : @(userIDs.count - 1).stringValue;
    if (userIDs.count == 1) return SNLocalizedFormat([prefix stringByAppendingString:@".1"], first, duration ?: @"");
    return SNLocalizedFormat([prefix stringByAppendingString:userIDs.count == 2 ? @".2" : @".n"], first, second, duration ?: @"");
}

/// HuddleMsgText's body (getHuddleMsgText), worded from the user's side: who is already there or
/// here too, or who was in it and for how long. A DM's huddle says nothing while it goes on
/// without the user.
- (SNRenderDocument *)huddleDocumentForMessage:(SNMessage *)message {
    SNHuddle *huddle = [self huddleOfMessage:message];
    NSString *me = self.source.me.userID ?: @"";
    NSPredicate *others = [NSPredicate predicateWithFormat:@"SELF != %@", me];
    NSArray<NSString *> *active = [huddle.participantIDs filteredArrayUsingPredicate:others], *all = [huddle.historyIDs filteredArrayUsingPredicate:others];
    BOOL live = huddle.isActive, inIt = [huddle.participantIDs containsObject:me], wasIn = [huddle.historyIDs containsObject:me];
    SNConversationKind kind = [self.source conversationWithID:message.conversationID ?: @""].kind;
    BOOL direct = kind == SNConversationDirect || kind == SNConversationGroupDirect;
    NSString *sentence = nil;
    if (live && !inIt) sentence = !direct && active.count ? [self people:active sentence:@"render.huddle.there" duration:nil] : nil;
    else if (live) sentence = active.count ? [self people:active sentence:@"render.huddle.too" duration:nil] : SNLocalized(@"render.huddle.alone");
    else if (wasIn && !all.count) sentence = SNLocalizedFormat(@"render.huddle.yours.alone", HuddleDuration(huddle));
    else if (all.count) sentence = [self people:all sentence:wasIn ? @"render.huddle.yours" : @"render.huddle.was" duration:HuddleDuration(huddle)];
    if (!sentence) return [SNRenderDocument documentWithBlocks:@[]];
    SNInlineText *text = [[SNInlineText alloc] initWithStyle:kSystemStyle];
    [text appendText:sentence style:0];
    if (!live && wasIn && !all.count) {
        [text appendText:@" " style:0];
        [text appendEmoji:@"tea" fallbackUnicode:nil];
    }
    return [SNRenderDocument documentWithBlocks:@[ text.paragraph ]];
}

- (SNRenderDocument *)documentForMessage:(SNMessage *)message { return [self documentForMessage:message inThread:NO]; }

- (SNRenderDocument *)previewOfMessage:(SNMessage *)message style:(SNTextStyle)style prefix:(NSString *)prefix {
    SNInlineText *text = [[SNInlineText alloc] initWithStyle:style];
    if (prefix) [text appendText:prefix style:0];
    SNDocumentSink *sink = [self sinkInto:text];
    sink->_flat = YES;
    NSUInteger start = sink->_start = text.length;
    SNWalkRichTextBlocks(message.blocks, sink);
    if (text.length == start && message.text.length) SNWalkMrkdwn(message.text, 0, sink);
    if (text.length == start && message.files.count) [text appendText:message.files.firstObject.title ?: message.files.firstObject.name style:0];
    return [SNRenderDocument documentWithBlocks:@[ text.paragraph ]];
}

- (SNRenderDocument *)documentForMessage:(SNMessage *)message inThread:(BOOL)inThread {
    SNRenderDocument *system = [self systemDocumentForMessage:message];
    if (system) return system;
    _messageTS = message.ts;
    _viewContext = inThread ? SNViewContextThread : SNViewContextChannel;
    SNRenderDocument *document = [self bodyOfMessage:message inThread:inThread];
    _messageTS = _viewContext = nil;
    return document;
}

- (SNRenderDocument *)bodyOfMessage:(SNMessage *)message inThread:(BOOL)inThread {
    NSMutableArray<SNRenderBlock *> *blocks = [NSMutableArray new];
    NSString *subtype = message.subtype;
    if ([subtype isEqualToString:@"thread_broadcast"]) {
        if (inThread) {
            SNInlineText *text = [[SNInlineText alloc] initWithStyle:kSystemStyle];
            [text appendText:SNLocalized(@"render.broadcast.thread") style:0];
            [blocks addObject:text.paragraph];
        } else [blocks addObject:[self broadcastLine:message]];
    }
    if (message.blocks.count) [blocks addObjectsFromArray:[self blocksForBlockKit:message.blocks]];
    else if (message.text.length) [blocks addObjectsFromArray:[self blocksForMrkdwn:message.text style:SNTextStyleBody inline:[subtype isEqualToString:@"me_message"] ? SNInlineItalic : 0]];
    [blocks addObjectsFromArray:[self blocksForAttachments:message.attachments]];
    if (message.editedTS) [self appendEdited:blocks];
    return [SNRenderDocument documentWithBlocks:blocks];
}

+ (SNRenderDocument *)previewOfMessage:(SNMessage *)message source:(id<SNSource>)source style:(SNTextStyle)style prefix:(NSString *)prefix {
    static SNRenderer *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [SNRenderer new]; });
    shared->_source = source;
    shared->_underlinesLinks = SNPreferenceBool(source.preferences, @"underline_links", NO);
    SNRenderDocument *document = [shared previewOfMessage:message style:style prefix:prefix];
    shared->_source = nil;
    return document;
}

/// "replied to a thread: <the parent's first words>", above a broadcast reply.
- (SNParagraphBlock *)broadcastLine:(SNMessage *)message {
    SNInlineText *text = [[SNInlineText alloc] initWithStyle:kSystemStyle];
    [text appendText:[SNLocalized(@"render.broadcast") stringByAppendingString:@" "] style:0];
    SNMessage *parent = message.conversationID && message.threadTS
                            ? [self.source cachedMessageWithTS:message.threadTS inConversation:message.conversationID threadTS:nil]
                            : nil;
    // Slack sends the parent along ("root") for when the history does not reach it.
    NSDictionary *root = SNJSONObject(message.json, @"root");
    SNMessage *quoted = parent ?: (root ? [SNMessage messageWithJSON:root conversationID:message.conversationID] : nil) ?: message;
    NSArray *body = quoted.blocks.count ? [self blocksForBlockKit:quoted.blocks] : [self blocksForMrkdwn:quoted.text style:SNTextStyleBody];
    NSString *preview = [[SNRenderDocument documentWithBlocks:body].plainText componentsSeparatedByString:@"\n"].firstObject ?: @"";
    if (preview.length > 80) preview = [[preview substringToIndex:80] stringByAppendingString:@"…"];
    [text appendText:preview style:SNInlineBold target:[SNRenderTarget targetWithKind:SNRenderTargetLink value:[@"thread:" stringByAppendingString:message.threadTS ?: @""]]];
    return text.paragraph;
}

/// "(edited)" in 13 pt grey right after the last paragraph's text, or on its own line.
- (void)appendEdited:(NSMutableArray<SNRenderBlock *> *)blocks {
    SNInlineText *label = [[SNInlineText alloc] initWithStyle:kEditedStyle];
    [label appendText:SNLocalized(@"render.edited") style:0];
    SNParagraphBlock *last = [blocks.lastObject isKindOfClass:SNParagraphBlock.class] ? (SNParagraphBlock *)blocks.lastObject : nil;
    if (!last.text.length) last = nil;
    if (!last) {
        [blocks addObject:[SNParagraphBlock paragraphWithText:label.attributedText style:SNTextStyleBody]];
        return;
    }
    NSMutableAttributedString *text = [last.text mutableCopy];
    // The space is the label's: the last character's attributes may be an emoji's picture, a
    // mention's chip or a link.
    SNInlineText *spaced = [[SNInlineText alloc] initWithStyle:kEditedStyle];
    [spaced appendText:[@" " stringByAppendingString:SNLocalized(@"render.edited")] style:0];
    [text appendAttributedString:spaced.attributedText];
    SNParagraphBlock *paragraph = [SNParagraphBlock paragraphWithText:text style:last.style];
    paragraph.indent = last.indent, paragraph.marker = last.marker, paragraph.spaceBefore = last.spaceBefore, paragraph.spaceAfter = last.spaceAfter;
    blocks[blocks.count - 1] = paragraph;
}

@end

@implementation SNDocumentSink

- (void)beginBlock:(SNTextBlockKind)kind indent:(NSInteger)indent number:(NSInteger)number {
    if (_flat) {
        if (_text.length > _start) [_text appendText:@" " style:0];
        _blockStyle = kind == SNTextCode ? SNInlineCode : 0;
        return;
    }
    [self close];
    _kind = kind, _indent = indent, _number = number;
    _text = [[SNInlineText alloc] initWithStyle:kind == SNTextCode ? kCodeStyle : _style];
    _text.monospaced = kind == SNTextCode;
    _text.jumbo = _jumbo && kind == SNTextSection;
}

/// Ends the block being written.
- (void)close {
    SNInlineText *text = _text;
    if (!text) return;
    _text = nil;
    switch (_kind) {
    case SNTextSection: {
        SNParagraphBlock *paragraph = text.paragraph;
        // A section that starts on a new line after a list or quote starts a paragraph.
        if (_blocks.count && [paragraph.text.string hasPrefix:@"\n"]) {
            paragraph = [SNParagraphBlock paragraphWithText:[paragraph.text attributedSubstringFromRange:NSMakeRange(1, paragraph.text.length - 1)] style:paragraph.style];
            paragraph.spaceBefore = 8;
        }
        if (paragraph.text.length) [_blocks addObject:paragraph];
        break;
    }
    case SNTextListItem: {
        SNParagraphBlock *paragraph = text.paragraph;
        paragraph.indent = 28 * (_indent + 1);
        paragraph.marker = _number ? NumberMarker(_number, _indent) : BulletMarker(_indent);
        [_blocks addObject:paragraph];
        break;
    }
    case SNTextQuote: [_blocks addObject:[SNGroupBlock quoteWithBlocks:@[ text.paragraph ]]]; break;
    case SNTextCode: [_blocks addObject:[SNCodeBlock codeBlockWithText:text.attributedText]]; break;
    }
}

- (NSArray<SNRenderBlock *> *)finish {
    [self close];
    return _blocks;
}

- (void)appendText:(NSString *)text style:(SNInlineStyle)style {
    [_text appendText:_flat ? [text stringByReplacingOccurrencesOfString:@"\n" withString:@" "] : text style:style | _blockStyle];
}

- (void)appendLink:(NSString *)string text:(NSString *)label style:(SNInlineStyle)style {
    NSURL *url = [NSURL URLWithString:string];
    if (!url) return [self appendText:label ?: string style:style];
    // A preview's bare link reads without its scheme, as in Slack's.
    if (_flat && !label && url.host) label = [url.absoluteString substringFromIndex:url.scheme.length + 3];
    [_renderer appendWebLink:url text:label style:style | _blockStyle to:_text];
}

- (void)appendUser:(NSString *)userID label:(NSString *)label { [_renderer appendUser:userID label:label to:_text]; }

- (void)appendChannel:(NSString *)channelID label:(NSString *)label style:(SNInlineStyle)style {
    [_renderer appendChannel:channelID label:label style:style to:_text];
}

- (void)appendUsergroup:(NSString *)groupID label:(NSString *)label { [_renderer appendUsergroup:groupID label:label to:_text]; }

- (void)appendBroadcast:(NSString *)range {
    // Previews have no chips for @here.
    if (_flat) [_text appendText:[@"@" stringByAppendingString:range] style:SNInlineBold];
    else [_renderer appendBroadcast:range to:_text];
}

- (void)appendEmoji:(NSString *)name unicode:(NSString *)unicode style:(SNInlineStyle)style {
    [_renderer noteEmoji:name];
    [_text appendEmoji:name fallbackUnicode:unicode];
}

- (void)appendDate:(NSTimeInterval)timestamp format:(NSString *)format link:(NSString *)link fallback:(NSString *)fallback style:(SNInlineStyle)style {
    [_renderer appendDate:timestamp format:format link:link fallback:fallback style:style | _blockStyle to:_text];
}

- (BOOL)knowsEmoji:(NSString *)name {
    [_renderer noteEmoji:name];
    return SNEmojiUnicode(name) || SNCustomEmojiURL(name);
}

@end
