// Owns the files lists' rows: their geometry, words, hover actions and clicks.
#import "render/format.h"
#import "render/icon.h"
#import "render/images.h"
#import "render/strings.h"
#import "ui/files/filenet.h"
#import "ui/files/fileview.h"
#import "ui/files/rows.h"
#import "ui/kit/label.h"
#import "ui/kit/popover.h"

/// .c-pillow_file: 12 pt padding around the 36 pt .c-pillow_file__icon, the text 12 pt after it.
/// The medium base entity centres its text on the icon with -4 pt margins and the title's own
/// -4 pt: the title's 22.5 pt line box 5.6 pt below the padding's top, the 16.25 pt detail line
/// 2 pt under it (b4_files_peek: baselines 23 and 43 pt down a row).
static const CGFloat kPad = 12, kIcon = 36, kTextX = kPad + kIcon + kPad, kFileRow = 60;
static const CGFloat kFileTitleTop = 5.625, kFileTitleLine = 22.5, kFileDetailTop = 30.125, kFileDetailLine = 16.25;
/// LinkEntity: the compact entity's fixed 62 pt with 12 pt padding; StackedLabels' body line
/// (22) on top of the caption's (18) 2 pt under it; the site icon 24 pt on the 36 pt tile.
static const CGFloat kLinkRow = 62, kLinkTitleLine = 22, kLinkDetailTop = 36, kLinkDetailLine = 18, kFavicon = 24;
/// Explorer lists: files framed in rgba(foreground, .1) with 12 pt outer corners
/// (.p-explorer_result--list), links in otl-ter with 8 pt ones (renderedInList).
static const CGFloat kFileListRadius = 12, kLinkListRadius = 8;
/// .c-file__actions at the card's top right: the message actions group (4 pt padding, 32 pt
/// buttons, More 28 wide, radius 12) with files_tab_view's otl-ter border and base shadow.
static const CGFloat kGroupInset = 12, kGroupPadding = 4, kGroupButton = 32, kGroupMore = 28;
/// The entity's ActionsBar: 8 pt in, 4 pt padding, smedium 28 pt buttons.
static const CGFloat kBarInset = 8, kBarPadding = 4, kBarButton = 28;
static const SNColorToken kGroupButtonHover = 0xe8e8e80a;

CGFloat SNFileRowHeight(SNFileRowStyle style, BOOL last) { return style == SNFileRowPeek ? kFileRow + (last ? 0 : 1) : 1 + kFileRow + (last ? 1 : 0); }
CGFloat SNLinkRowHeight(SNFileRowStyle style, BOOL last) { return style == SNFileRowPeek ? kLinkRow + (last ? 0 : 1) : 1 + kLinkRow + (last ? 1 : 0); }

/// getMainFileAction's "download": hosted files the media viewer does not show.
static BOOL Downloads(SNFile *file) {
    if (file.isExternal) return NO;
    return ![file.fileType isEqualToString:@"pdf"] && ![file.mimeType hasPrefix:@"image/"] && ![file.mimeType hasPrefix:@"video/"];
}

static void OpenInBrowser(SNFile *file) {
    // Another service's file opens there; Slack's own opens its page in Slack's web client.
    NSURL *url = file.isExternal ? file.privateURL ?: file.permalink : file.permalink ?: file.privateURL;
    if (url) [NSWorkspace.sharedWorkspace openURL:url];
}

void SNOpenFile(SNFile *file, id<SNSource> source) {
    [source noteFileViewed:file];
    if (Downloads(file)) SNDownloadFile(file, nil);
    else OpenInBrowser(file);
}

static NSString *UploaderName(SNFile *file, id<SNSource> source) {
    SNUser *user = file.userID ? [source userWithID:file.userID] : nil;
    return user.visibleName.length ? user.visibleName : file.userName ?: @"";
}

