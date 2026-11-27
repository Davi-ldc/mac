// Launch tracing (SP_TRACE=1) and monotonic time / physical memory footprint helpers.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

void SPTraceInit(void);
void SPTraceLaunch(const char *stage);
double SPMonotonicNowMs(void);
double SPProcessFootprintMB(void);

NS_ASSUME_NONNULL_END
