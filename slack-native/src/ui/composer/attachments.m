// Owns drawing the composer's attached files, their status circles and the row's scrolling.
#import "render/file.h"
#import "render/icon.h"
#import "render/images.h"
#import "render/strings.h"
#import "ui/composer/attachments.h"
#import "ui/files/fileview.h"
#import "ui/kit/button.h"
#import "ui/kit/label.h"

/// Items (client-boot-styles: .p-multi_file_upload__file_gallery padding 8, margin-right 12; the
/// thumbnail and .c-pillow_file 62 pt high, the card 208 pt of content in 12 pt padding and a 1 pt
/// border; the status button 22 pt, 10 pt past the item's top-right corner).
static const CGFloat kInset = 8, kItem = 62, kGap = 12, kCardWidth = 234, kRadius = 12, kCardPadding = 12, kTypeIcon = 36;
static const CGFloat kStatus = 22, kStatusReach = 10, kStatusGlyph = 20, kClose = 12, kSpinner = 16, kWarning = 20;
/// The arrows: 32 pt, 12 pt past the row's ends, hidden at that end of the row; a click scrolls
/// 250 pt over 160 ms.
static const CGFloat kArrow = 32, kArrowReach = 12, kPage = 250;
static const CFTimeInterval kPageDuration = 0.16;
/// The pending thumbnail's fill (sk_foreground_min at 4%) and ring; the ring over a picture.
static const SNColorToken kPendingFill = 0xe8e8e80a, kPendingRing = SNLegacyForegroundLowSolid, kPictureRing = 0xe8e8e821, kPictureRingHover = 0x00000026;
/// A sent picture dims under the pointer (filter: brightness(70%)).
static const SNColorToken kPictureDim = 0x0000004d;
static const SNColorToken kKind = SNLegacyForegroundMaxSolid;

#pragma mark Spinner

/// Slack's 16 pt spinner: a faint track and a quarter arc in content-hgl-1 turning every 1.2 s.
@interface SNComposerSpinnerLayer : SNLayer
@end

@implementation SNComposerSpinnerLayer

- (instancetype)init {
    if (!(self = [super init])) return nil;
    self.contentsScale = 2;
    self.needsDisplayOnBoundsChange = YES;
    return self;
}

- (void)drawInContext:(CGContextRef)context {
    CGFloat side = self.bounds.size.width, radius = side * 0.35, width = side * 0.08;
    CGPoint centre = CGPointMake(side / 2, side / 2);
    CGContextSetLineWidth(context, width);
    CGContextSetLineCap(context, kCGLineCapRound);
    CGContextSetStrokeColorWithColor(context, SNCGColor(SNColorWithAlpha(SNColorContentTer, 0.25)));
    CGContextAddArc(context, centre.x, centre.y, radius, 0, 2 * M_PI, 0);
    CGContextStrokePath(context);
    // dasharray 55 of a 2π·35 circumference.
    CGContextSetStrokeColorWithColor(context, SNCGColor(SNColorContentHgl1));
    CGContextAddArc(context, centre.x, centre.y, radius, M_PI_2, M_PI_2 + 2 * M_PI * 55 / (2 * M_PI * 35), 0);
    CGContextStrokePath(context);
}

- (void)spin {
    if ([self animationForKey:@"spin"]) return;
    CABasicAnimation *spin = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
    spin.fromValue = @0;
    spin.toValue = @(-2 * M_PI);
    spin.duration = 1.2;
    spin.repeatCount = HUGE_VALF;
    spin.timingFunction = [CAMediaTimingFunction functionWithControlPoints:0.25:0.29:0.54:0.86];
    [self addAnimation:spin forKey:@"spin"];
}

@end

#pragma mark Items

/// The status circle's button: the item redraws the circle as the pointer enters or leaves it.
@interface SNComposerStatusButton : SNHoverView
@property (nonatomic, copy, nullable) void (^stateChanged)(void);
@end

@implementation SNComposerStatusButton
- (void)stateDidChange {
    [super stateDidChange];
    if (self.stateChanged) self.stateChanged();
}
@end

/// One attached file, with room above and to the right for its status circle.
@interface SNComposerAttachmentItem : SNHoverView
@property (nonatomic) SNUpload *upload;
@property (nonatomic, readonly) SNHoverView *status;
@property (nonatomic, readonly) CGFloat itemWidth;
@end

