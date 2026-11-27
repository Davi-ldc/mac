// Owns collecting changes and delivering them once per run-loop turn.
#import "source/change.h"

/// The kinds before SNChangeLists carry sets.
enum { kSetKinds = SNChangeLists };

@implementation SNChange {
    NSMutableSet<NSString *> *_sets[kSetKinds];
    NSUInteger _flags;
}

- (void)add:(SNChangeKind)kind value:(NSString *)value {
    if (kind >= kSetKinds) {
        _flags |= (NSUInteger)1 << (kind - kSetKinds);
        return;
    }
    NSMutableSet *set = _sets[kind] ?: (_sets[kind] = [NSMutableSet new]);
    if (value) [set addObject:value];
}

- (BOOL)isEmpty {
    if (_flags) return NO;
    for (NSUInteger kind = 0; kind < kSetKinds; kind++)
        if (_sets[kind]) return NO;
    return YES;
}

- (BOOL)has:(SNChangeKind)kind { return (_flags >> (kind - kSetKinds)) & 1; }

- (NSSet *)users { return _sets[SNChangeUsers]; }
- (NSSet *)presence { return _sets[SNChangePresence]; }
- (NSSet *)usergroups { return _sets[SNChangeUsergroups]; }
- (NSSet *)conversations { return _sets[SNChangeConversations]; }
- (NSSet *)messages { return _sets[SNChangeMessages]; }
- (NSSet *)messageKeys { return _sets[SNChangeMessageKeys]; }
- (NSSet *)threads { return _sets[SNChangeThreads]; }
- (NSSet *)counts { return _sets[SNChangeCounts]; }
- (NSSet *)typing { return _sets[SNChangeTyping]; }
- (NSSet *)drafts { return _sets[SNChangeDrafts]; }
- (NSSet *)uploads { return _sets[SNChangeUploads]; }
- (NSSet *)huddles { return _sets[SNChangeHuddles]; }
- (NSSet *)profiles { return _sets[SNChangeProfiles]; }
- (BOOL)lists { return [self has:SNChangeLists]; }
- (BOOL)commands { return [self has:SNChangeCommands]; }
- (BOOL)emoji { return [self has:SNChangeEmoji]; }
- (BOOL)preferences { return [self has:SNChangePreferences]; }
- (BOOL)connection { return [self has:SNChangeConnection]; }
- (BOOL)timeZone { return [self has:SNChangeTimeZone]; }
- (BOOL)activity { return [self has:SNChangeActivity]; }
- (BOOL)huddleInvites { return [self has:SNChangeHuddleInvites]; }
- (BOOL)call { return [self has:SNChangeCall]; }
- (BOOL)vips { return [self has:SNChangeVIPs]; }
- (BOOL)recentFiles { return [self has:SNChangeRecentFiles]; }

@end

@interface SNWeakObserver : NSObject {
  @public
    __weak id<SNChangeObserver> _observer;
}
@end

@implementation SNWeakObserver
@end

/// Queues holding a change to deliver, in the order they noted their first.
static NSMutableArray<SNChangeQueue *> *gWaiting;

@implementation SNChangeQueue {
    NSMutableArray<SNWeakObserver *> *_observers;
    SNChange *_pending;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _observers = [NSMutableArray new];
    return self;
}

- (void)addObserver:(id<SNChangeObserver>)observer {
    SNWeakObserver *weak = [SNWeakObserver new];
    weak->_observer = observer;
    [_observers addObject:weak];
}

- (void)note:(SNChangeKind)kind value:(NSString *)value {
    // Nobody to tell: whoever starts observing reads the state as it is then.
    if (!_observers.count) return;
    if (!_pending) {
        _pending = [SNChange new];
        [self wait];
    }
    [_pending add:kind value:value];
}

- (void)wait {
    static CFRunLoopObserverRef turn;
    if (!turn) {
        // Order 0 runs before Core Animation's commit (2000000): views take the change into the
        // frame of the turn that made it. Exit covers runUntilDate: loops that end busy.
        turn = CFRunLoopObserverCreateWithHandler(NULL, kCFRunLoopBeforeWaiting | kCFRunLoopExit, true, 0,
                                                  ^(CFRunLoopObserverRef observer, CFRunLoopActivity activity) { SNFlushChanges(); });
        CFRunLoopAddObserver(CFRunLoopGetMain(), turn, kCFRunLoopCommonModes);
        gWaiting = [NSMutableArray new];
    }
    [gWaiting addObject:self];
}

- (void)deliver {
    SNChange *change = _pending;
    _pending = nil;
    if (!change) return;
    [_observers filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(SNWeakObserver *weak, NSDictionary *bindings) { return weak->_observer != nil; }]];
    for (SNWeakObserver *weak in [_observers copy]) [weak->_observer sourceChanged:change];
}

@end

void SNFlushChanges(void) {
    // Observers that change the source while they react are told in a further round; a few rounds
    // at most, so two that keep answering each other wait for the next turn.
    for (int round = 0; round < 8 && gWaiting.count; round++) {
        NSArray<SNChangeQueue *> *queues = gWaiting;
        gWaiting = [NSMutableArray new];
        for (SNChangeQueue *queue in queues) [queue deliver];
    }
    // Wake the next run-loop turn if changes remain after the cap so they are never stranded.
    if (gWaiting.count) dispatch_async(dispatch_get_main_queue(), ^{ SNFlushChanges(); });
}
