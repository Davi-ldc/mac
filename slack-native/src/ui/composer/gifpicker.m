// Owns the GIF picker: its search, grid and states, and the attachment a pick becomes.
#import "model/json.h"
#import "render/images.h"
#import "render/strings.h"
#import "ui/composer/gifpicker.h"
#import "ui/kit/button.h"
#import "ui/kit/forms.h"
#import "ui/kit/label.h"
#import "ui/kit/popover.h"

/// .p-gif_picker: 361 x 468 (at most the window less 200), 12 pt above the header, which is 12 pt in
/// and 12 above the grid; rows 4/12 padding, tiles a third of the row less 6, 100 tall, 6 apart,
/// radius 8 with a 1 pt ring, at 70% under the pointer.
static const CGFloat kWidth = 361, kHeight = 468, kTop = 12, kPadding = 12, kTileHeight = 100, kTileMargin = 6, kRowPadding = 4;
static const NSTimeInterval kSearchDelay = 0.36;

/// gif.media_formats' rendition: tinygif in the grid, gif in the message.
static NSDictionary *Format(NSDictionary *gif, NSString *name) { return SNJSONObject(SNJSONObject(gif, @"media_formats"), name); }

NSDictionary *SNGifAttachment(NSDictionary *gif) {
    NSDictionary *full = Format(gif, @"gif") ?: Format(gif, @"tinygif") ?: @{};
    NSArray *dims = SNJSONArray(full, @"dims");
    NSString *name = SNJSONString(gif, @"content_description");
    NSString *fallback = name.length ? name : @"GIF";
    NSMutableDictionary *image = [@{@"type" : @"image", @"block_id" : [NSUUID.UUID.UUIDString substringToIndex:5], @"image_url" : SNJSONString(full, @"url") ?: @"",
                                    @"alt_text" : fallback, @"is_animated" : @YES, @"fallback" : fallback,
                                    @"title" : @{@"type" : @"plain_text", @"text" : @"GIF", @"emoji" : @YES}} mutableCopy];
    if (dims.count == 2) {
        image[@"image_width"] = dims[0];
        image[@"image_height"] = dims[1];
    }
    if (full[@"size"]) image[@"image_bytes"] = full[@"size"];
    return @{@"blocks" : @[ image ]};
}

@interface SNGifTile : SNHoverView
@property (nonatomic, nullable) NSURL *url;
@end

@implementation SNGifTile

- (BOOL)isFlipped { return YES; }

- (void)setUrl:(NSURL *)url {
    _url = url;
    [self.imageHolder removeAllImages];
    self.needsDisplay = YES;
}

- (void)stateDidChange {
    [super stateDidChange];
    self.alphaValue = self.hovered ? 0.7 : 1;
}

- (void)drawRect:(NSRect)dirtyRect {
    NSBezierPath *frame = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 0.5, 0.5) xRadius:SNRadiusLarge yRadius:SNRadiusLarge];
    [NSGraphicsContext saveGraphicsState];
    [frame addClip];
    [SNColor(SNColorBaseTer) setFill];
    NSRectFill(self.bounds);
    CGImageRef image = _url ? [self.imageHolder imageWithURL:_url pixels:400] : NULL;
    if (image) {
        // Covers the tile, centred, as object-fit: cover.
        CGFloat scale = MAX(NSWidth(self.bounds) / CGImageGetWidth(image), NSHeight(self.bounds) / CGImageGetHeight(image));
        CGSize size = CGSizeMake(CGImageGetWidth(image) * scale, CGImageGetHeight(image) * scale);
        CGContextRef context = NSGraphicsContext.currentContext.CGContext;
        CGContextSaveGState(context);
        CGContextTranslateCTM(context, 0, NSHeight(self.bounds));
        CGContextScaleCTM(context, 1, -1);
        CGContextDrawImage(context, CGRectMake((NSWidth(self.bounds) - size.width) / 2, (NSHeight(self.bounds) - size.height) / 2, size.width, size.height), image);
        CGContextRestoreGState(context);
    }
    [NSGraphicsContext restoreGraphicsState];
    [SNColor(SNColorOtlTer) setStroke];
    [frame stroke];
}

