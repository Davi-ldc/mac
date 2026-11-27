// Owns `--bench <fixture>` (`make bench`, on the generated scale fixture): the whole window over
// the fixture with its busiest conversation open, then bursts of websocket events as Slack sends
// them (presence, messages, reactions), each timed through to the frame drawn after it, and the
// footprint once eight conversations hold their whole history.
#import <mach/mach.h>
#import <objc/runtime.h>

#import "app/launch.h"
#import "render/images.h"
#import "store/fixture.h"
#import "store/internal.h"
#import "test.h"
#import "ui/channel/list.h"
#import "ui/kit/list.h"
#import "ui/shell/shell.h"

/// What a burst makes the window do: changes delivered to observers, lists shown anew, list rows
/// refreshed, message lists shown anew and changed in place.
static NSUInteger gChanges, gListsShown, gRowsRefreshed, gMessagesShown, gMessagesChanged;

@implementation SNListView (BenchCount)
- (void)bench_showKeys:(NSArray<NSString *> *)keys {
    gListsShown++;
    [self bench_showKeys:keys];
}
- (void)bench_refreshKeys:(NSSet<NSString *> *)keys {
    gRowsRefreshed += keys.count;
    [self bench_refreshKeys:keys];
}
@end

@implementation SNMessageListView (BenchCount)
- (void)bench_showMessages:(NSArray<SNMessage *> *)messages inConversation:(NSString *)conversationID threadTS:(NSString *)threadTS lastRead:(NSString *)lastRead {
    gMessagesShown++;
    [self bench_showMessages:messages inConversation:conversationID threadTS:threadTS lastRead:lastRead];
}
- (BOOL)bench_showChangedMessages:(SNChange *)change {
    gMessagesChanged++;
    return [self bench_showChangedMessages:change];
}
@end

static void Count(Class class, SEL original, SEL counting) {
    method_exchangeImplementations(class_getInstanceMethod(class, original), class_getInstanceMethod(class, counting));
}

static double FootprintMB(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    return task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) == KERN_SUCCESS ? info.phys_footprint / 1048576.0 : -1;
}

/// The frame after a change: layout, the layers that need display, and the commit.
static void Draw(NSWindow *window) {
    [window.contentView layoutSubtreeIfNeeded];
    [window displayIfNeeded];
    [CATransaction flush];
}

static void Settle(NSWindow *window, NSTimeInterval seconds) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (until.timeIntervalSinceNow > 0) [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    Draw(window);
}

/// Applies `count` events twice, timing each event with its change delivered and printing the
/// frame after them: first in a run-loop turn each (frames arriving apart), then all in one turn
/// (frames arriving together, as a busy socket hands them over).
static void Burst(const char *name, NSUInteger count, SNStore *store, NSWindow *window, NSDictionary * (^event)(NSUInteger i, BOOL together)) {
    for (int together = 0; together < 2; together++) {
        NSMutableArray<NSDictionary *> *events = [NSMutableArray arrayWithCapacity:count];
        for (NSUInteger i = 0; i < count; i++) [events addObject:event(i, together)];
        gChanges = gListsShown = gRowsRefreshed = gMessagesShown = gMessagesChanged = 0;
        CFTimeInterval start = CACurrentMediaTime();
        // A pool per event, as the websocket's run-loop turns have.
        for (NSDictionary *each in events) @autoreleasepool {
                [store applyEvent:each];
                if (!together) SNFlushChanges();
            }
        SNFlushChanges();
        CFTimeInterval applied = CACurrentMediaTime();
        Draw(window);
        CFTimeInterval drawn = CACurrentMediaTime();
        printf("bench: %lu %s events, %s: %.0f ms (%.1f us each), frame after %.1f ms; %lu changes delivered, %lu lists and %lu message lists shown "
               "anew, %lu rows refreshed, %lu message list changes\n",
               (unsigned long)count, name, together ? "one turn" : "a turn each", (applied - start) * 1000, (applied - start) * 1e6 / count,
               (drawn - applied) * 1000, (unsigned long)gChanges, (unsigned long)gListsShown, (unsigned long)gMessagesShown, (unsigned long)gRowsRefreshed,
               (unsigned long)gMessagesChanged);
    }
}

