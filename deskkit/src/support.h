// Where deskkit keeps its state.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// ~/Library/Application Support/deskkit, or DESKKIT_HOME. Only this user can open it, as
/// it holds usage counts, quicklinks and the clipboard history.
NSURL *DKSupportDirectory(void);
/// A folder inside it, equally private.
NSURL *DKSupportSubdirectory(NSString *name);

NS_ASSUME_NONNULL_END