/// "hoje", "ontem" or nil for an older day.
static NSString *RelativeDay(NSDate *date, NSDate *now) {
    if (SNSameDay(date, now)) return SNLocalized(@"files.day.today");
    if (SNSameDay(date, [now dateByAddingTimeInterval:-86400])) return SNLocalized(@"files.day.yesterday");
    return nil;
}

NSString *SNFileRowDescription(SNFile *file, SNFileRowDetail detail, id<SNSource> source, NSDate *now) {
    NSString *name = UploaderName(file, source);
    if (detail == SNFileRowDetailShared) {
        if (!(file.timestamp ?: file.created)) return name.length ? SNLocalizedFormat(@"files.shared.by", name) : @"";
        NSDate *shared = [NSDate dateWithTimeIntervalSince1970:file.timestamp ?: file.created];
        NSString *day = RelativeDay(shared, now);
        return day ? SNLocalizedFormat(@"files.shared.day", name, day) : SNLocalizedFormat(@"files.shared.date", name, SNFormatShortDate(shared, now));
    }
    // getFileMetaForSyntheticView with [owner, last viewed or updated]; read time needs a
    // canvas's word count, which search results do not carry.
    // What Slack does not say about a file is left out rather than shown empty.
    NSMutableArray<NSString *> *parts = [NSMutableArray new];
    if (name.length) [parts addObject:SNLocalizedFormat(@"files.created", name)];
    NSTimeInterval viewed = file.lastRead ?: file.created, updated = file.updated ?: file.created;
    if (detail == SNFileRowDetailViewed && viewed > 0) {
        NSDate *date = [NSDate dateWithTimeIntervalSince1970:viewed];
        NSString *day = RelativeDay(date, now);
        [parts addObject:day ? SNLocalizedFormat(@"files.viewed.day", day) : SNLocalizedFormat(@"files.viewed.date", SNFormatShortDate(date, now))];
    } else if (detail == SNFileRowDetailUpdated && updated > 0) {
        [parts addObject:SNLocalizedFormat(@"files.updated", SNFormatAgo([NSDate dateWithTimeIntervalSince1970:updated], now))];
    }
    return [parts componentsJoinedByString:@" · "];
}

/// A path with each corner rounded or square, inside `rect`.
static NSBezierPath *Rounded(NSRect rect, CGFloat top, CGFloat bottom) {
    NSBezierPath *path = [NSBezierPath bezierPath];
    [path moveToPoint:NSMakePoint(NSMinX(rect) + top, NSMinY(rect))];
    [path lineToPoint:NSMakePoint(NSMaxX(rect) - top, NSMinY(rect))];
    if (top) [path curveToPoint:NSMakePoint(NSMaxX(rect), NSMinY(rect) + top) controlPoint1:NSMakePoint(NSMaxX(rect), NSMinY(rect)) controlPoint2:NSMakePoint(NSMaxX(rect), NSMinY(rect))];
    [path lineToPoint:NSMakePoint(NSMaxX(rect), NSMaxY(rect) - bottom)];
    if (bottom) [path curveToPoint:NSMakePoint(NSMaxX(rect) - bottom, NSMaxY(rect)) controlPoint1:NSMakePoint(NSMaxX(rect), NSMaxY(rect)) controlPoint2:NSMakePoint(NSMaxX(rect), NSMaxY(rect))];
    [path lineToPoint:NSMakePoint(NSMinX(rect) + bottom, NSMaxY(rect))];
    if (bottom) [path curveToPoint:NSMakePoint(NSMinX(rect), NSMaxY(rect) - bottom) controlPoint1:NSMakePoint(NSMinX(rect), NSMaxY(rect)) controlPoint2:NSMakePoint(NSMinX(rect), NSMaxY(rect))];
    [path lineToPoint:NSMakePoint(NSMinX(rect), NSMinY(rect) + top)];
    if (top) [path curveToPoint:NSMakePoint(NSMinX(rect) + top, NSMinY(rect)) controlPoint1:NSMakePoint(NSMinX(rect), NSMinY(rect)) controlPoint2:NSMakePoint(NSMinX(rect), NSMinY(rect))];
    [path closePath];
    return path;
}