@implementation SNComposerAttachmentItem {
    SNFile *_file;
    SNComposerSpinnerLayer *_spinner;
}

- (instancetype)initWithUpload:(SNUpload *)upload {
    if (!(self = [super initWithFrame:NSZeroRect])) return nil;
    self.hoverColor = self.pressedColor = 0;
    self.cursor = NSCursor.arrowCursor;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;
    self.transitionDuration = 0.1;
    SNComposerStatusButton *status = [[SNComposerStatusButton alloc] initWithFrame:NSZeroRect];
    __weak SNComposerAttachmentItem *weakSelf = self;
    status.stateChanged = ^{
        [weakSelf updateStatus];
        weakSelf.needsDisplay = YES;
    };
    _status = status;
    _status.hoverColor = _status.pressedColor = 0;
    _status.tooltip = SNLocalized(@"composer.attachment.remove");
    _status.wantsLayer = YES;
    _spinner = [SNComposerSpinnerLayer layer];
    [_status.layer addSublayer:_spinner];
    [self addSubview:_status];
    self.upload = upload;
    return self;
}

- (BOOL)isFlipped { return YES; }

- (CGFloat)itemWidth { return self.upload.isImage ? kItem : kCardWidth; }

- (void)setUpload:(SNUpload *)upload {
    _upload = upload;
    _file = [SNFile fileWithJSON:upload.fileJSON];
    [self setFrameSize:NSMakeSize(self.itemWidth + kStatusReach, kItem + kStatusReach)];
    _status.frame = NSMakeRect(self.itemWidth + kStatusReach - kStatus, 0, kStatus, kStatus);
    [self updateStatus];
    self.needsDisplay = YES;
}

- (NSRect)body { return NSMakeRect(0, kStatusReach, self.itemWidth, kItem); }

- (void)stateDidChange {
    [super stateDidChange];
    [self updateStatus];
    self.needsDisplay = YES;
}

- (BOOL)isWorking { return self.upload.state == SNUploadUploading || self.upload.state == SNUploadProcessing; }

/// RemoveFileButton: the button shows the remove x under the pointer, else the spinner while the
/// file works, the warning once it failed, and the x again once it is up.
- (BOOL)showsRemove { return _status.hovered || (!self.isWorking && self.upload.state != SNUploadFailed); }

/// A remove x shows only while the file is hovered (.p-multi_file_upload__file_status_btn--remove
/// is at opacity 0 otherwise); the spinner and the warning always show.
- (void)updateStatus {
    BOOL removing = [self showsRemove];
    _status.alphaValue = !removing || self.hovered || _status.hovered ? 1 : 0;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _spinner.frame = CGRectMake((kStatus - kSpinner) / 2, (kStatus - kSpinner) / 2, kSpinner, kSpinner);
    _spinner.hidden = removing || !self.isWorking;
    if (!_spinner.hidden) [_spinner spin];
    else [_spinner removeAnimationForKey:@"spin"];
    [CATransaction commit];
    _status.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    CGContextSetShouldSmoothFonts(NSGraphicsContext.currentContext.CGContext, false);
    if (self.upload.isImage) [self drawPicture];
    else [self drawCard];
    [self drawStatus];
}

- (void)drawPicture {
    NSRect body = self.body;
    NSBezierPath *shape = [NSBezierPath bezierPathWithRoundedRect:body xRadius:kRadius yRadius:kRadius];
    CGImageRef image = [self.imageHolder imageWithURL:self.upload.fileURL pixels:kItem * 2];
    if (!image) {
        [SNColor(kPendingFill) setFill];
        [shape fill];
        [SNColor(kPendingRing) setStroke];
        [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(body, 0.5, 0.5) xRadius:kRadius - 0.5 yRadius:kRadius - 0.5] stroke];
        return;
    }
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    CGContextSaveGState(context);
    [shape addClip];
    // background-size: cover, centred.
    CGFloat w = CGImageGetWidth(image), h = CGImageGetHeight(image), scale = MAX(kItem / w, kItem / h);
    NSRect drawn = NSMakeRect(NSMidX(body) - w * scale / 2, NSMidY(body) - h * scale / 2, w * scale, h * scale);
    CGContextTranslateCTM(context, 0, NSMaxY(drawn) + NSMinY(drawn));
    CGContextScaleCTM(context, 1, -1);
    CGContextDrawImage(context, drawn, image);
    CGContextRestoreGState(context);
    BOOL ready = self.upload.state == SNUploadReady;
    if (self.hovered && ready) {
        [SNColor(kPictureDim) setFill];
        [shape fill];
    }
    [SNColor(self.hovered && !ready ? kPictureRingHover : kPictureRing) setStroke];
    [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(body, 0.5, 0.5) xRadius:kRadius - 0.5 yRadius:kRadius - 0.5] stroke];
}