@end

@interface SNGifGrid : NSView
@end

@implementation SNGifGrid
- (BOOL)isFlipped { return YES; }
@end

@implementation SNGifPicker {
    id<SNSource> _source;
    void (^_picked)(NSDictionary *, NSURL *);
    SNFormInput *_field;
    NSScrollView *_scroll;
    SNGifGrid *_grid;
    SNLabel *_title, *_text;
    SNButton *_clear;
    SNPopover *_popover;
    NSInteger _request;
}

static __weak SNGifPicker *current;

+ (SNGifPicker *)current { return current; }

+ (instancetype)showForRect:(NSRect)rect inView:(NSView *)view source:(id<SNSource>)source query:(NSString *)query picked:(void (^)(NSDictionary *, NSURL *))picked {
    if (!view.window) return nil;
    CGFloat height = MIN(kHeight, NSHeight(view.window.contentView.bounds) - 200);
    SNGifPicker *picker = [[self alloc] initWithFrame:NSMakeRect(0, 0, kWidth, MAX(200, height))];
    picker->_source = source;
    picker->_picked = [picked copy];
    SNPanelView *panel = [[SNPanelView alloc] initWithFill:SNColorBasePry radius:SNRadiusMenuLive shadow:SNMenuShadow];
    panel.frame = picker.frame;
    picker.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [panel.contentView addSubview:picker];
    picker->_popover = [SNPopover showContent:panel forRect:rect inView:view placement:SNPlacementAbove gap:4];
    if (!picker->_popover) return nil;
    picker->_field.text = query;
    [picker->_field focus];
    [picker runSearch:query reason:@"gif-picker:initial-search"];
    current = picker;
    return picker;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _gifs = @[];
    __weak SNGifPicker *weakSelf = self;
    _field = [[SNFormInput alloc] initWithPlaceholder:SNLocalized(@"composer.gif.search") icon:@"search"];
    _field.changed = ^(NSString *text) {
        SNGifPicker *picker = weakSelf;
        [NSObject cancelPreviousPerformRequestsWithTarget:picker selector:@selector(typed) object:nil];
        [picker performSelector:@selector(typed) withObject:nil afterDelay:kSearchDelay];
    };
    _scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    _scroll.drawsBackground = NO;
    _scroll.hasVerticalScroller = YES;
    _scroll.scrollerStyle = NSScrollerStyleOverlay;
    _scroll.autohidesScrollers = YES;
    _grid = [[SNGifGrid alloc] initWithFrame:NSZeroRect];
    _scroll.documentView = _grid;
    _title = [SNLabel labelWithText:@"" font:SNFont(SNFontSizeBase, SNFontWeightBold) color:SNColorContentPry];
    _title.alignment = NSTextAlignmentCenter;
    _text = [SNLabel labelWithText:@"" font:SNFont(SNFontSizeCaption, SNFontWeightRegular) color:SNColorContentSec];
    _text.alignment = NSTextAlignmentCenter;
    _text.maximumLines = 0;
    _clear = [SNButton outlineButtonWithTitle:SNLocalized(@"composer.gif.clear")];
    _clear.font = SNFont(SNFontSizeCaption, SNFontWeightBold);
    _clear.action = ^(SNButton *button) {
        SNGifPicker *picker = weakSelf;
        picker->_field.text = @"";
        [picker search:@""];
    };
    for (NSView *view in @[ _field, _scroll, _title, _text, _clear ]) [self addSubview:view];
    [self showState:nil text:nil clear:NO];
    return self;
}

- (void)dealloc { [NSObject cancelPreviousPerformRequestsWithTarget:self]; }

- (BOOL)isFlipped { return YES; }

- (void)close { [_popover close]; }

