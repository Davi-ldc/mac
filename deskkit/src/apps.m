// Owns the index of installed applications, rescanned when an application folder changes,
// and the set of those that are running.
#import <AppKit/AppKit.h>

#import "apps.h"
#import "folderwatch.h"

NSNotificationName const DKApplicationsDidChangeNotification = @"DKApplicationsDidChangeNotification";

static NSArray<NSDictionary *> *applications;

/// Follows NSWorkspace's list instead of reading it when asked: an application's path
/// takes a round trip to Launch Services, about 5 ms for everything running, which the
/// launcher would otherwise pay on every key press.
@interface DKRunningApplications : NSObject
@property(readonly) NSSet<NSString *> *paths;
/// Works `paths` out again, and tells when they changed.
- (void)publish;
@end

@implementation DKRunningApplications {
    NSMapTable<NSRunningApplication *, NSString *> *_pathOf;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _pathOf = [NSMapTable strongToStrongObjectsMapTable];
    // Unlike the workspace's launch notifications, the list also covers applications
    // without a Dock icon.
    [NSWorkspace.sharedWorkspace addObserver:self forKeyPath:@"runningApplications"
                                     options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionOld | NSKeyValueObservingOptionNew
                                     context:NULL];
    return self;
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    // The applications that left and those that came; all of them, the first time.
    NSArray<NSRunningApplication *> *left = change[NSKeyValueChangeOldKey], *came = change[NSKeyValueChangeNewKey];
    if ([left isKindOfClass:NSArray.class])
        for (NSRunningApplication *app in left) [_pathOf removeObjectForKey:app];
    if ([came isKindOfClass:NSArray.class])
        for (NSRunningApplication *app in came) [_pathOf setObject:app.bundleURL.path ?: @"" forKey:app];
    [self publish];
}

- (void)publish {
    // Only the indexed ones: helpers come and go all day, and are nobody's business here.
    NSMutableSet<NSString *> *paths = [NSMutableSet setWithArray:[applications valueForKey:@"path"]];
    [paths intersectSet:[NSSet setWithArray:_pathOf.objectEnumerator.allObjects]];
    if ([paths isEqualToSet:_paths]) return;
    _paths = paths;
    [NSNotificationCenter.defaultCenter postNotificationName:DKApplicationsDidChangeNotification object:nil];
}

@end

static DKRunningApplications *running;

static NSArray<NSString *> *Folders(void) {
    // User applications come first so a per-user override in ~/Applications shadows a
    // system- or MDM-managed copy with the same name in /Applications.
    return @[ [NSHomeDirectory() stringByAppendingPathComponent:@"Applications"], @"/Applications", @"/Applications/Utilities",
              @"/System/Applications", @"/System/Applications/Utilities", @"/System/Library/CoreServices/Applications" ];
}

/// Applications in `folder` and, as Raycast lists them, in its plain subfolders (Houdini
/// keeps its apps two levels down), but not inside apps or frameworks.
static void AddApplications(NSString *folder, NSMutableArray<NSString *> *paths) {
    NSDirectoryEnumerator<NSURL *> *entries =
        [NSFileManager.defaultManager enumeratorAtURL:[NSURL fileURLWithPath:folder]
                           includingPropertiesForKeys:@[ NSURLIsDirectoryKey, NSURLIsPackageKey ]
                                              options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:nil];
    for (NSURL *entry in entries) {
        NSNumber *directory, *package;
        [entry getResourceValue:&directory forKey:NSURLIsDirectoryKey error:nil];
        [entry getResourceValue:&package forKey:NSURLIsPackageKey error:nil];
        if (!directory.boolValue) continue;
        if ([entry.pathExtension isEqualToString:@"app"]) [paths addObject:entry.path];
        if (package.boolValue || [entry.pathExtension isEqualToString:@"framework"] || entries.level >= 3) [entries skipDescendants];
    }
}

