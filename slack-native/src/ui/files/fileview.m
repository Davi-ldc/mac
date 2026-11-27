// Owns drawing files that do not play, their hover actions, a snippet's expansion and the size
// each kind takes.
#import <CoreText/CoreText.h>

#import "render/icon.h"
#import "render/images.h"
#import "render/strings.h"
#import "ui/files/filenet.h"
#import "ui/files/fileview.h"
#import "ui/files/mediaview.h"
#import "ui/kit/button.h"
#import "ui/kit/label.h"
#import "ui/kit/popover.h"

/// .c-message_kit__file__meta: the name in 13 pt at 70% and the caret, 4 pt above the file.
static const CGFloat kMetaHeight = 22, kMetaAlpha = 0.7;
static const CGFloat kImageMaxHeight = 360, kImageMaxWidth = 480;
/// The picture's buttons (gallery v3): 28 pt on base-modal, 8 pt in from the corner.
static const CGFloat kOverlayButton = 28, kOverlayGap = 4, kOverlayInset = 8;
/// .c-pillow_file: 1 pt border, 12 pt padding, a 36 pt icon 12 pt before the text; 426 pt at
/// most in a message (.p-message_file), 200 at least.
static const CGFloat kCardPadding = 12, kCardIcon = 36, kCardHeight = 62, kCardWidth = 426, kCardMinWidth = 200;
/// The header's text (base entity "medium", centred on the icon): the title's 22.5 pt line box
/// 8.6 pt below the card's top, the kind's 16.25 pt one 2 pt under it.
static const CGFloat kTitleTop = 8.625, kTitleLine = 22.5, kKindTop = 33.125, kKindLine = 16.25;
/// .c-message_actions__group at the card's top right: 4 pt padding, 32 pt buttons radius 8
/// (More 28 wide), on base-pry with a 1 pt rgba(232,232,232,.13) ring, radius 12.
static const CGFloat kGroupPadding = 4, kGroupButton = 32, kGroupMore = 28, kGroupInset = 12;
static const SNColorToken kGroupButtonHover = 0xe8e8e80a;
/// .c-pillow_file__preview--document: the first page 200 pt tall under a 1 pt rule, the card's
/// full inner width, 12 pt under the header.
static const CGFloat kDocumentPreview = 200, kDocumentGap = 12;
/// The snippet's code (.c-pillow_file__snippet__content): Roboto Mono 13 on 19.5, flush with the
/// card's border; a 32 pt line-number gutter, the text 12 pt in from it and 12 pt from the right.
static const CGFloat kCodeLine = 19.5, kGutter = 32, kCodeLeft = 1 + kGutter + 12, kCodeRight = 12;
/// Collapsed it is at most 200 pt tall with a 40 pt fade at the bottom; expanded, at most 500
/// lines (files.info's count in the client), then the truncation line.
static const CGFloat kCollapsedHeight = 200, kFade = 40, kTruncatedHeight = 28;
static const NSUInteger kExpandedLines = 500;
/// CSV cells: 4 pt padding, 80-200 pt wide, right and bottom rules.
static const CGFloat kCellPadding = 4, kCellMin = 80, kCellMax = 200;
/// The expand pill (.c-pillow_file__expandable_pill): 24 pt, radius 12, #616061, 13 pt white.
static const CGFloat kPillHeight = 24;
static const SNColorToken kPillFill = 0x616061ff, kMetaColor = 0xe8e8e8b3;

#pragma mark - Snippet code

/// CSS white-space: pre-wrap with overflow-wrap: break-word: at spaces, else anywhere.
static NSArray *Wrapped(NSAttributedString *text, CGFloat width) {
    if (!text.length) return @[];
    NSMutableArray *lines = [NSMutableArray new];
    CTTypesetterRef typesetter = CTTypesetterCreateWithAttributedString((__bridge CFAttributedStringRef)text);
    for (CFIndex start = 0; start < (CFIndex)text.length;) {
        CFIndex count = MAX(1, CTTypesetterSuggestLineBreak(typesetter, start, MAX(20, width)));
        [lines addObject:(__bridge_transfer id)CTTypesetterCreateLine(typesetter, CFRangeMake(start, count))];
        start += count;
    }
    CFRelease(typesetter);
    return lines;
}

/// A snippet's rows wrapped at a width: CTLines per source line (several when it wraps).
@interface SNCodeLayout : NSObject
@property (nonatomic, readonly) NSArray<NSArray *> *rows;
@property (nonatomic, readonly) NSArray<NSNumber *> *tops;
/// CSV: each column's width, and the rows' cells as truncated lines.
@property (nonatomic, readonly, nullable) NSArray<NSNumber *> *columns;
@property (nonatomic, readonly) CGFloat height;
@end

@implementation SNCodeLayout

