// Slack's VIP button, shared by the profile card, the profile panel and the Preferences' VIP list:
// who may be made a VIP (canMemberToggleVip) and the toggle with its toasts
// (togglePriorityUserById).
#import <AppKit/AppKit.h>

#import "source/source.h"

NS_ASSUME_NONNULL_BEGIN

/// The plan offers VIPs and `user` is someone else, not deleted and not an Agentforce agent.
BOOL SNCanToggleVIP(id<SNSource> source, SNUser *user);
BOOL SNIsVIP(id<SNSource> source, NSString *userID);
/// Adds `user` to the VIPs or takes them off, then says so in a toast in `window`: "Added <b>name</b>
/// to VIPs", or why Slack refused an addition.
void SNToggleVIP(id<SNSource> source, SNUser *user, NSWindow *_Nullable window);

NS_ASSUME_NONNULL_END