/// The row's part of its group: a list's base-pry fill and borders (the bottom one only under the
/// last row, each outer corner rounded), or the peek's line under all but the last. Returns the
/// top of the row's content.
static CGFloat DrawFrame(NSRect bounds, SNFileRowStyle style, BOOL first, BOOL last, SNColorToken border, CGFloat radius) {
    if (style == SNFileRowPeek) {
        if (!last) {
            [SNColor(SNColorOtlTer) setFill];
            NSRectFillUsingOperation(NSMakeRect(0, NSMaxY(bounds) - 1, NSWidth(bounds), 1), NSCompositingOperationSourceOver);
        }
        return 0;
    }
    NSRect box = NSInsetRect(bounds, 0.5, 0.5);
    // A row but the last leaves its bottom edge to the next row's top border.
    if (!last) box.size.height += 1;
    NSBezierPath *frame = Rounded(box, first ? radius - 0.5 : 0, last ? radius - 0.5 : 0);
    [NSGraphicsContext saveGraphicsState];
    NSRectClip(bounds);
    [SNColor(SNColorBasePry) setFill];
    [frame fill];
    [SNColor(border) setStroke];
    [frame stroke];
    [NSGraphicsContext restoreGraphicsState];
    return 1;
}

/// The actions group's fill, border and shadow behind its buttons.
@interface SNFileRowActions : NSView
@property (nonatomic) BOOL bar;
@end

@implementation SNFileRowActions

- (BOOL)isFlipped { return YES; }

- (void)drawRect:(NSRect)dirtyRect {
    NSRect box = NSInsetRect(self.bounds, 3, 3);
    NSBezierPath *group = [NSBezierPath bezierPathWithRoundedRect:box xRadius:SNRadiusXlarge yRadius:SNRadiusXlarge];
    [NSGraphicsContext saveGraphicsState];
    // shadow-base: 0 1px 3px #00000019, 0 1px 2px -1px #00000019.
    NSShadow *shadow = [NSShadow new];
    shadow.shadowOffset = NSMakeSize(0, -1);
    shadow.shadowBlurRadius = 3;
    shadow.shadowColor = [NSColor colorWithWhite:0 alpha:0.1];
    [shadow set];
    [SNColor(self.bar ? SNColorBasePry : SNLegacyPrimaryBackground) setFill];
    [group fill];
    [NSGraphicsContext restoreGraphicsState];
    [SNColor(SNColorOtlTer) setStroke];
    [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(box, 0.5, 0.5) xRadius:SNRadiusXlarge - 0.5 yRadius:SNRadiusXlarge - 0.5] stroke];
}

@end

/// Makes a hover group of icon buttons: `specs` are @[icon, tooltip key, action]; returns the
/// group sized to them (3 pt of room around the box for its shadow).
static SNFileRowActions *MakeGroup(NSArray<NSArray *> *specs, BOOL bar) {
    SNFileRowActions *group = [[SNFileRowActions alloc] initWithFrame:NSZeroRect];
    group.bar = bar;
    group.wantsLayer = YES;
    CGFloat padding = bar ? kBarPadding : kGroupPadding, side = bar ? kBarButton : kGroupButton, x = 3 + padding;
    for (NSArray *spec in specs) {
        BOOL more = [spec[0] isEqualToString:@"ellipsis-vertical-filled"];
        CGFloat width = more && !bar ? kGroupMore : side;
        SNButton *button = [SNButton iconButtonNamed:spec[0] size:side iconSize:18];
        button.hoverFillColor = kGroupButtonHover;
        button.contentColor = SNLegacyForegroundMaxSolid;
        button.hoverContentColor = button.pressedContentColor = SNLegacyPrimaryForeground;
        button.tooltip = SNLocalized(spec[1]);
        button.action = spec[2];
        button.frame = NSMakeRect(x, 3 + padding, width, side);
        x += width;
        [group addSubview:button];
    }
    group.frame = NSMakeRect(0, 0, x + padding + 3, side + 2 * padding + 6);
    return group;
}