/// Lays out until `limit` points are filled (the collapsed box), or every row.
+ (instancetype)layoutWithPreview:(SNSnippetPreview *)preview width:(CGFloat)width limit:(CGFloat)limit {
    SNCodeLayout *layout = [self new];
    NSMutableArray *rows = [NSMutableArray new], *tops = [NSMutableArray new];
    if (preview.rows) {
        NSFont *font = SNMonoFont(13, SNFontWeightRegular);
        NSMutableArray<NSNumber *> *columns = [NSMutableArray new];
        for (NSArray<NSString *> *row in preview.rows)
            for (NSUInteger i = 0; i < row.count; i++) {
                CGFloat text = ceil([row[i] sizeWithAttributes:@{NSFontAttributeName : font}].width) + 2 * kCellPadding;
                CGFloat cell = MIN(kCellMax, MAX(kCellMin, text));
                if (i < columns.count) columns[i] = @(MAX(columns[i].doubleValue, cell));
                else [columns addObject:@(cell)];
            }
        layout->_columns = columns;
        CGFloat y = 0;
        for (NSUInteger i = 0; i < preview.rows.count && y < limit; i++) {
            [tops addObject:@(y)];
            [rows addObject:preview.rows[i]];
            y += kCodeLine + 2 * kCellPadding + (i + 1 < preview.rows.count ? 1 : 0);
        }
        layout->_height = y;
    } else {
        NSUInteger count = preview.lines.count;
        // One line sits in an 18 pt margin, two in 8, more in 4 (CodeMirror-code's first and
        // last rows).
        CGFloat pad = count == 1 ? 18 : count == 2 ? 8 : 4, y = pad;
        for (NSUInteger i = 0; i < count && y < limit; i++) {
            [tops addObject:@(y)];
            NSArray *lines = Wrapped(preview.lines[i], width);
            [rows addObject:lines];
            y += MAX(1, lines.count) * kCodeLine;
        }
        layout->_height = y + pad;
    }
    layout->_rows = rows;
    layout->_tops = tops;
    return layout;
}

@end

/// Expanded snippets by message context and file, bounded to 50 entries and cleared on sign-out.
static NSMutableDictionary<NSString *, SNSnippetPreview *> *ExpandedSnippets(void) {
    static NSMutableDictionary *expanded;
    if (!expanded) expanded = [NSMutableDictionary new];
    return expanded;
}

static NSMutableArray<NSString *> *ExpandedSnippetOrder(void) {
    static NSMutableArray *order;
    if (!order) order = [NSMutableArray new];
    return order;
}

void SNResetExpandedSnippets(void) {
    [ExpandedSnippets() removeAllObjects];
    [ExpandedSnippetOrder() removeAllObjects];
}

static NSString *ExpansionKey(SNFile *file, NSString *context) { return [NSString stringWithFormat:@"%@/%@", context, file.fileID]; }

/// What the snippet shows: its whole text while expanded, else the preview.
static SNSnippetPreview *SnippetShown(SNFile *file, NSString *context, BOOL *expanded) {
    SNSnippetPreview *full = ExpandedSnippets()[ExpansionKey(file, context)];
    if (expanded) *expanded = full != nil;
    return full ?: [SNSnippetPreview previewOfFile:file];
}

/// isExpandableSnippet: more lines than the preview holds.
static BOOL Expandable(SNFile *file) { return file.moreLineCount > 0 || file.previewIsTruncated; }

static BOOL IsTable(SNFile *file) { return [file.fileType isEqualToString:@"csv"] || [file.fileType isEqualToString:@"tsv"]; }

/// The snippet card's height: the code (at most 200 pt collapsed), the truncation line.
static CGFloat SnippetHeight(SNFile *file, NSString *context, CGFloat width) {
    BOOL expanded;
    SNSnippetPreview *preview = SnippetShown(file, context, &expanded);
    if (!preview) return kCardHeight;
    BOOL collapsed = !expanded && Expandable(file);
    CGFloat code = [SNCodeLayout layoutWithPreview:preview width:width - kCodeLeft - kCodeRight limit:collapsed ? kCollapsedHeight : CGFLOAT_MAX].height;
    if (collapsed) code = MIN(code, kCollapsedHeight);
    return 1 + code + (expanded && preview.truncated ? kTruncatedHeight : 0) + 1;
}

#pragma mark - File type icon

/// The 36 pt type icon: Slack's file-<type> artwork is a tinted rounded square with a glyph; the
/// tints are the client's per-type colours (c-icon--file-<type>).
static void TypeIcon(SNFile *file, NSString **glyph, SNColorToken *tint) {
    NSString *type = file.fileType.lowercaseString ?: @"";
    NSString *mime = file.mimeType ?: @"";
    NSDictionary<NSString *, NSArray *> *types = @{
        @"pdf" : @[ @"pdf-file", @0xdb4437ff ],
        @"doc" : @[ @"document", @0x2c4098ff ], @"docx" : @[ @"document", @0x2c4098ff ],
        @"gdoc" : @[ @"document", @0x4285f4ff ],
        @"xls" : @[ @"spreadsheet", @0x377437ff ], @"xlsx" : @[ @"spreadsheet", @0x377437ff ], @"xlsm" : @[ @"spreadsheet", @0x377437ff ],
        @"xltx" : @[ @"spreadsheet", @0x377437ff ], @"gsheet" : @[ @"spreadsheet", @0x0f9d58ff ], @"csv" : @[ @"spreadsheet", @0x3aa3e3ff ],
        @"ppt" : @[ @"presentation", @0xe05a30ff ], @"pptx" : @[ @"presentation", @0xe05a30ff ], @"gpres" : @[ @"presentation", @0xf4b400ff ],
        @"zip" : @[ @"zip", @0x3aa3e3ff ], @"binary" : @[ @"binary", @0x3aa3e3ff ],
        @"text" : @[ @"text", @0x3aa3e3ff ], @"post" : @[ @"document", @0x66c79eff ], @"space" : @[ @"document", @0x66c79eff ],
        @"quip" : @[ @"canvas", @0x3aa3e3ff ], @"canvas" : @[ @"canvas", @0x3aa3e3ff ], @"list" : @[ @"lists", @0x3aa3e3ff ],
    };
    NSArray *known = types[type];
    if (known) {
        *glyph = known[0];
        *tint = (SNColorToken)[known[1] unsignedIntValue];
    } else if ([mime hasPrefix:@"image/"]) *glyph = @"image", *tint = 0x3aa3e3ff;
    else if ([mime hasPrefix:@"video/"]) *glyph = @"video", *tint = 0x3aa3e3ff;
    else if ([mime hasPrefix:@"audio/"]) *glyph = @"headphones", *tint = 0x3aa3e3ff;
    else if ([file.mode isEqualToString:@"snippet"]) *glyph = @"code", *tint = 0x3aa3e3ff;
    else *glyph = @"file", *tint = 0x3aa3e3ff;
}

