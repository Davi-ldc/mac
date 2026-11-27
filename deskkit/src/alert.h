// A transient on-screen message.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A message as Hammerspoon's hs.alert shows one, for `seconds`; it fades in and out, and
/// never takes focus or clicks.
void DKShowAlert(NSString *text, NSTimeInterval seconds);
/// Fades the message out early.
void DKHideAlert(void);

NS_ASSUME_NONNULL_END