#pragma mark - File row

@implementation SNFileRow {
    id<SNSource> _source;
    SNFileRowStyle _style;
    SNFileRowActions *_actions;
}

- (instancetype)initWithSource:(id<SNSource>)source style:(SNFileRowStyle)style {
    if (!(self = [super initWithFrame:NSZeroRect])) return nil;
    _source = source;
    _style = style;
    // .c-pillow_file's hover darkens a border the explorer keeps: only the actions show.
    self.hoverColor = self.pressedColor = 0;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;
    __weak SNFileRow *weakSelf = self;
    self.action = ^(SNFileRow *row) {
        SNFileRow *me = weakSelf;
        if (me.file) SNOpenFile(me.file, me->_source);
    };
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)setFile:(SNFile *)file {
    if (file != _file) [self.imageHolder removeAllImages];
    _file = file;
    [_actions removeFromSuperview];
    _actions = nil;
    self.needsDisplay = YES;
}

- (void)setFirst:(BOOL)first {
    _first = first;
    self.needsDisplay = YES;
}

- (void)setLast:(BOOL)last {
    _last = last;
    self.needsDisplay = YES;
}

/// Made on the first hover: a list scrolling past files makes no buttons.
- (void)setHovered:(BOOL)hovered {
    if (hovered && !_actions) [self makeActions];
    [super setHovered:hovered];
}

- (void)stateDidChange {
    [super stateDidChange];
    // The actions fade in over 100 ms (.c-file__actions: opacity .1s).
    _actions.animator.alphaValue = self.hovered || self.pressed;
    if (self.showsActionOnHover) self.needsDisplay = YES;
}

- (void)makeActions {
    SNFile *file = _file;
    if (!file) return;
    NSMutableArray *specs = [NSMutableArray new];
    __weak SNFileRow *weakSelf = self;
    if (!file.isExternal) [specs addObject:@[ @"download", @"channel.file.download", ^(SNButton *b) { SNDownloadFile(file, nil); } ]];
    [specs addObject:@[ @"new-window", @"channel.file.browser", ^(SNButton *b) { OpenInBrowser(file); } ]];
    [specs addObject:@[ @"ellipsis-vertical-filled", @"channel.file.more", ^(SNButton *b) { [weakSelf showMoreFrom:b]; } ]];
    _actions = MakeGroup(specs, NO);
    _actions.alphaValue = 0;
    [self addSubview:_actions];
    self.needsLayout = YES;
}

- (NSArray<SNButton *> *)actionButtons {
    if (!_actions) [self makeActions];
    return (NSArray<SNButton *> *)_actions.subviews ?: @[];
}

- (void)layout {
    [super layout];
    CGFloat top = _style == SNFileRowList ? 1 : 0;
    NSSize size = _actions.frame.size;
    _actions.frame = NSMakeRect(NSWidth(self.bounds) - kGroupInset - size.width + 3, top + kGroupInset - 3, size.width, size.height);
}

- (void)showMoreFrom:(NSView *)button {
    SNFile *file = _file;
    NSMutableArray<SNMenuItem *> *items = [NSMutableArray arrayWithObject:[SNMenuItem itemWithTitle:SNLocalized(@"channel.file.browser") action:^{ OpenInBrowser(file); }]];
    if (!file.isExternal) [items addObject:[SNMenuItem itemWithTitle:SNLocalized(@"channel.file.download") action:^{ SNDownloadFile(file, nil); }]];
    if (file.permalink)
        [items addObject:[SNMenuItem itemWithTitle:SNLocalized(@"channel.file.copylink") action:^{
                   [NSPasteboard.generalPasteboard clearContents];
                   [NSPasteboard.generalPasteboard setString:file.permalink.absoluteString forType:NSPasteboardTypeString];
               }]];
    [[[SNMenu alloc] initWithItems:items width:0] showForRect:button.bounds inView:button placement:SNPlacementBelow];
}