NSString *SNFileTypeGlyph(SNFile *file) {
    NSString *glyph;
    SNColorToken tint;
    TypeIcon(file, &glyph, &tint);
    return glyph;
}

void SNDrawFileTypeIcon(SNFile *file, NSRect rect) {
    NSString *glyph;
    SNColorToken tint;
    TypeIcon(file, &glyph, &tint);
    [SNColor(tint) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:rect xRadius:SNRadiusLarge yRadius:SNRadiusLarge] fill];
    SNDrawIcon(glyph, 20, 0xffffffff, rect);
}

#pragma mark - Pictures

void SNDrawFilePicture(NSURL *url, NSRect rect, CGFloat radius, NSView *view) {
    NSBezierPath *rounded = [NSBezierPath bezierPathWithRoundedRect:rect xRadius:radius yRadius:radius];
    [SNColor(SNColorBaseTer) setFill];
    [rounded fill];
    CGFloat pixels = MAX(rect.size.width, rect.size.height) * (view.window.backingScaleFactor ?: 2);
    CGImageRef image = url ? [view.imageHolder imageWithURL:url pixels:pixels] : NULL;
    if (image) {
        CGContextRef context = NSGraphicsContext.currentContext.CGContext;
        CGContextSaveGState(context);
        [rounded addClip];
        CGContextTranslateCTM(context, 0, NSMaxY(rect) + NSMinY(rect));
        CGContextScaleCTM(context, 1, -1);
        CGContextDrawImage(context, rect, image);
        CGContextRestoreGState(context);
    }
    // The gallery's inset 1 pt ring over the picture.
    [SNColor(SNColorOtlTer) setStroke];
    [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(rect, 0.5, 0.5) xRadius:radius - 0.5 yRadius:radius - 0.5] stroke];
}

/// Draws `image` covering `rect` (CSS background-size: cover), anchored at the top centre.
static void DrawCoverTop(CGImageRef image, NSRect rect) {
    CGFloat w = CGImageGetWidth(image), h = CGImageGetHeight(image);
    if (w <= 0 || h <= 0) return;
    CGFloat scale = MAX(rect.size.width / w, rect.size.height / h);
    NSRect drawn = NSMakeRect(NSMidX(rect) - w * scale / 2, NSMinY(rect), w * scale, h * scale);
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    CGContextSaveGState(context);
    CGContextClipToRect(context, rect);
    CGContextTranslateCTM(context, 0, NSMaxY(drawn) + NSMinY(drawn));
    CGContextScaleCTM(context, 1, -1);
    CGContextDrawImage(context, drawn, image);
    CGContextRestoreGState(context);
}

#pragma mark - Hover actions

/// The card's actions group: its fill and ring drawn behind the buttons.
@interface SNFileActionGroup : NSView
@end

@implementation SNFileActionGroup

- (BOOL)isFlipped { return YES; }

- (void)drawRect:(NSRect)dirtyRect {
    NSBezierPath *group = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 1, 1) xRadius:SNRadiusXlarge - 1 yRadius:SNRadiusXlarge - 1];
    [SNColor(SNLegacyPrimaryBackground) setFill];
    [group fill];
    [SNColor(SNLegacyHairline) setStroke];
    [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 0.5, 0.5) xRadius:SNRadiusXlarge - 0.5 yRadius:SNRadiusXlarge - 0.5] stroke];
}

@end

/// The snippet's "Show more (N lines)" / "Show less" pill.
@interface SNExpandPill : SNHoverView
@property (nonatomic) BOOL expands;
@property (nonatomic, copy) NSString *label;
@end

@implementation SNExpandPill

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.hoverColor = self.pressedColor = 0;
    return self;
}

+ (NSFont *)font { return SNFont(SNFontSizeCaption, SNFontWeightRegular); }

- (CGFloat)fittingWidth { return ceil(8 + 13 + 4 + SNTextWidth(self.label, SNExpandPill.font) + 8); }

- (void)drawRect:(NSRect)dirtyRect {
    [SNColor(kPillFill) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:kPillHeight / 2 yRadius:kPillHeight / 2] fill];
    SNDrawIcon(self.expands ? @"expand-diagonal" : @"reduce-diagonal", 13, 0xffffffff, NSMakeRect(8, 0, 13, kPillHeight));
    SNDrawText(self.label, SNExpandPill.font, 0xffffffff, kPillHeight, NSTextAlignmentLeft, 1, NSMakeRect(8 + 13 + 4, 0, self.bounds.size.width - 33, kPillHeight));
}

@end

#pragma mark - File view

@implementation SNFileView {
    NSString *_context;
    NSString *_name;
    CGFloat _nameWidth;
    NSView *_actions;
    SNExpandPill *_pill;
    SNCodeLayout *_code;
    CGFloat _codeWidth;
    BOOL _codeExpanded, _loading;
    NSPoint _pressedAt;
}

