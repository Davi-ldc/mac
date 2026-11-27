// Owns copying new screenshots in ~/Pictures to the clipboard.
#import <AppKit/AppKit.h>

#import "features.h"
#import "folderwatch.h"

// Only a file this fresh is a screenshot just taken, not an old one moved into the folder.
static const NSTimeInterval kFreshSeconds = 5;

static BOOL IsScreenshotName(NSString *name) {
    return [name.pathExtension isEqualToString:@"png"] && ([name hasPrefix:@"Screenshot"] || [name hasPrefix:@"Captura"]);
}

void DKStartScreenshotCopy(void) {
    NSString *folder = [NSHomeDirectory() stringByAppendingPathComponent:@"Pictures"];
    // Names copied within the freshness window, with when; older names fail the freshness
    // test anyway, so they are forgotten.
    static NSMutableDictionary<NSString *, NSDate *> *copied;
    copied = [NSMutableDictionary new];
    DKWatchFolder(folder, ^{
        for (NSString *name in copied.allKeys)
            if (-copied[name].timeIntervalSinceNow > kFreshSeconds) [copied removeObjectForKey:name];
        NSFileManager *files = NSFileManager.defaultManager;
        // The event does not say which entry changed, so the folder is listed; only names
        // that look like screenshots are looked at further.
        for (NSString *name in [files contentsOfDirectoryAtPath:folder error:nil]) {
            if (!IsScreenshotName(name) || copied[name]) continue;
            NSString *path = [folder stringByAppendingPathComponent:name];
            NSDate *modified = [files attributesOfItemAtPath:path error:nil].fileModificationDate;
            if (!modified || -modified.timeIntervalSinceNow > kFreshSeconds) continue;
            NSData *png = [NSData dataWithContentsOfFile:path];
            if (!png) continue;
            copied[name] = NSDate.date;
            [NSPasteboard.generalPasteboard clearContents];
            [NSPasteboard.generalPasteboard setData:png forType:NSPasteboardTypePNG];
        }
    });
}