/// A picture's own thumbnail on the tile (p-file_thumbnail), else the type icon.
- (void)drawIconInRect:(NSRect)rect {
    BOOL picture = [_file.mimeType hasPrefix:@"image/"] || [_file.mimeType hasPrefix:@"video/"];
    NSURL *thumbnail = [_file.mimeType hasPrefix:@"video/"] ? _file.videoThumbnailURL : [_file thumbnailURLForPixels:kIcon * 2];
    if (picture && thumbnail) SNDrawFilePicture(thumbnail, rect, SNRadiusLarge, self);
    else SNDrawFileTypeIcon(_file, rect);
}

- (void)drawRect:(NSRect)dirtyRect {
    if (!_file) return;
    NSRect bounds = self.bounds;
    CGFloat top = DrawFrame(bounds, _style, _first, _last, SNColorWithAlpha(SNLegacyPrimaryForeground, 0.1), kFileListRadius);
    [self drawIconInRect:NSMakeRect(kPad, top + kPad, kIcon, kIcon)];
    CGFloat width = MAX(0, NSWidth(bounds) - kTextX - kPad - 8);
    SNDrawText(_file.title.length ? _file.title : _file.name, SNFont(SNFontSizeBase, SNFontWeightBold), SNLegacyPrimaryForeground, kFileTitleLine,
               NSTextAlignmentLeft, 1, NSMakeRect(kTextX, top + kFileTitleTop, width, kFileTitleLine));
    NSRect detail = NSMakeRect(kTextX, top + kFileDetailTop, width + 8, kFileDetailLine);
    if (self.showsActionOnHover && (self.hovered || self.pressed)) [self drawActionTextInRect:detail];
    else
        SNDrawText(SNFileRowDescription(_file, _detail, _source, NSDate.date), SNFont(SNFontSizeCaption, SNFontWeightRegular), SNLegacyForegroundMaxSolid,
                   kFileDetailLine, NSTextAlignmentLeft, 1, detail);
}

/// getActionText: "Download **Word Document**" for what a click downloads, else "Open in browser".
- (void)drawActionTextInRect:(NSRect)rect {
    NSFont *font = SNFont(SNFontSizeCaption, SNFontWeightRegular), *bold = SNFont(SNFontSizeCaption, SNFontWeightBold);
    if (!Downloads(_file)) {
        SNDrawText(SNLocalized(@"channel.file.hover.browser"), font, SNLegacyForegroundMaxSolid, kFileDetailLine, NSTextAlignmentLeft, 1, rect);
        return;
    }
    NSArray<NSString *> *parts = [SNLocalized(@"channel.file.hover.download") componentsSeparatedByString:@"%@"];
    NSArray *pieces = @[ @[ parts.firstObject ?: @"", font ], @[ SNFileDescription(_file), bold ], @[ parts.count > 1 ? parts[1] : @"", font ] ];
    CGFloat x = NSMinX(rect);
    for (NSArray *piece in pieces) {
        NSString *text = piece[0];
        if (!text.length || x >= NSMaxX(rect)) continue;
        SNDrawText(text, piece[1], SNLegacyForegroundMaxSolid, kFileDetailLine, NSTextAlignmentLeft, 1, NSMakeRect(x, NSMinY(rect), NSMaxX(rect) - x, kFileDetailLine));
        x += ceil([text sizeWithAttributes:@{NSFontAttributeName : piece[1]}].width);
    }
}

@end

#pragma mark - Link row

@implementation SNLinkRow {
    SNFileRowStyle _style;
    SNFileRowActions *_actions;
    NSTrackingArea *_contents;
    /// The pointer is over the icon and labels (LinkEntity's contents), not only the row.
    BOOL _overContents;
}