- (instancetype)initWithFile:(SNFile *)file style:(SNFileStyle)style context:(NSString *)context {
    if (!(self = [super initWithFrame:NSZeroRect])) return nil;
    _file = file;
    _style = style;
    _context = [context copy];
    _name = file.title.length ? file.title : file.name;
    _nameWidth = [self hasMetaLine] ? ceil(SNTextWidth(_name, SNFont(SNFontSizeCaption, SNFontWeightRegular))) : 0;
    self.hoverColor = self.pressedColor = 0;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;
    // The actions fade in over 100 ms (opacity .1s); a card's border changes over the 80 ms default.
    self.transitionDuration = style == SNFileStyleImage ? 0.1 : SNDuration80;
    __weak SNFileView *weakSelf = self;
    self.action = ^(SNFileView *view) { [weakSelf mainAction]; };
    [self updateCursor];
    if (style == SNFileStyleSnippet && Expandable(file)) {
        _pill = [[SNExpandPill alloc] initWithFrame:NSZeroRect];
        _pill.wantsLayer = YES;
        _pill.alphaValue = 0;
        _pill.action = ^(SNExpandPill *pill) { [weakSelf toggleExpansion]; };
        [self addSubview:_pill];
    }
    return self;
}

- (BOOL)hasMetaLine { return _style == SNFileStyleImage || _style == SNFileStyleSnippet || _style == SNFileStyleCollapsed; }

- (void)setMetaTitle:(NSString *)metaTitle {
    _metaTitle = [metaTitle copy];
    _name = metaTitle ?: (_file.title.length ? _file.title : _file.name);
    _nameWidth = ceil(SNTextWidth(_name, SNFont(SNFontSizeCaption, SNFontWeightRegular)));
    self.needsDisplay = YES;
}

/// FilesMetaTextWrapper's collapse button: a 20 pt square around the caret after the name.
- (NSRect)caretRect {
    CGFloat nameWidth = MIN(_nameWidth, self.bounds.size.width - 20);
    return NSMakeRect(nameWidth + 6 + 5 - 10, (kMetaHeight - 20) / 2, 20, 20);
}

- (NSCursor *)cursorAtPoint:(NSPoint)point {
    if (self.toggleFiles && NSPointInRect(point, self.caretRect)) return NSCursor.pointingHandCursor;
    if (_style == SNFileStyleCollapsed) return NSCursor.pointingHandCursor;
    return [super cursorAtPoint:point];
}
- (BOOL)isExpanded { return ExpandedSnippets()[ExpansionKey(_file, _context)] != nil; }

/// effects.txt [B16]: zoom-in over a picture; the hand over a card; nothing over a snippet that
/// does not expand (its text is for reading).
- (void)updateCursor {
    if (_style == SNFileStyleImage) {
        if (@available(macOS 15, *)) self.cursor = NSCursor.zoomInCursor;
    } else if (_style == SNFileStyleSnippet) {
        self.cursor = Expandable(_file) && !self.isExpanded ? nil : NSCursor.arrowCursor;
    }
}

#pragma mark Actions

/// Made on the first hover: a list scrolling past files makes no buttons.
- (void)setHovered:(BOOL)hovered {
    if (hovered && !_actions) [self makeActions];
    [super setHovered:hovered];
}

/// The buttons Slack's hover shows for this kind that do something here: Collapse (an expanded
/// snippet), Download (Slack's own files), open in the browser (where Slack's viewer, sharing and
/// details are) and More.
- (void)makeActions {
    // A video has its own corner button and a clip its own More in the player; collapsed files have
    // only their line.
    if (_style == SNFileStyleVideo || _style == SNFileStyleCollapsed || (_style == SNFileStyleAudio && SNFileIsAudioClip(_file))) return;
    BOOL overlay = _style == SNFileStyleImage;
    NSMutableArray<NSArray *> *specs = [NSMutableArray new];
    __weak SNFileView *weakSelf = self;
    if (_style == SNFileStyleSnippet && self.isExpanded) [specs addObject:@[ @"arrow-collapse", @"channel.file.collapse", ^(SNButton *b) { [weakSelf toggleExpansion]; } ]];
    if (!_file.isExternal) [specs addObject:@[ @"download", @"channel.file.download", ^(SNButton *b) { [weakSelf download]; } ]];
    if (!(_style == SNFileStyleSnippet && IsTable(_file)))
        [specs addObject:@[ @"new-window", @"channel.file.browser", ^(SNButton *b) { [weakSelf openInBrowser]; } ]];
    [specs addObject:@[ @"ellipsis-vertical-filled", @"channel.file.more", ^(SNButton *b) { [weakSelf showMoreFrom:b]; } ]];
    [_actions removeFromSuperview];
    _actions = overlay ? [[NSView alloc] initWithFrame:NSZeroRect] : [[SNFileActionGroup alloc] initWithFrame:NSZeroRect];
    _actions.wantsLayer = YES;
    _actions.alphaValue = self.hovered;
    CGFloat x = overlay ? 0 : kGroupPadding;
    for (NSArray *spec in specs) {
        BOOL more = [spec[0] isEqualToString:@"ellipsis-vertical-filled"];
        CGFloat side = overlay ? kOverlayButton : kGroupButton, width = overlay || !more ? side : kGroupMore;
        SNButton *button = [SNButton iconButtonNamed:spec[0] size:side iconSize:overlay ? 16 : 18];
        if (overlay) {
            button.fillColor = SNColorBaseModal;
            button.hoverFillColor = SNColorBaseInvPry;
            button.borderColor = SNColorOtlInvTer;
            button.cornerRadius = SNRadiusBase;
            button.contentColor = SNColorContentInvSec;
            button.hoverContentColor = button.pressedContentColor = SNColorContentInvPry;
        } else {
            button.hoverFillColor = kGroupButtonHover;
            button.contentColor = SNLegacyForegroundMaxSolid;
            button.hoverContentColor = button.pressedContentColor = SNLegacyPrimaryForeground;
        }
        button.tooltip = SNLocalized(spec[1]);
        button.action = spec[2];
        button.frame = NSMakeRect(x, overlay ? 0 : kGroupPadding, width, side);
        x += width + (overlay ? kOverlayGap : 0);
        [_actions addSubview:button];
    }
    _actions.frame = overlay ? NSMakeRect(0, 0, x - kOverlayGap, kOverlayButton) : NSMakeRect(0, 0, x + kGroupPadding, kGroupButton + 2 * kGroupPadding);
    [self placeActions];
    [self addSubview:_actions];
}

