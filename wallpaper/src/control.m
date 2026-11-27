#import "livewall.h"

void LWIgnoreControlSignals(void) {
    signal(SIGUSR1, SIG_IGN);
    signal(SIGUSR2, SIG_IGN);
}

/// Runs `handler` on the main queue each time `number` arrives. The source lives as long
/// as the process.
static void OnSignal(int number, dispatch_block_t handler) {
    static NSMutableArray *sources;
    if (!sources) sources = [NSMutableArray new];
    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL,
                                                      (uintptr_t)number, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(source, handler);
    dispatch_resume(source);
    [sources addObject:source];
}

void LWHandleControlSignals(LWClock *clock) {
    OnSignal(SIGUSR1, ^{
        [clock setHold:LWHoldRequested active:YES];
    });
    OnSignal(SIGUSR2, ^{
        [clock setHold:LWHoldRequested active:NO];
    });
}
