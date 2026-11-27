// Owns fixture launches and the memory measurement.
#import <mach/mach.h>

#import "app/launch.h"
#import "render/images.h"
#import "render/strings.h"
#import "ui/shell/shell.h"

SNFixtureSource *SNOpenFixture(NSURL *folder) {
    SNFixtureSource *source = [SNFixtureSource sourceWithFolder:folder];
    if (!source) return nil;
    SNSetLanguage(source.me.locale ?: @"en");
    __weak SNFixtureSource *weakSource = source;
    SNSetImageFetcher(^(NSURL *url, void (^completion)(NSData *)) {
        NSURL *file = url.isFileURL ? url : [weakSource imageFileForURL:url];
        if (!file) return completion(nil);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            completion([NSData dataWithContentsOfURL:file]);
        });
    });
    return source;
}

/// What Activity Monitor calls Memory: the process's physical footprint.
static double FootprintMB(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return -1;
    return info.phys_footprint / 1048576.0;
}

/// A signed-in launch's store, from the cache alone.
static SNStore *OpenCache(NSURL *url) {
    SNDatabase *database = [NSFileManager.defaultManager fileExistsAtPath:url.path] ? [SNDatabase databaseAtURL:url] : nil;
    SNStore *store = database ? [[SNStore alloc] initWithDatabase:database api:nil] : nil;
    if (!store.hasState) return nil;
    SNSetLanguage(store.me.locale ?: @"en");
    return store;
}

int SNMeasureMemory(NSURL *fixture) {
    NSApplication.sharedApplication.activationPolicy = NSApplicationActivationPolicyProhibited;
    printf("memory footprint at start: %.1f MB\n", FootprintMB());
    NSDate *start = NSDate.date;
    SNStore *source = [fixture.pathExtension isEqualToString:@"sqlite"] ? OpenCache(fixture) : SNOpenFixture(fixture);
    if (!source) {
        fprintf(stderr, "no fixture or cache at %s\n", fixture.path.UTF8String);
        return 1;
    }
    SNShell *shell = [[SNShell alloc] initWithSource:source defaults:nil];
    NSWindow *window = shell.window;
    [window.contentView layoutSubtreeIfNeeded];
    // Core Animation draws the layers of views that need display whether or not the window is on
    // screen, so their backing stores exist as they would after a first frame.
    [window displayIfNeeded];
    [CATransaction flush];
    printf("first frame drawn %.0f ms after start\n", -start.timeIntervalSinceNow * 1000);
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:2];
    while (until.timeIntervalSinceNow > 0 || SNImageLoadsInFlight())
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    printf("memory footprint with the window drawn: %.1f MB\n", FootprintMB());
    return 0;
}