- (NSArray<NSView *> *)actionButtons {
    if (!_actions) [self makeActions];
    return _actions.subviews ?: @[];
}

- (void)placeActions {
    NSSize size = _actions.frame.size, bounds = self.bounds.size;
    CGFloat inset = _style == SNFileStyleImage ? kOverlayInset : kGroupInset;
    _actions.frame = NSMakeRect(bounds.width - inset - size.width, self.topOfFile + inset, size.width, size.height);
}

/// Slack's main action: a card downloads what Slack would download and opens the rest (its
/// viewer's files, other services' files) in the browser; an expandable snippet expands.
- (void)mouseDown:(NSEvent *)event {
    _pressedAt = [self convertPoint:event.locationInWindow fromView:nil];
    [super mouseDown:event];
}

- (void)mainAction {
    if (self.toggleFiles && NSPointInRect(_pressedAt, self.caretRect)) {
        self.toggleFiles();
        return;
    }
    if (_style == SNFileStyleCollapsed) {
        [self openInBrowser];
    } else if (_style == SNFileStyleSnippet) {
        if (Expandable(_file) && !self.isExpanded) [self toggleExpansion];
        // The truncation line's "see it in full".
        else if (self.isExpanded && SnippetShown(_file, _context, NULL).truncated && _pressedAt.y > self.bounds.size.height - kTruncatedHeight) [self openInBrowser];
    } else if (self.downloads) {
        [self download];
    } else {
        [self openInBrowser];
    }
}

/// getMainFileAction's "download": hosted files the media viewer does not show.
- (BOOL)downloads {
    if (_file.isExternal || _style != SNFileStyleCard) return NO;
    return ![_file.fileType isEqualToString:@"pdf"] && ![_file.mimeType hasPrefix:@"image/"];
}

- (void)openInBrowser {
    // Another service's file opens there; Slack's own opens its page in Slack's web client.
    NSURL *url = _file.isExternal ? _file.privateURL ?: _file.permalink : _file.permalink ?: _file.privateURL;
    if (url) [NSWorkspace.sharedWorkspace openURL:url];
}

- (void)download { SNDownloadFile(_file, nil); }

- (void)showMoreFrom:(NSView *)button {
    __weak SNFileView *weakSelf = self;
    NSURL *link = _file.permalink;
    NSMutableArray<SNMenuItem *> *items = [NSMutableArray new];
    [items addObject:[SNMenuItem itemWithTitle:SNLocalized(@"channel.file.browser") action:^{ [weakSelf openInBrowser]; }]];
    if (!_file.isExternal) [items addObject:[SNMenuItem itemWithTitle:SNLocalized(@"channel.file.download") action:^{ [weakSelf download]; }]];
    if (link)
        [items addObject:[SNMenuItem itemWithTitle:SNLocalized(@"channel.file.copylink") action:^{
                   [NSPasteboard.generalPasteboard clearContents];
                   [NSPasteboard.generalPasteboard setString:link.absoluteString forType:NSPasteboardTypeString];
               }]];
    [[[SNMenu alloc] initWithItems:items width:0] showForRect:button.bounds inView:button placement:SNPlacementBelow];
}

#pragma mark Snippet expansion

/// Expanding reads the whole text (the client asks files.info; the file's own URL gives the same
/// text without the highlighting past the preview), then the row lays out again.
- (void)toggleExpansion {
    NSString *key = ExpansionKey(_file, _context);
    if (ExpandedSnippets()[key]) {
        [ExpandedSnippets() removeObjectForKey:key];
        [ExpandedSnippetOrder() removeObject:key];
        [self expansionChanged];
        return;
    }
    if (_loading) return;
    _loading = YES;
    __weak SNFileView *weakSelf = self;
    SNFetchFileText(_file, ^(NSString *text) {
        SNFileView *view = weakSelf;
        if (!view) return;
        view->_loading = NO;
        if (text) [view expandWithContent:text];
    });
}

- (void)expandWithContent:(NSString *)content {
    SNSnippetPreview *preview = [SNSnippetPreview previewOfFile:_file];
    if (!preview) return;
    NSString *key = ExpansionKey(_file, _context);
    ExpandedSnippets()[key] = [preview previewWithContent:content maximumLines:kExpandedLines];
    NSMutableArray<NSString *> *order = ExpandedSnippetOrder();
    [order removeObject:key];
    [order addObject:key];
    while (order.count > 50) {
        NSString *oldest = order.firstObject;
        [order removeObjectAtIndex:0];
        [ExpandedSnippets() removeObjectForKey:oldest];
    }
    [self expansionChanged];
}

- (void)expansionChanged {
    _code = nil;
    [self updateCursor];
    if (_actions) [self makeActions];
    self.needsDisplay = YES;
    if (self.sizeChanged) self.sizeChanged();
}

#pragma mark Layout

- (void)setFrameSize:(NSSize)size {
    if (!NSEqualSizes(size, self.frame.size)) self.needsDisplay = YES;
    [super setFrameSize:size];
}

- (CGFloat)topOfFile { return [self hasMetaLine] ? kMetaHeight : 0; }

