// Owns drawing the detail pane. Everything is drawn rather than built from subviews: the
// pane changes on every selection and holds no state worth keeping in views.
#import <QuartzCore/QuartzCore.h>

#import "bench.h"
#import "detailview.h"
#import "theme.h"

/// The preview ends this far from the top of the panel when there is metadata below it.
static const CGFloat kPreviewBottom = 280;
static const CGFloat kTextInset = 20, kTableInset = 16, kCellPadding = 8, kLineHeight = 28;
/// A picture may reach this much further to either side than text does.
static const CGFloat kImageOutset = 4;

@implementation DKDetailView {
    DKDetail *_detail;
    /// The detail's picture, once its loader has handed it over.
    NSImage *_image;
    CAGradientLayer *_fade;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    // Like the list, the pane fades out where it passes under the bottom bar.
    _fade = [CAGradientLayer layer];
    _fade.colors = @[ (id)NSColor.blackColor.CGColor, (id)NSColor.blackColor.CGColor, (id)[NSColor colorWithWhite:0 alpha:0.25].CGColor ];
    self.layer.mask = _fade;
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)layout {
    [super layout];
    CGFloat height = self.bounds.size.height;
    _fade.frame = self.bounds;
    // The layer is flipped like the view: 0 is the top.
    _fade.startPoint = CGPointMake(0.5, 0);
    _fade.endPoint = CGPointMake(0.5, 1);
    _fade.locations = @[ @0, @(1 - DKFooterHeight / MAX(height, 1)), @1 ];
}

- (void)showItem:(DKItem *)item {
    DKDetail *detail = item.detail ? item.detail() : nil;
    _detail = detail;
    _image = nil;
    self.needsDisplay = YES;
    if (!detail.imageLoader) return;
    __weak DKDetailView *weakSelf = self;
    detail.imageLoader(NSInsetRect(self.previewRect, -kImageOutset, 0).size, self.layer.contentsScale,
                       ^(NSImage *image) { [weakSelf showImage:image of:detail]; });
}

- (void)showImage:(NSImage *)image of:(DKDetail *)detail {
    // A picture that took a while can come after the selection has moved on.
    if (detail != _detail) return;
    DKBenchMark("picture");
    _image = image;
    self.needsDisplay = YES;
}

/// Down to the metadata when there is some, else to the bottom bar.
- (NSRect)previewRect {
    NSSize size = self.bounds.size;
    CGFloat bottom = _detail.metadata.count ? kPreviewBottom : size.height - DKFooterHeight;
    return NSMakeRect(kTextInset, DKHeaderHeight + 5, size.width - 2 * kTextInset, bottom - DKHeaderHeight - 21);
}

- (void)drawRect:(NSRect)dirty {
    NSRect bounds = self.bounds, preview = self.previewRect;
    [self drawSeparatorInHeight:bounds.size.height];
    if (_image) [self drawImage:_image in:NSInsetRect(preview, -kImageOutset, 0)];
    else if (_detail.text.length) [self drawText:_detail.text in:preview];
    if (_detail.metadata.count) [self drawMetadata:_detail.metadata from:kPreviewBottom width:bounds.size.width];
}

/// Raycast's divider starts below the header and fades out at both ends.
- (void)drawSeparatorInHeight:(CGFloat)height {
    NSGradient *gradient = [[NSGradient alloc] initWithColorsAndLocations:DKWhite(0), 0.0, DKWhite(0.1), 0.08,
                                                                          DKWhite(0.1), 0.92, DKWhite(0), 1.0, nil];
    [gradient drawInRect:NSMakeRect(0, DKHeaderHeight, 1, height - DKHeaderHeight) angle:90];
}

- (void)drawText:(NSString *)text in:(NSRect)rect {
    NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
    paragraph.lineBreakMode = NSLineBreakByWordWrapping;
    paragraph.lineHeightMultiple = 1.15;
    NSDictionary *style = @{NSFontAttributeName : DKFont(13, 400), NSForegroundColorAttributeName : DKTextPrimary(),
                            NSParagraphStyleAttributeName : paragraph};
    [text drawWithRect:rect
               options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine
            attributes:style
               context:nil];
}

- (void)drawImage:(NSImage *)image in:(NSRect)rect {
    NSSize size = image.size;
    NSRect centred = NSMakeRect(NSMidX(rect) - size.width / 2, NSMidY(rect) - size.height / 2, size.width, size.height);
    // The picture comes with a pixel for each of the screen's; off their grid it would blur.
    [image drawInRect:[self backingAlignedRect:centred options:NSAlignAllEdgesNearest] fromRect:NSZeroRect
            operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES
                hints:@{NSImageHintInterpolation : @(NSImageInterpolationHigh)}];
}

- (void)drawMetadata:(NSArray<NSArray<NSString *> *> *)metadata from:(CGFloat)top width:(CGFloat)width {
    NSDictionary *heading = @{NSFontAttributeName : DKFont(11, 400), NSForegroundColorAttributeName : DKTextSecondary()};
    NSDictionary *label = @{NSFontAttributeName : DKFont(11, 400), NSForegroundColorAttributeName : DKTextSecondary()};
    NSMutableParagraphStyle *right = [NSMutableParagraphStyle new];
    right.alignment = NSTextAlignmentRight;
    right.lineBreakMode = NSLineBreakByTruncatingMiddle;
    NSDictionary *value = @{NSFontAttributeName : DKFont(11, 400), NSForegroundColorAttributeName : DKTextPrimary(),
                            NSParagraphStyleAttributeName : right};

    CGFloat x = kTableInset, tableWidth = width - 2 * kTableInset;
    NSString *title = @"Information";
    NSSize titleSize = [title sizeWithAttributes:heading];
    // Centre of the title, then the rows: measured from Raycast's Quicklinks detail.
    [title drawAtPoint:NSMakePoint(x + kCellPadding, top + 22.5 - titleSize.height / 2) withAttributes:heading];
    CGFloat y = top + 36;
    for (NSUInteger i = 0; i < metadata.count; i++, y += kLineHeight) {
        NSRect row = NSMakeRect(x, y, tableWidth, kLineHeight);
        if (i % 2 == 0) {
            [DKWhite(0.02) setFill];
            [[NSBezierPath bezierPathWithRoundedRect:row xRadius:4 yRadius:4] fill];
        }
        NSString *name = metadata[i][0], *text = metadata[i][1];
        NSSize nameSize = [name sizeWithAttributes:label];
        CGFloat textY = y + (kLineHeight - nameSize.height) / 2;
        [name drawAtPoint:NSMakePoint(x + kCellPadding, textY) withAttributes:label];
        CGFloat valueX = x + kCellPadding + nameSize.width + 16;
        [text drawInRect:NSMakeRect(valueX, textY, NSMaxX(row) - kCellPadding - valueX, nameSize.height) withAttributes:value];
    }
}

@end
