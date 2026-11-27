// A form in Raycast's layout: labels right-aligned in the left column, fields in a
// 360-point centre column.
#import <AppKit/AppKit.h>

#import "items.h"
#import "panel.h"

NS_ASSUME_NONNULL_BEGIN

@interface DKFormView : DKFlippedView
- (void)showForm:(DKForm *)form;
@property(readonly) NSArray<NSString *> *values;
@property(readonly, nullable) NSTextField *firstField;
/// Moves focus to the next field; returns NO from the last one.
- (BOOL)focusNextField;
/// Starts a new line in the focused field if it takes Return; returns NO otherwise.
- (BOOL)insertNewline;
/// Puts `file` on the line of a list field under `point`, as dropping it there does: the
/// field's lineForDroppedFile rewrites the line. NO when nothing took it.
- (BOOL)dropFile:(NSURL *)file at:(NSPoint)point;
/// Shows why the values were not accepted, in red under the fields.
- (void)showError:(NSString *)message;
@end

NS_ASSUME_NONNULL_END