- (void)layout {
    [super layout];
    CGFloat width = NSWidth(self.bounds);
    _field.frame = NSMakeRect(kPadding, kTop, width - 2 * kPadding, SNFormControlHeight);
    CGFloat top = NSMaxY(_field.frame) + kPadding;
    _scroll.frame = NSMakeRect(0, top, width, MAX(0, NSHeight(self.bounds) - top));
    _title.frame = NSMakeRect(kPadding, top + 80, width - 2 * kPadding, 22);
    CGFloat text = [_text heightForWidth:width - 4 * kPadding];
    _text.frame = NSMakeRect(2 * kPadding, top + 106, width - 4 * kPadding, text);
    CGFloat clearWidth = ceil(_clear.fittingContentSize.width) + 24;
    _clear.frame = NSMakeRect(round((width - clearWidth) / 2), NSMaxY(_text.frame) + 16, clearWidth, 28);
    [self layoutGrid];
}

- (void)layoutGrid {
    CGFloat width = NSWidth(self.bounds), inner = width - 2 * kPadding;
    CGFloat tile = floor(inner * 0.33 - kTileMargin);
    NSArray<NSView *> *tiles = _grid.subviews;
    for (NSUInteger i = 0; i < tiles.count; i++) {
        NSUInteger row = i / 3, column = i % 3;
        tiles[i].frame = NSMakeRect(kPadding + column * (tile + 2 * kTileMargin) + kTileMargin / 2, kRowPadding + row * (kTileHeight + 2 * kTileMargin), tile, kTileHeight);
    }
    NSUInteger rows = (tiles.count + 2) / 3;
    _grid.frame = NSMakeRect(0, 0, width, 2 * kRowPadding + rows * (kTileHeight + 2 * kTileMargin));
}

- (void)typed { [self runSearch:_field.text reason:@"gif-picker:search"]; }

- (void)search:(NSString *)query { [self runSearch:query reason:@"gif-picker:search"]; }

- (void)runSearch:(NSString *)query reason:(NSString *)reason {
    // Spaces alone search nothing new.
    if (query.length && ![query stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].length) return;
    NSInteger request = ++_request;
    __weak SNGifPicker *weakSelf = self;
    [_source searchGIFs:query reason:reason completion:^(NSArray<NSDictionary *> *gifs, NSString *error) {
        SNGifPicker *picker = weakSelf;
        if (!picker || request != picker->_request) return;
        [picker showGifs:gifs error:error];
    }];
}

- (void)showGifs:(NSArray<NSDictionary *> *)gifs error:(NSString *)error {
    _gifs = gifs ?: @[];
    for (NSView *tile in [_grid.subviews copy]) [tile removeFromSuperview];
    __weak SNGifPicker *weakSelf = self;
    for (NSUInteger i = 0; i < _gifs.count; i++) {
        SNGifTile *tile = [[SNGifTile alloc] initWithFrame:NSZeroRect];
        tile.hoverColor = tile.pressedColor = 0;
        tile.tooltip = SNJSONString(_gifs[i], @"content_description");
        tile.url = SNJSONURL(Format(_gifs[i], @"tinygif") ?: Format(_gifs[i], @"gif"), @"url");
        tile.action = ^(SNGifTile *clicked) { [weakSelf pickAtIndex:i]; };
        [_grid addSubview:tile];
    }
    if (error) [self showState:SNLocalized(@"composer.gif.downTitle") text:SNLocalized(@"composer.gif.downText") clear:NO];
    else if (!_gifs.count) [self showState:SNLocalized(@"composer.gif.emptyTitle") text:SNLocalized(@"composer.gif.emptyText") clear:YES];
    else [self showState:nil text:nil clear:NO];
    [self layoutGrid];
}

- (void)showState:(NSString *)title text:(NSString *)text clear:(BOOL)clear {
    _title.text = title ?: @"";
    _text.text = text ?: @"";
    _title.hidden = _text.hidden = !title;
    _clear.hidden = !clear;
    self.needsLayout = YES;
}

- (void)pickAtIndex:(NSUInteger)index {
    if (index >= _gifs.count) return;
    NSDictionary *gif = _gifs[index];
    NSURL *preview = SNJSONURL(Format(gif, @"tinygif") ?: Format(gif, @"gif"), @"url");
    void (^picked)(NSDictionary *, NSURL *) = _picked;
    [self close];
    if (picked) picked(SNGifAttachment(gif), preview);
}

@end
