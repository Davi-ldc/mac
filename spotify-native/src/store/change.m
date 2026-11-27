// Coalesced per-run-loop-turn state change delivery.
#import "store/change.h"

#import <CoreFoundation/CoreFoundation.h>

enum { kSPSetKinds = SPChangeLibraryLists };

@implementation SPChange {
    NSMutableSet<NSString *> *_sets[kSPSetKinds];
    NSUInteger _flags;
}

- (void)add:(SPChangeKind)kind value:(NSString *)value {
    if (kind >= kSPSetKinds) {
        _flags |= (NSUInteger)1 << (kind - kSPSetKinds);
        return;
    }
    NSMutableSet<NSString *> *set = _sets[kind] ?: (_sets[kind] = [NSMutableSet new]);
    if (value) [set addObject:value];
}

- (BOOL)isEmpty {
    if (_flags != 0) return NO;
    for (NSUInteger k = 0; k < kSPSetKinds; k++) {
        if (_sets[k] != nil) return NO;
    }
    return YES;
}

- (BOOL)hasFlag:(SPChangeKind)kind {
    return ((_flags >> (kind - kSPSetKinds)) & 1u) != 0;
}

- (NSSet<NSString *> *)tracks { return _sets[SPChangeTracks]; }
- (NSSet<NSString *> *)albums { return _sets[SPChangeAlbums]; }
- (NSSet<NSString *> *)artists { return _sets[SPChangeArtists]; }
- (NSSet<NSString *> *)playlists { return _sets[SPChangePlaylists]; }
- (NSSet<NSString *> *)favorites { return _sets[SPChangeFavorites]; }

- (BOOL)libraryLists { return [self hasFlag:SPChangeLibraryLists]; }
- (BOOL)homeShelves { return [self hasFlag:SPChangeHomeShelves]; }
- (BOOL)search { return [self hasFlag:SPChangeSearch]; }
- (BOOL)playback { return [self hasFlag:SPChangePlayback]; }
- (BOOL)devices { return [self hasFlag:SPChangeDevices]; }
- (BOOL)connection { return [self hasFlag:SPChangeConnection]; }
- (BOOL)profile { return [self hasFlag:SPChangeProfile]; }
- (BOOL)recentSearches { return [self hasFlag:SPChangeRecentSearches]; }

@end

@interface SPWeakChangeObserver : NSObject {
  @public
    __weak id<SPChangeObserver> _observer;
}
@end

@implementation SPWeakChangeObserver
@end

static NSMutableArray<SPChangeQueue *> *gWaitingQueues;

@implementation SPChangeQueue {
    NSMutableArray<SPWeakChangeObserver *> *_observers;
    SPChange *_pending;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _observers = [NSMutableArray new];
    return self;
}

- (void)addObserver:(id<SPChangeObserver>)observer {
    if (!observer) return;
    for (SPWeakChangeObserver *w in _observers) {
        if (w->_observer == observer) return;
    }
    SPWeakChangeObserver *w = [SPWeakChangeObserver new];
    w->_observer = observer;
    [_observers addObject:w];
}

- (void)removeObserver:(id<SPChangeObserver>)observer {
    if (!observer) return;
    NSMutableIndexSet *toRemove = [NSMutableIndexSet new];
    for (NSUInteger i = 0; i < _observers.count; i++) {
        id<SPChangeObserver> obs = _observers[i]->_observer;
        if (!obs || obs == observer) [toRemove addIndex:i];
    }
    [_observers removeObjectsAtIndexes:toRemove];
}

- (void)note:(SPChangeKind)kind value:(NSString *)value {
    if (_observers.count == 0) return;
    if (!_pending) {
        _pending = [SPChange new];
        [self scheduleFlush];
    }
    [_pending add:kind value:value];
}

- (void)scheduleFlush {
    static CFRunLoopObserverRef turnObserver = NULL;
    if (!turnObserver) {
        // Order 0 runs before Core Animation commits (order 2000000); Exit covers runUntilDate: loops.
        turnObserver = CFRunLoopObserverCreateWithHandler(
            NULL,
            kCFRunLoopBeforeWaiting | kCFRunLoopExit,
            true,
            0,
            ^(CFRunLoopObserverRef observer, CFRunLoopActivity activity) {
                SPFlushChanges();
            });
        CFRunLoopAddObserver(CFRunLoopGetMain(), turnObserver, kCFRunLoopCommonModes);
        gWaitingQueues = [NSMutableArray new];
    }
    if (![gWaitingQueues containsObject:self]) {
        [gWaitingQueues addObject:self];
    }
}

- (void)deliver {
    SPChange *change = _pending;
    _pending = nil;
    if (!change || change.isEmpty) return;

    NSMutableIndexSet *dead = [NSMutableIndexSet new];
    for (NSUInteger i = 0; i < _observers.count; i++) {
        if (!_observers[i]->_observer) [dead addIndex:i];
    }
    if (dead.count) [_observers removeObjectsAtIndexes:dead];

    NSArray<SPWeakChangeObserver *> *snapshot = [_observers copy];
    for (SPWeakChangeObserver *w in snapshot) {
        id<SPChangeObserver> obs = w->_observer;
        if (obs) [obs storeChanged:change];
    }
}

@end

void SPFlushChanges(void) {
    for (int round = 0; round < 8 && gWaitingQueues.count > 0; round++) {
        NSArray<SPChangeQueue *> *batch = gWaitingQueues;
        gWaitingQueues = [NSMutableArray new];
        for (SPChangeQueue *queue in batch) {
            [queue deliver];
        }
    }
    // If re-entrant observers hit the 8-round cap, wake the main run loop so queued changes never strand.
    if (gWaitingQueues.count > 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            SPFlushChanges();
        });
        CFRunLoopWakeUp(CFRunLoopGetMain());
    }
}
