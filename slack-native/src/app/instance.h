// What keeps runs of the app apart: one running copy per session (two would rotate the same
// cookies and overwrite each other's), and the defaults each kind of run keeps its state in.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// <app folder>/<bundle identifier>.session.lock: the Keychain's session item is per bundle
/// identifier, so two builds sharing one share the lock too.
NSURL *SNInstanceLockFile(void);
/// Locks `file` for the rest of the process's life; NO when it is locked already (by another
/// copy) or cannot be locked.
BOOL SNHoldInstanceLock(NSURL *file);

/// The suite the window keeps its place and sizes in: the workspace's own (IDs are per
/// workspace), or with `workspaceID` nil the fixture runs', so a fixture never leaves a
/// conversation for a signed-in launch to reopen.
NSUserDefaults *SNAppDefaults(NSString *_Nullable workspaceID);

NS_ASSUME_NONNULL_END