- (void)drawCard {
    NSRect body = self.body;
    NSBezierPath *outline = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(body, 0.5, 0.5) xRadius:kRadius - 0.5 yRadius:kRadius - 0.5];
    [SNColor(SNColorBasePry) setFill];
    [outline fill];
    [SNColor(self.hovered ? SNColorOtlSec : SNColorOtlTer) setStroke];
    [outline stroke];
    NSRect icon = NSMakeRect(NSMinX(body) + 1 + kCardPadding, NSMinY(body) + 1 + kCardPadding, kTypeIcon, kTypeIcon);
    SNDrawFileTypeIcon(_file, icon);
    // The name (bold, line-height 1.5, 4 pt up, 8 pt clear of the edge) over the kind (13 pt).
    CGFloat x = NSMaxX(icon) + kCardPadding, width = NSMaxX(body) - 1 - kCardPadding - x;
    CGFloat nameTop = NSMinY(icon) - 4, nameLine = SNFontSizeBase * 1.5;
    SNDrawText(self.upload.name, SNFont(SNFontSizeBase, SNFontWeightBold), SNColorContentPry, nameLine, NSTextAlignmentLeft, 1,
               NSMakeRect(x, nameTop, width - 8, nameLine));
    SNDrawText(SNFileDescription(_file), SNFont(SNFontSizeCaption, SNFontWeightRegular), kKind, SNFontSizeCaption * 1.25, NSTextAlignmentLeft, 1,
               NSMakeRect(x, nameTop + nameLine + 2, width, SNFontSizeCaption * 1.25));
}

/// The circle's fill sits under the spinner layer, so it is drawn here in the item's coordinates.
- (void)drawStatus {
    if (_status.alphaValue == 0) return;
    NSRect circle = _status.frame;
    if ([self showsRemove]) {
        // The remove button is clear (status_btn--remove): only the 20 pt base-inv-pry disc and
        // its close-filled x at the micro font size show.
        NSRect glyph = NSInsetRect(circle, (kStatus - kStatusGlyph) / 2, (kStatus - kStatusGlyph) / 2);
        [SNColor(SNColorBaseInvPry) setFill];
        [[NSBezierPath bezierPathWithOvalInRect:glyph] fill];
        SNDrawIcon(@"close-filled", kClose, SNColorContentInvPry, NSInsetRect(glyph, (kStatusGlyph - kClose) / 2, (kStatusGlyph - kClose) / 2));
        return;
    }
    [SNColor(SNLegacyPrimaryBackground) setFill];
    [[NSBezierPath bezierPathWithOvalInRect:circle] fill];
    if (self.upload.state == SNUploadFailed) {
        SNDrawIcon(@"warning-filled", kWarning, SNColorContentImp, NSInsetRect(circle, (kStatus - kWarning) / 2, (kStatus - kWarning) / 2));
    }
}

@end

#pragma mark The row

/// What the items scroll in, cut at the row's edges.
@interface SNComposerAttachmentsClip : NSView
@end

@implementation SNComposerAttachmentsClip
- (BOOL)isFlipped { return YES; }
@end

@implementation SNComposerAttachments {
    SNComposerAttachmentsClip *_clip;
    NSMutableArray<SNComposerAttachmentItem *> *_items;
    SNButton *_left, *_right;
    CGFloat _offset;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _items = [NSMutableArray new];
    _clip = [[SNComposerAttachmentsClip alloc] initWithFrame:NSZeroRect];
    _clip.clipsToBounds = YES;
    [self addSubview:_clip];
    __weak SNComposerAttachments *weakSelf = self;
    _left = [self arrowNamed:@"arrow-left" action:^{ [weakSelf scrollBy:-kPage]; }];
    _right = [self arrowNamed:@"arrow-right" action:^{ [weakSelf scrollBy:kPage]; }];
    return self;
}

