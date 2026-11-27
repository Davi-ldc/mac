// Owns folder watching. A vnode source on the folder wakes only for changes to the
// folder's own entries; FSEvents would also report everything beneath it, which for
// ~/Pictures includes every write to the Photos library.
#import "folderwatch.h"

static NSMutableArray<dispatch_source_t> *sources;

BOOL DKWatchFolder(NSString *folder, void (^handler)(void)) {
    int fd = open(folder.fileSystemRepresentation, O_EVTONLY);
    if (fd < 0) return NO;
    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, (uintptr_t)fd, DISPATCH_VNODE_WRITE,
                                                      dispatch_get_main_queue());
    dispatch_source_set_event_handler(source, handler);
    dispatch_source_set_cancel_handler(source, ^{ close(fd); });
    dispatch_resume(source);
    if (!sources) sources = [NSMutableArray new];
    [sources addObject:source];
    return YES;
}
