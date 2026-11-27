// Site icons for web quicklinks.
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// The site's own icon, or Safari's icon until it has been fetched;
/// DKWebIconDidLoadNotification is posted when one arrives.
NSImage *DKWebIcon(NSString *host);
extern NSNotificationName const DKWebIconDidLoadNotification;

NS_ASSUME_NONNULL_END
