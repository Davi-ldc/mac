// Slack's Preferences dialog (the web client's prefs-dialog, ⌘,), drawn over the window as the
// official app draws it: a modal up to 800 x 700 pt with "Preferences" over a 1 pt line, the
// sections in a 205 pt list at the left (the current one on #0a77a7) and the chosen section's
// options at the right, scrolling. It offers the sections and options this client honours. Slack's
// own preferences save to users.prefs (users.prefs.set, users.prefs.setNotifications) the moment
// they change; the app's own (launching at login) stay on this Mac.
#import <AppKit/AppKit.h>

#import "source/source.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SNPrefsSection) {
    SNPrefsNotifications,
    /// Offered where the plan offers VIPs.
    SNPrefsVIP,
    SNPrefsHome,
    SNPrefsMessages,
    SNPrefsLanguage,
    SNPrefsAccessibility,
    SNPrefsMarkAsRead,
    SNPrefsAdvanced,
};

@interface SNPreferencesDialog : NSObject
/// Opens over `window` at `section` (closing one already open).
+ (instancetype)showInWindow:(NSWindow *)window source:(id<SNSource>)source section:(SNPrefsSection)section;
+ (nullable SNPreferencesDialog *)current;
@property (nonatomic) SNPrefsSection section;
/// The dialog's surface, for tests and snapshots.
@property (nonatomic, readonly) NSView *panel;
/// The current section's options as labelled (tests): a check or radio's label, a select's choice.
@property (nonatomic, readonly) NSArray<NSString *> *optionTitles;
/// The sections offered, in order (tests).
@property (nonatomic, readonly) NSArray<NSNumber *> *sections;
/// The current section's view of its own (the VIP list), if it has one (tests).
@property (nonatomic, readonly, nullable) NSView *customView;
/// Acts on the option labelled `title` as a click would: a check flips, a radio is chosen, and a
/// select or field takes `value` (tests).
- (BOOL)chooseOption:(NSString *)title value:(nullable NSString *)value;
- (void)close;
@end

NS_ASSUME_NONNULL_END