int SNRunBench(NSURL *folder) {
    NSApplication.sharedApplication.activationPolicy = NSApplicationActivationPolicyProhibited;
    double startMB = FootprintMB();
    CFTimeInterval start = CACurrentMediaTime();
    SNFixtureSource *source = SNOpenFixture(folder);
    if (!source) {
        fprintf(stderr, "no fixture at %s (make bench generates it)\n", folder.path.UTF8String);
        return 1;
    }
    CFTimeInterval loaded = CACurrentMediaTime();
    SNShell *shell = [[SNShell alloc] initWithSource:source defaults:nil];
    NSWindow *window = shell.window;
    Draw(window);
    printf("bench: %lu users, %lu conversations loaded in %.0f ms, first frame %.0f ms later\n", (unsigned long)source.users.count,
           (unsigned long)source.conversationsByID.count, (loaded - start) * 1000, (CACurrentMediaTime() - loaded) * 1000);

    // The busy channels are the ones with history, by ID.
    NSMutableArray<NSString *> *busy = [NSMutableArray new];
    for (NSString *conversationID in source.cachedConversationIDs)
        if ([source messagesInConversation:conversationID].count) [busy addObject:conversationID];
    [busy sortUsingSelector:@selector(compare:)];
    // One the window does not show yet (it opens on the first channel).
    NSString *shown = busy.lastObject;
    if (!shown) {
        fprintf(stderr, "the fixture has no conversation with messages\n");
        return 1;
    }
    start = CACurrentMediaTime();
    [shell openConversation:shown];
    while ([source isLoadingMessagesInConversation:shown]) [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
    Draw(window);
    printf("bench: opening %s %.1f ms\n", shown.UTF8String, (CACurrentMediaTime() - start) * 1000);
    Settle(window, 0.5);
    printf("bench: footprint %.1f MB (%.1f at start)\n", FootprintMB(), startMB);

    Count(SNListView.class, @selector(showKeys:), @selector(bench_showKeys:));
    Count(SNListView.class, @selector(refreshKeys:), @selector(bench_refreshKeys:));
    Count(SNMessageListView.class, @selector(showMessages:inConversation:threadTS:lastRead:), @selector(bench_showMessages:inConversation:threadTS:lastRead:));
    Count(SNMessageListView.class, @selector(showChangedMessages:), @selector(bench_showChangedMessages:));
    SNObserveChanges(source, ^(SNChange *change) { gChanges++; });
    NSArray<SNUser *> *users = [source.users.allValues sortedArrayUsingComparator:^NSComparisonResult(SNUser *a, SNUser *b) { return [a.userID compare:b.userID]; }];
    NSArray<SNMessage *> *messages = [source messagesInConversation:shown];
    __block double ts = messages.lastObject.ts.doubleValue;
    Burst("presence_change", users.count, source, window, ^NSDictionary *(NSUInteger i, BOOL together) {
        return @{@"type" : @"presence_change", @"user" : users[i].userID, @"presence" : [source presenceOfUser:users[i].userID] == SNPresenceActive ? @"away" : @"active"};
    });
    Burst("message (shown conversation)", 1000, source, window, ^NSDictionary *(NSUInteger i, BOOL together) {
        ts += 1;
        return @{@"type" : @"message", @"channel" : shown, @"user" : users[1 + i % (users.count - 1)].userID, @"text" : @"a burst",
                 @"ts" : [NSString stringWithFormat:@"%.6f", ts], @"client_msg_id" : NSUUID.UUID.UUIDString.lowercaseString};
    });
    Burst("message (other conversations)", 1000, source, window, ^NSDictionary *(NSUInteger i, BOOL together) {
        ts += 1;
        return @{@"type" : @"message", @"channel" : busy.count > 1 ? busy[1 + i % (busy.count - 1)] : shown, @"user" : users[1 + i % (users.count - 1)].userID,
                 @"text" : @"elsewhere", @"ts" : [NSString stringWithFormat:@"%.6f", ts], @"client_msg_id" : NSUUID.UUID.UUIDString.lowercaseString};
    });
    messages = [source messagesInConversation:shown];
    Burst("reaction_added", 1000, source, window, ^NSDictionary *(NSUInteger i, BOOL together) {
        SNMessage *message = messages[messages.count - 1 - i % MIN(messages.count, (NSUInteger)40)];
        return @{@"type" : @"reaction_added", @"user" : users[1 + i % (users.count - 1)].userID, @"reaction" : together ? @"+1" : @"eyes",
                 @"item" : @{@"type" : @"message", @"channel" : shown, @"ts" : message.ts}};
    });
    Settle(window, 0.5);
    printf("bench: footprint after the bursts %.1f MB\n", FootprintMB());

    // Every page of the busy conversations, as scrolling to their start would load them.
    start = CACurrentMediaTime();
    NSUInteger held = 0;
    for (NSString *conversationID in busy) {
        [source loadConversation:conversationID];
        while ([source hasOlderMessagesInConversation:conversationID] || [source isLoadingMessagesInConversation:conversationID]) @autoreleasepool {
            if (![source isLoadingMessagesInConversation:conversationID]) [source loadOlderMessagesInConversation:conversationID];
            [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
        }
        held += [source messagesInConversation:conversationID].count;
        printf("bench: %s holds %lu messages; footprint %.1f MB\n", conversationID.UTF8String, (unsigned long)[source messagesInConversation:conversationID].count, FootprintMB());
    }
    Draw(window);
    printf("bench: %lu messages in %lu conversations paged in %.0f ms; footprint %.1f MB\n", (unsigned long)held, (unsigned long)busy.count,
           (CACurrentMediaTime() - start) * 1000, FootprintMB());
    while (SNImageLoadsInFlight()) [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    return 0;
}
