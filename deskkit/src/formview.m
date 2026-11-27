// Owns form layout and the look of its fields, including the focus ring.
#import <QuartzCore/QuartzCore.h>

#import "formview.h"
#import "theme.h"

/// Raycast's form grid, measured from its Create Quicklink form: a 360-point centre column,
/// labels ending 24 points left of it, 24 points between rows. Field sizes are those of the
/// fill; the border lies outside it.
static const CGFloat kColumn = 360, kLabelGap = 24, kRowGap = 24, kTop = 8;
static const CGFloat kFieldHeight = 32, kMultilineHeight = 100, kFieldRadius = 12, kFieldPadding = 12;
/// Where the first line of text sits in a field, which is where its label lines up.
static const CGFloat kFirstLine = 14.5;
static const CGFloat kInfoGap = 8;

/// Tells its box when it gains focus, which is when the box draws Raycast's focus ring.
@interface DKFormTextField : NSTextField
@property(copy, nullable) void (^onFocus)(void);
@property BOOL oneEntryPerLine;
@property(copy, nullable) NSString *_Nullable (^lineForDroppedFile)(NSString *line, NSURL *file);
@end
@implementation DKFormTextField
- (BOOL)becomeFirstResponder {
    BOOL accepted = [super becomeFirstResponder];
    // A field selects its whole text when it gains focus, and Return would then replace the
    // whole list with a line break; the caret goes after the last entry instead.
    if (accepted && _oneEntryPerLine) self.currentEditor.selectedRange = NSMakeRange(self.stringValue.length, 0);
    if (accepted && self.onFocus) self.onFocus();
    return accepted;
}
@end

@interface DKFormView ()
- (NSInteger)lineAt:(NSPoint)point field:(DKFormTextField *_Nullable __strong *_Nullable)found;
@end

/// Takes image files dropped on a list field, for the form to put on a line. It lies over the
/// field, since a field being edited would take the drop itself, as text; clicks go through.
@interface DKDropOverlay : NSView
@property(weak) DKFormView *form;
@end
@implementation DKDropOverlay
- (NSView *)hitTest:(NSPoint)point { return nil; }
- (NSURL *)imageIn:(id<NSDraggingInfo>)info {
    return [info.draggingPasteboard readObjectsForClasses:@[ NSURL.class ] options:@{
        NSPasteboardURLReadingFileURLsOnlyKey : @YES, NSPasteboardURLReadingContentsConformToTypesKey : @[ @"public.image" ]
    }].firstObject;
}
- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)info {
    NSPoint point = [_form convertPoint:info.draggingLocation fromView:nil];
    return [self imageIn:info] && [_form lineAt:point field:NULL] >= 0 ? NSDragOperationCopy : NSDragOperationNone;
}
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)info { return [self draggingUpdated:info]; }
- (BOOL)performDragOperation:(id<NSDraggingInfo>)info {
    NSURL *image = [self imageIn:info];
    return image && [_form dropFile:image at:[_form convertPoint:info.draggingLocation fromView:nil]];
}
@end

@implementation DKFormView {
    NSMutableArray<DKFormTextField *> *_fields;
    NSMutableArray<NSView *> *_boxes;
    /// Each box's border, a view just outside it, in the same order.
    NSMutableArray<NSView *> *_borders;
    NSTextField *_error;
}