/// The names the app is also known by, as Raycast reads them: its file's name when the
/// title differs (Siri AI for Siri) and the names it declares (System Preferences for
/// System Settings, iCal for Calendar, Vault for Passwords).
static NSArray<NSString *> *AlternateTitles(NSBundle *bundle, NSString *title) {
    NSMutableArray<NSString *> *titles = [NSMutableArray new];
    NSString *file = bundle.bundlePath.lastPathComponent.stringByDeletingPathExtension;
    if (![file isEqualToString:title]) [titles addObject:file];
    NSArray *names = bundle.infoDictionary[@"CFBundleAlternateNames"];
    if ([names isKindOfClass:NSArray.class])
        for (NSString *name in names)
            if ([name isKindOfClass:NSString.class]) [titles addObject:bundle.localizedInfoDictionary[name] ?: name];
    return titles;
}

/// What else finds the app in Raycast: its bundle identifier and the Spotlight keywords it
/// declares ("Terminal" for Ghostty, "downloads" for the App Store).
static NSArray<NSString *> *Keywords(NSBundle *bundle) {
    NSMutableArray<NSString *> *keywords = [NSMutableArray new];
    if (bundle.bundleIdentifier) [keywords addObject:bundle.bundleIdentifier];
    NSString *declared = bundle.localizedInfoDictionary[@"MDItemKeywords"] ?: bundle.infoDictionary[@"MDItemKeywords"];
    if ([declared isKindOfClass:NSString.class])
        for (NSString *keyword in [declared componentsSeparatedByString:@","]) {
            NSString *trimmed = [keyword stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if (trimmed.length) [keywords addObject:trimmed];
        }
    return keywords;
}

static void Scan(void) {
    NSMutableArray *found = [NSMutableArray new];
    NSMutableSet *seen = [NSMutableSet new];
    NSFileManager *files = NSFileManager.defaultManager;
    // Finder and the places it opens as apps (AirDrop, Recents, iCloud Drive) live outside
    // the application folders but are launched like any other app.
    NSString *finder = @"/System/Library/CoreServices/Finder.app";
    NSMutableArray<NSString *> *paths = [NSMutableArray arrayWithObject:finder];
    AddApplications([finder stringByAppendingPathComponent:@"Contents/Applications"], paths);
    for (NSString *folder in Folders())
        for (NSString *name in [files contentsOfDirectoryAtPath:folder error:nil])
            if ([name.pathExtension isEqualToString:@"app"]) [paths addObject:[folder stringByAppendingPathComponent:name]];
    for (NSString *folder in @[ [NSHomeDirectory() stringByAppendingPathComponent:@"Applications"], @"/Applications" ])
        for (NSString *name in [files contentsOfDirectoryAtPath:folder error:nil]) {
            NSString *path = [folder stringByAppendingPathComponent:name];
            BOOL directory;
            if (!name.pathExtension.length && ![Folders() containsObject:path] && [files fileExistsAtPath:path isDirectory:&directory] && directory)
                AddApplications(path, paths);
        }
    for (NSString *path in paths) {
        NSString *title = [files displayNameAtPath:path];
        if ([title.pathExtension isEqualToString:@"app"]) title = title.stringByDeletingPathExtension;
        if ([seen containsObject:title]) continue;
        [seen addObject:title];
        NSBundle *bundle = [NSBundle bundleWithPath:path];
        [found addObject:@{@"title" : title, @"path" : path, @"alternateTitles" : AlternateTitles(bundle, title), @"keywords" : Keywords(bundle)}];
    }
    applications = found;
    [running publish];
    [NSNotificationCenter.defaultCenter postNotificationName:DKApplicationsDidChangeNotification object:nil];
}

void DKStartApplicationIndex(void) {
    if (applications) return;
    Scan();
    running = [DKRunningApplications new];
    for (NSString *folder in Folders()) DKWatchFolder(folder, ^{ Scan(); });
}

NSArray<NSDictionary *> *DKApplications(void) { return applications ?: @[]; }

NSSet<NSString *> *DKRunningApplicationPaths(void) { return running.paths ?: [NSSet set]; }