- (void)layout {
    [super layout];
    [self placeActions];
    [self placePill];
}

/// Collapsed, "Show more" sits in the middle of the box and rises 12 pt into place on hover;
/// expanded, "Show less" sits 12 pt above the bottom and comes up from 12 pt lower.
- (void)placePill {
    if (!_pill) return;
    BOOL expanded = self.isExpanded;
    _pill.expands = !expanded;
    NSInteger lines = _file.lineCount;
    _pill.label = expanded ? SNLocalized(@"channel.file.less")
                           : lines ? [NSString stringWithFormat:SNLocalized(lines == 1 ? @"channel.file.more.one" : @"channel.file.more.other"), @(lines)]
                                   : SNLocalized(@"channel.file.more.lines");
    CGFloat width = _pill.fittingWidth, top = self.topOfFile;
    CGFloat box = self.bounds.size.height - top - 1 - (expanded && SnippetShown(_file, _context, NULL).truncated ? kTruncatedHeight : 0);
    CGFloat y = expanded ? top + box - 12 - kPillHeight : top + 1 + (box - kPillHeight) / 2;
    CGFloat shift = self.hovered ? 0 : expanded ? 12 : -12;
    _pill.frame = NSMakeRect(round((self.bounds.size.width - width) / 2), y + shift, width, kPillHeight);
    _pill.needsDisplay = YES;
}

- (void)stateDidChange {
    [super stateDidChange];
    _actions.alphaValue = self.hovered;
    _pill.alphaValue = self.hovered;
    [self placePill];
    self.needsDisplay = YES;
}

#pragma mark Drawing

- (void)drawRect:(NSRect)dirtyRect {
    switch (_style) {
    case SNFileStyleCollapsed: [self drawMetaLine]; break;
    case SNFileStyleImage: [self drawPicture]; break;
    case SNFileStyleSnippet: [self drawSnippet]; break;
    default: [self drawCard]; break;
    }
}

- (void)drawMetaLine {
    SNColorToken meta = SNColorWithAlpha(SNLegacyForegroundMax, kMetaAlpha);
    CGFloat nameWidth = MIN(_nameWidth, self.bounds.size.width - 20);
    SNDrawText(_name, SNFont(SNFontSizeCaption, SNFontWeightRegular), meta, kMetaHeight, NSTextAlignmentLeft, 1, NSMakeRect(0, 0, nameWidth, kMetaHeight));
    SNDrawIcon(_style == SNFileStyleCollapsed ? @"caret-right-filled" : @"caret-down-filled", SNFontSizeCaption, meta, NSMakeRect(nameWidth + 6, 7, 10, 8));
}

- (void)drawPicture {
    [self drawMetaLine];
    NSRect picture = NSMakeRect(0, kMetaHeight, self.bounds.size.width, self.bounds.size.height - kMetaHeight);
    CGFloat pixels = MAX(picture.size.width, picture.size.height) * (self.window.backingScaleFactor ?: 2);
    SNDrawFilePicture([_file thumbnailURLForPixels:pixels], picture, SNRadiusLarge, self);
}

/// The card's frame: base-pry, 1 pt otl-ter border (otl-sec hovered), radius 12; `rect` is its
/// outer edge. Returns the path inside the border, to clip what fills the card.
- (NSBezierPath *)drawCardFrame:(NSRect)rect {
    NSBezierPath *card = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(rect, 0.5, 0.5) xRadius:SNRadiusXlarge - 0.5 yRadius:SNRadiusXlarge - 0.5];
    [SNColor(SNColorBasePry) setFill];
    [card fill];
    return [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(rect, 1, 1) xRadius:SNRadiusXlarge - 1 yRadius:SNRadiusXlarge - 1];
}

- (void)strokeCardFrame:(NSRect)rect {
    [SNColor(self.hovered ? SNColorOtlSec : SNColorOtlTer) setStroke];
    [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(rect, 0.5, 0.5) xRadius:SNRadiusXlarge - 0.5 yRadius:SNRadiusXlarge - 0.5] stroke];
}

- (void)drawCard {
    NSRect bounds = self.bounds;
    NSBezierPath *inside = [self drawCardFrame:bounds];
    NSRect icon = NSMakeRect(1 + kCardPadding, 1 + kCardPadding, kCardIcon, kCardIcon);
    SNDrawFileTypeIcon(_file, icon);
    CGFloat x = NSMaxX(icon) + 12, width = bounds.size.width - x - 1 - kCardPadding - 8;
    SNDrawText(_name, SNFont(SNFontSizeBase, SNFontWeightBold), SNLegacyPrimaryForeground, kTitleLine, NSTextAlignmentLeft, 1, NSMakeRect(x, kTitleTop, width, kTitleLine));
    [self drawDescriptionAt:NSMakeRect(x, kKindTop, width + 8, kKindLine)];
    if (_style == SNFileStyleDocument) {
        CGFloat top = 1 + kCardPadding + kCardIcon + kDocumentGap;
        NSRect preview = NSMakeRect(1, top + 1, bounds.size.width - 2, kDocumentPreview);
        [SNColor(SNLegacyForegroundLowSolid) setFill];
        [NSBezierPath fillRect:NSMakeRect(1, top, bounds.size.width - 2, 1)];
        // thumb_800 || thumb_480 || thumb_pdf, as the client picks it.
        NSURL *url = _file.thumbnailURLs[@800] ?: _file.thumbnailURLs[@480] ?: _file.pdfThumbnailURL;
        // Decoded by its longer side: a portrait page needs that side long enough for the width.
        CGSize page = _file.pdfThumbnailSize;
        CGFloat pixels = preview.size.width * (self.window.backingScaleFactor ?: 2) * (page.width > 0 ? MAX(1, page.height / page.width) : 1);
        CGImageRef image = [self.imageHolder imageWithURL:url pixels:pixels];
        if (image) {
            [NSGraphicsContext saveGraphicsState];
            [inside addClip];
            DrawCoverTop(image, preview);
            [NSGraphicsContext restoreGraphicsState];
        }
    }
    [self strokeCardFrame:bounds];
}