- (SNButton *)arrowNamed:(NSString *)name action:(void (^)(void))action {
    SNButton *arrow = [SNButton iconButtonNamed:name size:kArrow iconSize:20];
    arrow.cornerRadius = kArrow / 2;
    arrow.contentColor = SNColorContentSec;
    arrow.hoverContentColor = arrow.pressedContentColor = SNColorContentPry;
    arrow.hoverFillColor = SNColorBaseTer;
    arrow.action = ^(SNButton *button) { action(); };
    [self addSubview:arrow];
    return arrow;
}

- (BOOL)isFlipped { return YES; }
- (NSArray<NSView *> *)itemViews { return [_items copy]; }
- (NSView *)leftArrow { return _left; }
- (NSView *)rightArrow { return _right; }

- (void)setUploads:(NSArray<SNUpload *> *)uploads {
    _uploads = [uploads copy];
    NSMutableDictionary<NSString *, SNComposerAttachmentItem *> *kept = [NSMutableDictionary new];
    for (SNComposerAttachmentItem *item in _items) kept[item.upload.uploadID] = item;
    [_items removeAllObjects];
    __weak SNComposerAttachments *weakSelf = self;
    for (SNUpload *upload in uploads) {
        SNComposerAttachmentItem *item = kept[upload.uploadID];
        [kept removeObjectForKey:upload.uploadID];
        if (item) item.upload = upload;
        else {
            item = [[SNComposerAttachmentItem alloc] initWithUpload:upload];
            __weak SNComposerAttachmentItem *weakItem = item;
            item.status.action = ^(SNHoverView *view) {
                SNComposerAttachments *row = weakSelf;
                if (row.remove && weakItem) row.remove(weakItem.upload);
            };
            [_clip addSubview:item];
        }
        [_items addObject:item];
    }
    for (SNComposerAttachmentItem *gone in kept.allValues) [gone removeFromSuperview];
    self.needsLayout = YES;
}

- (CGFloat)contentWidth {
    CGFloat width = 2 * kInset;
    for (SNComposerAttachmentItem *item in _items) width += item.itemWidth;
    return width + kGap * MAX(0, (NSInteger)_items.count - 1);
}

- (CGFloat)maximumOffset { return MAX(0, self.contentWidth - NSWidth(self.bounds)); }

- (void)layout {
    [super layout];
    _clip.frame = self.bounds;
    _offset = MIN(MAX(0, _offset), self.maximumOffset);
    [self placeItems];
}

- (void)placeItems {
    CGFloat x = kInset - _offset, top = SNComposerAttachmentsOverhang + kInset - kStatusReach;
    for (SNComposerAttachmentItem *item in _items) {
        [item setFrameOrigin:NSMakePoint(x, top)];
        x += item.itemWidth + kGap;
    }
    CGFloat arrowY = SNComposerAttachmentsOverhang + kInset + (kItem - kArrow) / 2;
    _left.frame = NSMakeRect(-kArrowReach, arrowY, kArrow, kArrow);
    _right.frame = NSMakeRect(NSWidth(self.bounds) + kArrowReach - kArrow, arrowY, kArrow, kArrow);
    _left.hidden = _offset <= 0.5;
    _right.hidden = _offset >= self.maximumOffset - 0.5;
}

- (void)scrollBy:(CGFloat)distance {
    _offset = MIN(MAX(0, _offset + distance), self.maximumOffset);
    SNAnimate(kPageDuration, SNEaseDefault(), ^{ [self placeItems]; });
}

- (void)scrollWheel:(NSEvent *)event {
    CGFloat delta = fabs(event.scrollingDeltaX) > fabs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY;
    if (self.maximumOffset <= 0 || delta == 0) return [super scrollWheel:event];
    _offset = MIN(MAX(0, _offset - delta * (event.hasPreciseScrollingDeltas ? 1 : 10)), self.maximumOffset);
    [self placeItems];
}

// The overhang lies over the text: only the items and arrows take the pointer there.
- (NSView *)hitTest:(NSPoint)point {
    NSView *hit = [super hitTest:point];
    return hit == self || hit == _clip ? nil : hit;
}

@end
