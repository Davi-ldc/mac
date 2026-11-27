// The picker's header: a logo or back button, and the search field.
#import <AppKit/AppKit.h>

#import "panel.h"

NS_ASSUME_NONNULL_BEGIN

@interface DKSearchBar : DKFlippedView
- (instancetype)initWithLogo:(NSImage *)logo;
@property(readonly) NSTextField *field;
- (void)setPlaceholder:(NSString *)placeholder;
/// The logo on the root screen, a back chevron on the screens pushed above it.
@property(nonatomic) BOOL showsBack;
/// Forms have a header with only the back button.
@property(nonatomic) BOOL showsField;
@property(copy, nullable) void (^onBack)(void);
@end

NS_ASSUME_NONNULL_END