/// The kind ("PDF"); hovered, what a click does: "Download **Word Document**" or "Open in browser".
- (void)drawDescriptionAt:(NSRect)rect {
    NSFont *font = SNFont(SNFontSizeCaption, SNFontWeightRegular);
    NSString *kind = SNFileDescription(_file);
    if (!self.hovered || _style == SNFileStyleSnippet) {
        SNDrawText(kind, font, SNLegacyForegroundMaxSolid, kKindLine, NSTextAlignmentLeft, 1, rect);
        return;
    }
    if (!self.downloads) {
        SNDrawText(SNLocalized(@"channel.file.hover.browser"), font, SNLegacyForegroundMaxSolid, kKindLine, NSTextAlignmentLeft, 1, rect);
        return;
    }
    // "Baixar %@": the words around the bold kind.
    NSArray<NSString *> *parts = [SNLocalized(@"channel.file.hover.download") componentsSeparatedByString:@"%@"];
    NSFont *bold = SNFont(SNFontSizeCaption, SNFontWeightBold);
    CGFloat x = NSMinX(rect);
    NSArray *pieces = @[ @[ parts.firstObject ?: @"", font ], @[ kind, bold ], @[ parts.count > 1 ? parts[1] : @"", font ] ];
    for (NSArray *piece in pieces) {
        NSString *text = piece[0];
        if (!text.length) continue;
        CGFloat width = ceil([text sizeWithAttributes:@{NSFontAttributeName : piece[1]}].width);
        SNDrawText(text, piece[1], SNLegacyForegroundMaxSolid, kKindLine, NSTextAlignmentLeft, 1, NSMakeRect(x, NSMinY(rect), MAX(0, NSMaxX(rect) - x), kKindLine));
        x += width;
        if (x >= NSMaxX(rect)) break;
    }
}

- (void)drawSnippet {
    [self drawMetaLine];
    NSRect bounds = self.bounds;
    NSRect card = NSMakeRect(0, kMetaHeight, bounds.size.width, bounds.size.height - kMetaHeight);
    NSBezierPath *inside = [self drawCardFrame:card];
    BOOL expanded;
    SNSnippetPreview *preview = SnippetShown(_file, _context, &expanded);
    BOOL collapsed = !expanded && Expandable(_file);
    CGFloat textWidth = card.size.width - kCodeLeft - kCodeRight;
    if (!_code || _codeWidth != textWidth || _codeExpanded != expanded) {
        _code = preview ? [SNCodeLayout layoutWithPreview:preview width:textWidth limit:collapsed ? kCollapsedHeight : CGFLOAT_MAX] : nil;
        _codeWidth = textWidth;
        _codeExpanded = expanded;
    }
    CGFloat boxHeight = card.size.height - 2 - (expanded && preview.truncated ? kTruncatedHeight : 0);
    NSRect box = NSMakeRect(1, NSMinY(card) + 1, card.size.width - 2, boxHeight);
    [NSGraphicsContext saveGraphicsState];
    [inside addClip];
    NSRectClip(box);
    if (_code.columns) [self drawTable:preview inBox:box];
    else [self drawLinesInBox:box];
    if (collapsed) {
        // The 40 pt fade into the card's colour at the bottom.
        NSGradient *fade = [[NSGradient alloc] initWithStartingColor:SNColor(SNColorWithAlpha(SNColorBasePry, 0)) endingColor:SNColor(SNColorBasePry)];
        [fade drawInRect:NSMakeRect(NSMinX(box), NSMaxY(box) - kFade, box.size.width, kFade) angle:90];
    }
    [NSGraphicsContext restoreGraphicsState];
    if (expanded && preview.truncated) [self drawTruncatedLineBelow:box];
    [self strokeCardFrame:card];
}

- (void)drawLinesInBox:(NSRect)box {
    // The gutter: surf-pry with an otl-ter rule, line numbers right-aligned at 50%.
    [SNColor(SNColorOver(SNColorSurfPry, SNColorBasePry)) setFill];
    [NSBezierPath fillRect:NSMakeRect(NSMinX(box), NSMinY(box), kGutter, box.size.height)];
    [SNColor(SNColorOtlTer) setFill];
    [NSBezierPath fillRect:NSMakeRect(NSMinX(box) + kGutter - 1, NSMinY(box), 1, box.size.height)];
    NSFont *mono = SNMonoFont(13, SNFontWeightRegular);
    CGFloat baseline = SNBaselineOffset(mono, kCodeLine);
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    for (NSUInteger i = 0; i < _code.rows.count; i++) {
        CGFloat top = NSMinY(box) + _code.tops[i].doubleValue;
        if (top > NSMaxY(box)) break;
        SNDrawText(@(i + 1).stringValue, mono, 0xe8e8e880, kCodeLine, NSTextAlignmentRight, 1, NSMakeRect(NSMinX(box), top, kGutter - 1 - 4, kCodeLine));
        NSArray *lines = _code.rows[i];
        CGContextSaveGState(context);
        CGContextSetShouldSmoothFonts(context, false);
        CGContextSetTextMatrix(context, CGAffineTransformMakeScale(1, -1));
        for (NSUInteger j = 0; j < lines.count; j++) {
            // Browsers put each baseline on a whole device pixel.
            CGPoint origin = CGContextConvertPointToDeviceSpace(context, CGPointMake(NSMinX(box) - 1 + kCodeLeft, top + j * kCodeLine + baseline));
            origin = CGContextConvertPointToUserSpace(context, CGPointMake(origin.x, round(origin.y)));
            CGContextSetTextPosition(context, origin.x, origin.y);
            CTLineDraw((__bridge CTLineRef)lines[j], context);
        }
        CGContextRestoreGState(context);
    }
}

