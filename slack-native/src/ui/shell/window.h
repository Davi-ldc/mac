// The main window: full-size content under a transparent titlebar, with the traffic lights where
// Slack puts them (first at x 12, centred on the 40 pt top bar) and a notice when the window's
// key state changes, since Slack dims its chrome in background windows. While key it sets the
// cursor SNCursorAtPoint (ui/kit/hoverview.h) gives after every pointer event.
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Slack's default window size, which the reference captures were taken at.
static const NSSize SNWindowDefaultSize = {1435, 938};

@interface SNMainWindow : NSWindow
- (instancetype)initWithSize:(NSSize)size;
/// Called with YES when the window becomes key and NO when it resigns.
@property (nonatomic, copy, nullable) void (^keyStateChanged)(BOOL key);
@end

NS_ASSUME_NONNULL_END
