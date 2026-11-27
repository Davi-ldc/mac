// Index of installed applications.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Scans the application folders and rescans whenever one of them changes, and follows
/// which applications are running.
void DKStartApplicationIndex(void);
/// Each entry has "title" (display name), "path", and "alternateTitles" and "keywords"
/// (arrays of strings).
NSArray<NSDictionary *> *DKApplications(void);
/// Paths of the indexed applications that are running.
NSSet<NSString *> *DKRunningApplicationPaths(void);
/// Posted on the main thread when either of the two changes.
extern NSNotificationName const DKApplicationsDidChangeNotification;

NS_ASSUME_NONNULL_END
