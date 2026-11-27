// Dark native macOS window with transparent titlebar and global Space / Cmd+K / Cmd+[ / Cmd+] routing.
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface SPWindow : NSWindow
@property (nonatomic, copy, nullable) void (^onSpaceTogglePlayPause)(void);
@property (nonatomic, copy, nullable) void (^onFocusSearch)(void);
@property (nonatomic, copy, nullable) void (^onNavigateBack)(void);
@property (nonatomic, copy, nullable) void (^onNavigateForward)(void);

/// YES when firstResponder is an active text editor / text field (so Space inserts a space instead of pausing).
- (BOOL)isEditingText;
/// Exposed helper for deterministic Space-key routing tests.
- (BOOL)handleKeyEvent:(NSEvent *)event;
@end

NS_ASSUME_NONNULL_END
