// Watching a folder for new, removed and renamed entries.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Calls `handler` on the main queue whenever an entry of `folder` (not of its subfolders)
/// is added, removed or renamed, for as long as deskkit runs. Returns NO when the folder
/// cannot be opened.
BOOL DKWatchFolder(NSString *folder, void (^handler)(void));

NS_ASSUME_NONNULL_END
