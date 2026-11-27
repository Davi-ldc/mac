// Commands a view sends to the app up the responder chain, which ends at the app delegate:
// [NSApp sendAction:@selector(signOut:) to:nil from:self].
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol SNAppActions
/// "Sair": this Mac forgets the session and the workspace's cache, Slack is told, and the
/// sign-in window opens. Nothing happens without a signed-in workspace (fixture runs).
- (void)signOut:(nullable id)sender;
/// Slack's Preferences over the window (⌘,; the workspace menu's "Preferências").
- (void)showPreferences:(nullable id)sender;
/// The locale preference changed: the window is made again in the new language, as Slack's client
/// reloads.
- (void)reloadLanguage:(nullable id)sender;
@end

NS_ASSUME_NONNULL_END
