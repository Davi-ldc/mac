// Editing a message in place: the message's row becomes the composer's box with its text and
// the Cancelar and Salvar buttons (Return saves, Shift+Return starts a new line, Escape cancels),
// over the editing row's tint. Saving an emptied message asks to delete it instead.
#import <AppKit/AppKit.h>

#import "source/source.h"

NS_ASSUME_NONNULL_BEGIN

@interface SNMessageEditor : NSView
- (instancetype)initWithMessage:(SNMessage *)message source:(id<SNSource>)source;
@property (nonatomic, readonly) SNMessage *message;
/// The row's height at `width`, for the list's layout.
- (CGFloat)heightForWidth:(CGFloat)width;
/// The text as edited (tests).
@property (nonatomic, copy) NSString *text;
- (void)focus;
/// Saves (editMessage:text:blocks:) when the text changed, or asks to delete when it is empty.
- (void)save;
- (void)cancel;
/// The text grew or shrank a line.
@property (nonatomic, copy, nullable) void (^heightChanged)(SNMessageEditor *editor);
/// Editing ended: saved, cancelled or handed over to the delete confirmation (`deleteRequested`).
@property (nonatomic, copy, nullable) void (^finished)(SNMessageEditor *editor);
@property (nonatomic, copy, nullable) void (^deleteRequested)(SNMessage *message);
@end

NS_ASSUME_NONNULL_END
