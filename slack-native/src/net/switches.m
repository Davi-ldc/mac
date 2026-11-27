// Owns the SN_TRACE and SN_READONLY switches and the trace file.
#import <stdatomic.h>
#import <sys/sysctl.h>
#import <sys/time.h>

#import "net/switches.h"

/// Past this size the trace moves to <file>.1 (replacing the one before) and starts over.
static const long SNTraceLimit = 1024 * 1024;

static BOOL readOnlyConfigured, readOnly;
/// Guarded by @synchronized(NSURL.class); `tracing` mirrors whether it is set.
static NSURL *traceFile;
static FILE *traceStream;
static atomic_bool tracing;

static BOOL EnvironmentSwitch(const char *name) {
    const char *value = getenv(name);
    return value && strcmp(value, "1") == 0;
}

static void ReadTraceSwitch(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!EnvironmentSwitch("SN_TRACE")) return;
        NSURL *library = [NSFileManager.defaultManager URLsForDirectory:NSLibraryDirectory inDomains:NSUserDomainMask].firstObject;
        traceFile = [library URLByAppendingPathComponent:@"Logs/slack-native/trace.log"];
        atomic_store(&tracing, true);
    });
}

BOOL SNTracing(void) {
    ReadTraceSwitch();
    return atomic_load_explicit(&tracing, memory_order_relaxed);
}

NSURL *SNTraceFile(void) {
    ReadTraceSwitch();
    @synchronized(NSURL.class) {
        return traceFile;
    }
}

void SNSetTraceFile(NSURL *file) {
    ReadTraceSwitch();
    @synchronized(NSURL.class) {
        traceFile = file;
        atomic_store(&tracing, file != nil);
        if (traceStream) fclose(traceStream);
        traceStream = NULL;
    }
}

void SNWriteTrace(NSString *name, NSInteger status, NSString *outcome, double milliseconds, NSUInteger bytes) {
    NSURL *file = SNTraceFile();
    if (!file) return;
    struct timeval now;
    gettimeofday(&now, NULL);
    struct tm local;
    localtime_r(&now.tv_sec, &local);
    char stamp[32];
    strftime(stamp, sizeof stamp, "%Y-%m-%d %H:%M:%S", &local);
    NSString *line = [NSString stringWithFormat:@"%s.%03d\t%@\t%@\t%@\t%@\t%lu\n", stamp, (int)(now.tv_usec / 1000), name,
                                                status ? @(status).stringValue : @"-", outcome,
                                                milliseconds >= 0 ? [NSString stringWithFormat:@"%.0f", milliseconds] : @"-", (unsigned long)bytes];
    @synchronized(NSURL.class) {
        if (!traceStream) {
            [NSFileManager.defaultManager createDirectoryAtURL:file.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
            traceStream = fopen(file.fileSystemRepresentation, "a");
        }
        if (!traceStream) return;
        fputs(line.UTF8String, traceStream);
        fflush(traceStream);
        if (ftell(traceStream) < SNTraceLimit) return;
        fclose(traceStream);
        traceStream = NULL;
        rename(file.fileSystemRepresentation, [file.path stringByAppendingString:@".1"].fileSystemRepresentation);
    }
}

void SNWriteLaunchStep(NSString *step) {
    static struct timeval started;
    static NSMutableSet<NSString *> *written;
    @synchronized(NSURL.class) {
        if (!written) {
            written = [NSMutableSet new];
            struct kinfo_proc info;
            size_t size = sizeof info;
            int name[] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
            if (sysctl(name, 4, &info, &size, NULL, 0) == 0) started = info.kp_proc.p_starttime;
        }
        // Only a launch traced from main(): a test process that turns tracing on later has none.
        if ([written containsObject:step] || (!written.count && ![step isEqualToString:@"main"])) return;
        [written addObject:step];
    }
    struct timeval now;
    gettimeofday(&now, NULL);
    double milliseconds = (now.tv_sec - started.tv_sec) * 1000.0 + (now.tv_usec - started.tv_usec) / 1000.0;
    SNWriteTrace([@"launch:" stringByAppendingString:step], 0, @"ok", milliseconds, 0);
}

BOOL SNReadOnly(void) {
    if (!readOnlyConfigured) {
        readOnlyConfigured = YES;
        readOnly = EnvironmentSwitch("SN_READONLY");
    }
    return readOnly;
}

void SNSetReadOnly(BOOL value) {
    readOnlyConfigured = YES;
    readOnly = value;
}

BOOL SNIsMutatingMethod(NSString *method) {
    // Searching and the edge API (Slack's read cache) change nothing; the upload URL is an
    // upload's first step.
    if ([method hasPrefix:@"search."] || [method hasPrefix:@"edge:"] || [method isEqualToString:@"gif.featured"]) return NO;
    if ([method hasPrefix:@"files.getUpload"]) return YES;
    static NSSet<NSString *> *reads;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        reads = [NSSet setWithObjects:@"list", @"info", @"history", @"replies", @"counts", @"userBoot", @"dms", @"teamInfo", @"test",
                                      @"members", @"boot", @"feed", @"appCommands", nil];
    });
    NSString *verb = [method componentsSeparatedByString:@"."].lastObject;
    // conversations.searchLinks searches as search.* does.
    return !([reads containsObject:verb] || [verb hasPrefix:@"get"] || [verb hasPrefix:@"search"]);
}
