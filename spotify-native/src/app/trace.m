// Launch phase timing (enabled via SP_TRACE=1) and physical footprint measurement.
#import "app/trace.h"

#import <mach/mach.h>
#import <mach/mach_time.h>
#import <stdio.h>
#import <stdlib.h>

static BOOL gTraceEnabled = NO;
static double gStartMs = 0.0;

double SPMonotonicNowMs(void) {
    static mach_timebase_info_data_t tb;
    if (tb.denom == 0) mach_timebase_info(&tb);
    return (double)mach_absolute_time() * (double)tb.numer / (double)tb.denom / 1e6;
}

double SPProcessFootprintMB(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) == KERN_SUCCESS) {
        return (double)info.phys_footprint / (1024.0 * 1024.0);
    }
    return 0.0;
}

void SPTraceInit(void) {
    gStartMs = SPMonotonicNowMs();
    const char *env = getenv("SP_TRACE");
    gTraceEnabled = (env && env[0] == '1');
}

void SPTraceLaunch(const char *stage) {
    if (!gTraceEnabled) return;
    double elapsed = SPMonotonicNowMs() - gStartMs;
    fprintf(stderr, "[SP_TRACE] %-16s +%6.1f ms (phys %.1f MB)\n", stage, elapsed, SPProcessFootprintMB());
    fflush(stderr);
}