- (void)drawTable:(SNSnippetPreview *)preview inBox:(NSRect)box {
    NSFont *mono = SNMonoFont(13, SNFontWeightRegular);
    NSArray<NSNumber *> *columns = _code.columns;
    for (NSUInteger i = 0; i < _code.rows.count; i++) {
        NSArray<NSString *> *row = _code.rows[i];
        NSIndexSet *numbers = i < preview.numericCells.count ? preview.numericCells[i] : nil;
        CGFloat top = NSMinY(box) + _code.tops[i].doubleValue, x = NSMinX(box), height = kCodeLine + 2 * kCellPadding;
        if (top > NSMaxY(box)) break;
        for (NSUInteger c = 0; c < row.count && c < columns.count && x < NSMaxX(box); c++) {
            CGFloat width = columns[c].doubleValue;
            NSRect text = NSMakeRect(x + kCellPadding, top + kCellPadding, width - 2 * kCellPadding, kCodeLine);
            SNDrawText(row[c], mono, SNLegacyPrimaryForeground, kCodeLine, [numbers containsIndex:c] ? NSTextAlignmentRight : NSTextAlignmentLeft, 1, text);
            // Right and bottom rules only, none under the last row.
            [SNColor(SNLegacyHairline) setFill];
            [NSBezierPath fillRect:NSMakeRect(x + width, top, 1, height + 1)];
            x += width + 1;
        }
        [SNColor(SNLegacyHairline) setFill];
        if (i + 1 < preview.rows.count) [NSBezierPath fillRect:NSMakeRect(NSMinX(box), top + height, x - NSMinX(box), 1)];
    }
}

/// "This snippet was truncated for display; see it in full" under a rule.
- (void)drawTruncatedLineBelow:(NSRect)box {
    CGFloat top = NSMaxY(box);
    [SNColor(SNColorOtlTer) setFill];
    [NSBezierPath fillRect:NSMakeRect(NSMinX(box), top, box.size.width, 1)];
    NSFont *font = SNFont(SNFontSizeCaption, SNFontWeightRegular);
    NSString *text = SNLocalized(@"channel.file.truncated"), *link = SNLocalized(@"channel.file.truncated.link");
    CGFloat x = NSMinX(box) + 8;
    SNDrawIcon(@"info", 13, kMetaColor, NSMakeRect(x, top + 1, 13, kTruncatedHeight - 1));
    x += 13 + 4;
    CGFloat width = ceil([text sizeWithAttributes:@{NSFontAttributeName : font}].width);
    SNDrawText(text, font, kMetaColor, kTruncatedHeight - 1, NSTextAlignmentLeft, 1, NSMakeRect(x, top + 1, NSMaxX(box) - x, kTruncatedHeight - 1));
    SNDrawText(link, font, SNLegacyHighlight, kTruncatedHeight - 1, NSTextAlignmentLeft, 1, NSMakeRect(x + width, top + 1, MAX(0, NSMaxX(box) - x - width), kTruncatedHeight - 1));
}

@end

#pragma mark - Sizes

NSSize SNFileViewSize(SNFile *file, SNFileStyle style, CGFloat width, NSString *context) {
    switch (style) {
    case SNFileStyleImage: {
        CGSize size = file.originalSize.width > 0 && file.originalSize.height > 0 ? file.originalSize : CGSizeMake(360, 240);
        CGFloat scale = MIN(1, MIN(MIN(width, kImageMaxWidth) / size.width, kImageMaxHeight / size.height));
        return NSMakeSize(round(size.width * scale), kMetaHeight + round(size.height * scale));
    }
    case SNFileStyleVideo:
    case SNFileStyleAudio: return SNMediaViewSize(file, style, width);
    case SNFileStyleSnippet: {
        // A lone snippet spans the column (.p-message_file--snippet has no max-width).
        CGFloat cardWidth = MAX(kCardMinWidth, width);
        return NSMakeSize(cardWidth, kMetaHeight + SnippetHeight(file, context, cardWidth));
    }
    case SNFileStyleDocument:
        // The page takes the bottom padding's place (margin-bottom: -12px).
        return NSMakeSize(MAX(kCardMinWidth, MIN(width, kCardWidth)), kCardHeight - kCardPadding + kDocumentGap + 1 + kDocumentPreview);
    case SNFileStyleCard: return NSMakeSize(MAX(kCardMinWidth, MIN(width, kCardWidth)), kCardHeight);
    case SNFileStyleCollapsed: return NSZeroSize;
    }
    return NSZeroSize;
}

NSSize SNCollapsedFilesSize(NSString *title, CGFloat width) {
    CGFloat text = ceil(SNTextWidth(title, SNFont(SNFontSizeCaption, SNFontWeightRegular)));
    return NSMakeSize(MIN(width, text + 6 + 15), kMetaHeight);
}

SNFileView *SNMakeFileView(SNFile *file, SNFileStyle style, NSString *context) {
    if (style == SNFileStyleVideo || style == SNFileStyleAudio) return SNMakeMediaView(file, style, context);
    return [[SNFileView alloc] initWithFile:file style:style context:context];
}
