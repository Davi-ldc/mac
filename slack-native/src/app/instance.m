// Owns the instance lock and the defaults suites.
#import <sys/file.h>

#import "app/instance.h"
#import "store/database.h"

static NSString *BundleIdentifier(void) { return NSBundle.mainBundle.bundleIdentifier ?: @"local.slack-native"; }

NSURL *SNInstanceLockFile(void) { return [SNDatabase.folder URLByAppendingPathComponent:[BundleIdentifier() stringByAppendingString:@".session.lock"]]; }

BOOL SNHoldInstanceLock(NSURL *file) {
    [NSFileManager.defaultManager createDirectoryAtURL:file.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    int descriptor = open(file.fileSystemRepresentation, O_RDWR | O_CREAT, 0600);
    if (descriptor < 0) return NO;
    // The descriptor is never closed: the lock goes when the process does, however it ends.
    if (flock(descriptor, LOCK_EX | LOCK_NB) == 0) return YES;
    close(descriptor);
    return NO;
}

NSUserDefaults *SNAppDefaults(NSString *workspaceID) {
    return [[NSUserDefaults alloc] initWithSuiteName:[NSString stringWithFormat:@"%@.%@", BundleIdentifier(), workspaceID ?: @"fixture"]];
}
