// Owns the on-disk location of deskkit's state; each folder is made once per run.
#import "support.h"

static NSURL *MakePrivate(NSURL *folder) {
    NSFileManager *files = NSFileManager.defaultManager;
    NSDictionary *owner = @{NSFilePosixPermissions : @0700};
    [files createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:owner error:nil];
    // A folder that already existed (the installer makes one) keeps its mode unless set again.
    [files setAttributes:owner ofItemAtPath:folder.path error:nil];
    return folder;
}

NSURL *DKSupportDirectory(void) {
    static NSURL *folder;
    if (folder) return folder;
    const char *override = getenv("DESKKIT_HOME");
    folder = override ? [NSURL fileURLWithPath:@(override)]
                      : [[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory
                                                              inDomains:NSUserDomainMask].firstObject
                            URLByAppendingPathComponent:@"deskkit"];
    return MakePrivate(folder);
}

NSURL *DKSupportSubdirectory(NSString *name) {
    static NSMutableDictionary<NSString *, NSURL *> *made;
    if (!made) made = [NSMutableDictionary new];
    if (!made[name]) made[name] = MakePrivate([DKSupportDirectory() URLByAppendingPathComponent:name]);
    return made[name];
}