- (void)showForm:(DKForm *)form {
    for (NSView *view in self.subviews.copy) [view removeFromSuperview];
    _fields = [NSMutableArray new];
    _boxes = [NSMutableArray new];
    _borders = [NSMutableArray new];
    CGFloat columnX = (self.bounds.size.width - kColumn) / 2;
    CGFloat y = DKHeaderHeight + kTop;
    for (DKFormField *spec in form.fields) {
        CGFloat height = spec.multiline ? kMultilineHeight : kFieldHeight;
        CGFloat lineCenter = y + (spec.multiline ? kFirstLine : height / 2);

        NSTextField *label = DKLabel(spec.label, DKFont(11, 400), DKTextSecondary());
        label.alignment = NSTextAlignmentRight;
        [label sizeToFit];
        CGFloat labelHeight = label.frame.size.height;
        label.frame = NSMakeRect(16, lineCenter - labelHeight / 2, columnX - kLabelGap - 16 + 2, labelHeight);
        [self addSubview:label];

        NSView *box = [[NSView alloc] initWithFrame:NSMakeRect(columnX, y, kColumn, height)];
        box.wantsLayer = YES;
        box.layer.cornerRadius = kFieldRadius;
        box.layer.backgroundColor = DKWhite(0.05).CGColor;
        NSView *border = [NSView new];
        border.wantsLayer = YES;
        [self addSubview:border];
        [self addSubview:box];
        [_boxes addObject:box];
        [_borders addObject:border];
        [box addSubview:[self textFieldFor:spec inBox:box]];
        if (spec.oneEntryPerLine && spec.lineForDroppedFile) {
            DKDropOverlay *overlay = [[DKDropOverlay alloc] initWithFrame:box.bounds];
            overlay.form = self;
            [overlay registerForDraggedTypes:@[ NSPasteboardTypeFileURL ]];
            [box addSubview:overlay];
        }
        y += height;

        if (spec.info) {
            NSTextField *info = [NSTextField wrappingLabelWithString:spec.info];
            info.font = DKFont(11, 400);
            info.textColor = DKTextSecondary();
            NSSize size = [info sizeThatFits:NSMakeSize(kColumn, CGFLOAT_MAX)];
            info.frame = NSMakeRect(columnX, y + kInfoGap, kColumn, size.height);
            [self addSubview:info];
            y = NSMaxY(info.frame);
        }
        y += kRowGap;
    }
    _error = [NSTextField wrappingLabelWithString:@""];
    _error.font = DKFont(11, 400);
    _error.textColor = NSColor.systemRedColor;
    _error.frame = NSMakeRect(columnX, y - kRowGap + kInfoGap, kColumn, 0);
    [self addSubview:_error];
    [self highlightBox:nil];
}

- (void)showError:(NSString *)message {
    _error.stringValue = message;
    NSRect frame = _error.frame;
    frame.size.height = [_error sizeThatFits:NSMakeSize(kColumn, CGFLOAT_MAX)].height;
    _error.frame = frame;
}

- (NSTextField *)textFieldFor:(DKFormField *)spec inBox:(NSView *)box {
    DKFormTextField *field = [DKFormTextField new];
    field.bezeled = NO;
    field.drawsBackground = NO;
    field.focusRingType = NSFocusRingTypeNone;
    field.font = DKFont(13, 400);
    field.textColor = DKTextPrimary();
    field.stringValue = spec.value ?: @"";
    field.oneEntryPerLine = spec.oneEntryPerLine;
    field.lineForDroppedFile = spec.lineForDroppedFile;
    field.placeholderAttributedString = [[NSAttributedString alloc]
        initWithString:spec.placeholder
            attributes:@{NSForegroundColorAttributeName : DKTextTertiary(), NSFontAttributeName : field.font}];
    CGFloat line = ceil(field.font.ascender - field.font.descender + field.font.leading) + 2;
    NSSize boxSize = box.bounds.size;
    if (spec.multiline) {
        field.cell.wraps = !spec.oneEntryPerLine;
        field.cell.scrollable = spec.oneEntryPerLine;
        if (spec.oneEntryPerLine) field.lineBreakMode = NSLineBreakByTruncatingTail;
        field.usesSingleLineMode = NO;
        CGFloat top = kFirstLine - line / 2 + 1.5;
        // The box is not flipped: the text's frame is measured from its bottom.
        field.frame = NSMakeRect(kFieldPadding, kFieldPadding, boxSize.width - 2 * kFieldPadding, boxSize.height - top - kFieldPadding);
    } else {
        field.cell.scrollable = YES;
        field.lineBreakMode = NSLineBreakByTruncatingTail;
        field.frame = NSMakeRect(kFieldPadding, (boxSize.height - line) / 2, boxSize.width - 2 * kFieldPadding, line);
    }
    __weak DKFormView *weakSelf = self;
    __weak NSView *weakBox = box;
    field.onFocus = ^{ [weakSelf highlightBox:weakBox]; };
    [_fields addObject:field];
    return field;
}