- (instancetype)initWithStyle:(SNFileRowStyle)style {
    if (!(self = [super initWithFrame:NSZeroRect])) return nil;
    _style = style;
    self.hoverColor = self.pressedColor = 0;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;
    self.action = ^(SNLinkRow *row) {
        if (row.link) [NSWorkspace.sharedWorkspace openURL:row.link.url];
    };
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)setLink:(SNChannelLink *)link {
    if (link != _link) [self.imageHolder removeAllImages];
    _link = link;
    self.needsDisplay = YES;
}

- (void)setFirst:(BOOL)first {
    _first = first;
    self.needsDisplay = YES;
}

- (void)setLast:(BOOL)last {
    _last = last;
    self.needsDisplay = YES;
}

- (void)setHovered:(BOOL)hovered {
    if (hovered && !_actions) [self makeActions];
    [super setHovered:hovered];
}

- (void)stateDidChange {
    [super stateDidChange];
    // The actions bar shows at once (opacity 80 ms in the entity's CSS).
    _actions.animator.alphaValue = self.hovered || self.pressed;
    if (!self.hovered) _overContents = NO;
    self.needsDisplay = YES;
}

- (void)makeActions {
    __weak SNLinkRow *weakSelf = self;
    _actions = MakeGroup(@[
        @[ @"info", @"files.link.details", ^(SNButton *b) { [weakSelf openLink]; } ],
        @[ @"ellipsis-vertical-filled", @"files.link.more", ^(SNButton *b) { [weakSelf showMoreFrom:b]; } ]
    ],
                         YES);
    _actions.alphaValue = 0;
    [self addSubview:_actions];
    self.needsLayout = YES;
}

- (NSArray<SNButton *> *)actionButtons {
    if (!_actions) [self makeActions];
    return (NSArray<SNButton *> *)_actions.subviews;
}

- (void)openLink {
    if (_link) [NSWorkspace.sharedWorkspace openURL:_link.url];
}

- (void)showMoreFrom:(NSView *)button {
    NSURL *url = _link.url;
    SNMenuItem *copy = [SNMenuItem itemWithTitle:SNLocalized(@"files.link.copy") action:^{
        [NSPasteboard.generalPasteboard clearContents];
        [NSPasteboard.generalPasteboard setString:url.absoluteString forType:NSPasteboardTypeString];
    }];
    [[[SNMenu alloc] initWithItems:@[ copy ] width:0] showForRect:button.bounds inView:button placement:SNPlacementBelow];
}

- (CGFloat)contentTop { return _style == SNFileRowList ? 1 : 0; }

- (void)layout {
    [super layout];
    NSSize size = _actions.frame.size;
    _actions.frame = NSMakeRect(NSWidth(self.bounds) - kBarInset - size.width + 3, self.contentTop + kBarInset - 3, size.width, size.height);
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_contents) [self removeTrackingArea:_contents];
    _contents = [[NSTrackingArea alloc] initWithRect:NSMakeRect(kPad, self.contentTop + kPad, MAX(0, NSWidth(self.bounds) - 2 * kPad), kIcon + 8)
                                             options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways
                                               owner:self
                                            userInfo:@{@"contents" : @YES}];
    [self addTrackingArea:_contents];
}

- (void)mouseEntered:(NSEvent *)event {
    if (event.trackingArea == _contents) {
        _overContents = YES;
        self.needsDisplay = YES;
        return;
    }
    [super mouseEntered:event];
}

- (void)mouseExited:(NSEvent *)event {
    if (event.trackingArea == _contents) {
        _overContents = NO;
        self.needsDisplay = YES;
        return;
    }
    [super mouseExited:event];
}

/// LinkEntity's labels: the title or the host, then the host under a title or the path.
- (NSString *)primaryText { return _link.title ?: _link.url.host ?: @""; }

