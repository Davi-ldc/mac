// Raycast's HUD: a short confirmation at the bottom of the screen once the panel has closed.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Shows `title` for a moment, as Raycast does after "Copied answer to clipboard".
void DKShowHUD(NSString *title);

NS_ASSUME_NONNULL_END