/// The focused field trades its thin border for a brighter ring twice as wide, which grows
/// outward so the text does not move.
- (void)highlightBox:(NSView *)focused {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (NSUInteger i = 0; i < _boxes.count; i++) {
        CGFloat width = _boxes[i] == focused ? 2 : 1;
        CALayer *border = _borders[i].layer;
        _borders[i].frame = NSInsetRect(_boxes[i].frame, -width, -width);
        border.cornerRadius = kFieldRadius + width;
        border.borderWidth = width;
        border.borderColor = DKWhite(width == 2 ? 0.3 : 0.2).CGColor;
    }
    [CATransaction commit];
}

- (NSArray<NSString *> *)values { return [_fields valueForKey:@"stringValue"]; }

- (NSTextField *)firstField { return _fields.firstObject; }

- (NSUInteger)focusedIndex {
    NSTextView *editor = (NSTextView *)self.window.firstResponder;
    return [_fields indexOfObjectPassingTest:^BOOL(DKFormTextField *field, NSUInteger i, BOOL *stop) {
        return field.currentEditor == editor;
    }];
}

- (BOOL)focusNextField {
    NSUInteger index = [self focusedIndex];
    if (index == NSNotFound || index + 1 >= _fields.count) return NO;
    [self.window makeFirstResponder:_fields[index + 1]];
    return YES;
}

/// The line of a list field under `point`, and that field; -1 when no line is there.
- (NSInteger)lineAt:(NSPoint)point field:(DKFormTextField *__strong *)found {
    for (DKFormTextField *field in _fields) {
        NSPoint local = [field convertPoint:point fromView:self];
        if (!field.lineForDroppedFile || !NSPointInRect(local, field.bounds)) continue;
        NSRect text = [field.cell titleRectForBounds:field.bounds];
        CGFloat fromTop = field.isFlipped ? local.y - NSMinY(text) : NSMaxY(text) - local.y;
        // Lines scrolled up out of a field being edited.
        NSView *clip = field.currentEditor.superview;
        if ([clip isKindOfClass:NSClipView.class]) fromTop += clip.bounds.origin.y;
        NSInteger line = (NSInteger)floor(fromTop / [[NSLayoutManager new] defaultLineHeightForFont:field.font]);
        NSArray<NSString *> *lines = [field.stringValue componentsSeparatedByString:@"\n"];
        if (line < 0 || line >= (NSInteger)lines.count || !lines[line].length) return -1;
        if (found) *found = field;
        return line;
    }
    return -1;
}

- (BOOL)dropFile:(NSURL *)file at:(NSPoint)point {
    DKFormTextField *field;
    NSInteger index = [self lineAt:point field:&field];
    if (index < 0) return NO;
    NSMutableArray<NSString *> *lines = [[field.stringValue componentsSeparatedByString:@"\n"] mutableCopy];
    NSString *line = field.lineForDroppedFile(lines[index], file);
    if (!line) return NO;
    lines[index] = line;
    NSString *text = [lines componentsJoinedByString:@"\n"];
    if (field.currentEditor) field.currentEditor.string = text;
    else field.stringValue = text;
    return YES;
}

- (BOOL)insertNewline {
    NSUInteger index = [self focusedIndex];
    if (index == NSNotFound || !_fields[index].oneEntryPerLine) return NO;
    // A field's editor ends editing on Return; this is its way of taking a line break.
    [(NSTextView *)self.window.firstResponder insertNewlineIgnoringFieldEditor:nil];
    return YES;
}

@end