- (NSString *)secondaryText {
    if (_link.title) return _link.url.host ?: @"";
    NSString *path = _link.url.path.length ? _link.url.path : @"/";
    if (_link.url.query.length) path = [path stringByAppendingFormat:@"?%@", _link.url.query];
    return [path isEqualToString:@"/"] ? @"" : path;
}

- (void)drawRect:(NSRect)dirtyRect {
    if (!_link) return;
    NSRect bounds = self.bounds;
    CGFloat top = DrawFrame(bounds, _style, _first, _last, SNColorOtlTer, kLinkListRadius);
    NSRect tile = NSMakeRect(kPad, top + kPad, kIcon, kIcon);
    [SNColor(SNColorSurfSec) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:tile xRadius:SNRadiusLarge yRadius:SNRadiusLarge] fill];
    CGImageRef icon = _link.iconURL ? [self.imageHolder imageWithURL:_link.iconURL pixels:kFavicon * 2] : NULL;
    if (icon) {
        NSRect box = NSMakeRect(NSMidX(tile) - kFavicon / 2, NSMidY(tile) - kFavicon / 2, kFavicon, kFavicon);
        CGContextRef context = NSGraphicsContext.currentContext.CGContext;
        CGContextSaveGState(context);
        CGContextTranslateCTM(context, 0, NSMaxY(box) + NSMinY(box));
        CGContextScaleCTM(context, 1, -1);
        CGContextDrawImage(context, box, icon);
        CGContextRestoreGState(context);
    } else {
        SNDrawIcon(@"link", 20, SNColorContentPry, tile);
    }
    CGFloat width = MAX(0, NSWidth(bounds) - kTextX - kPad);
    SNDrawText(self.primaryText, SNFont(SNFontSizeBase, SNFontWeightBold), SNColorContentPry, kLinkTitleLine, NSTextAlignmentLeft, 1,
               NSMakeRect(kTextX, top + kPad, width, kLinkTitleLine));
    NSString *secondary = self.secondaryText;
    if (_overContents && secondary.length) secondary = SNLocalized(@"files.link.open");
    SNDrawText(secondary, SNFont(SNFontSizeCaption, SNFontWeightRegular), SNColorContentTer, kLinkDetailLine, NSTextAlignmentLeft, 1,
               NSMakeRect(kTextX, top + kLinkDetailTop, width, kLinkDetailLine));
}

@end

#pragma mark - Skeleton

@implementation SNFileSkeletonRow {
    SNFileRowStyle _style;
    NSUInteger _index;
    BOOL _last;
}

- (instancetype)initWithStyle:(SNFileRowStyle)style index:(NSUInteger)index last:(BOOL)last {
    if (!(self = [super initWithFrame:NSZeroRect])) return nil;
    _style = style;
    _index = index;
    _last = last;
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)drawRect:(NSRect)dirtyRect {
    CGFloat top = DrawFrame(self.bounds, _style, _index == 0, _last, SNColorWithAlpha(SNLegacyPrimaryForeground, 0.1), kFileListRadius);
    [SNColor(SNColorBaseTer) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(kPad, top + kPad, kIcon, kIcon) xRadius:SNRadiusBase yRadius:SNRadiusBase] fill];
    // b4_files_peek's skeleton: the title bar 14 pt down (Slack picks its length at random), the
    // two meta bars 35 pt down, 120 and 80 long, 8 apart; all 8 pt tall pills.
    static const CGFloat titles[] = {160, 160, 160, 80, 120, 160, 120};
    CGFloat title = titles[_index % (sizeof titles / sizeof *titles)];
    for (NSValue *bar in @[ [NSValue valueWithRect:NSMakeRect(kTextX, top + 14, title, 8)], [NSValue valueWithRect:NSMakeRect(kTextX, top + 35, 120, 8)],
                            [NSValue valueWithRect:NSMakeRect(kTextX + 128, top + 35, 80, 8)] ])
        [[NSBezierPath bezierPathWithRoundedRect:bar.rectValue xRadius:4 yRadius:4] fill];
}

@end
