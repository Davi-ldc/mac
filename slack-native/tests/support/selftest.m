// Owns `--selftest` and `--snapshot`: the registry, the runner and the checks' report.
#import "model/user.h"
#import "net/switches.h"
#import "render/emoji.h"
#import "render/images.h"
#import "render/strings.h"
#import "snapshot.h"
#import "test.h"

typedef struct {
    const char *name;
    SNTestFunction function;
    SNCaseKind kind;
    double seconds;
} SNCaseEntry;

static SNCaseEntry cases[512];
static int caseCount, failures;
static NSURL *repository;

void SNRegisterTest(const char *name, SNTestFunction function, SNCaseKind kind) {
    if (caseCount == (int)(sizeof cases / sizeof *cases)) abort();
    cases[caseCount++] = (SNCaseEntry){name, function, kind, 0};
}

void SNCheck(BOOL condition, const char *what, const char *file, int line) {
    if (condition) {
        printf("ok   %s\n", what);
        return;
    }
    printf("FAIL %s (%s:%d)\n", what, strrchr(file, '/') ? strrchr(file, '/') + 1 : file, line);
    failures++;
}

NSURL *SNRepository(void) { return repository; }
NSURL *SNPublicFixture(void) { return [repository URLByAppendingPathComponent:@"tests/fixtures"]; }

NSURL *SNPrivateFixture(void) {
    NSURL *folder = [repository URLByAppendingPathComponent:@"design/fixtures"];
    return [NSFileManager.defaultManager fileExistsAtPath:[folder URLByAppendingPathComponent:@"auth.test.json"].path] ? folder : nil;
}

void SNSettle(NSTimeInterval seconds) { [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]]; }

SNChange *SNChangeOf(SNChangeKind kind, NSString *value) {
    SNChange *change = [SNChange new];
    [change add:kind value:value];
    return change;
}

@interface SNTestObserver : NSObject <SNChangeObserver>
@property (nonatomic, copy, nullable) void (^block)(SNChange *change);
@end

@implementation SNTestObserver
- (void)sourceChanged:(SNChange *)change {
    if (self.block) self.block(change);
}
@end

/// Observers stay until stopped: sources hold them weakly.
static NSMutableSet<SNTestObserver *> *observers;

id SNObserveChanges(id<SNSource> source, void (^block)(SNChange *change)) {
    SNTestObserver *observer = [SNTestObserver new];
    observer.block = block;
    [source addChangeObserver:observer];
    if (!observers) observers = [NSMutableSet new];
    [observers addObject:observer];
    return observer;
}

void SNStopObserving(SNTestObserver *observer) {
    observer.block = nil;
    [observers removeObject:observer];
}

static int CompareNames(const void *a, const void *b) { return strcmp(((const SNCaseEntry *)a)->name, ((const SNCaseEntry *)b)->name); }

static int CompareTimes(const void *a, const void *b) {
    double x = (*(SNCaseEntry *const *)a)->seconds, y = (*(SNCaseEntry *const *)b)->seconds;
    return x < y ? 1 : x > y ? -1 : 0;
}

/// What a store or a fixture sets process-wide goes back to a fresh process's state, so a case
/// passes alone (a name filter) as it does after the others.
static void ResetGlobals(NSTimeZone *zone) {
    // A case's last changes reach its own views, not the next case's.
    SNFlushChanges();
    NSTimeZone.defaultTimeZone = zone;
    SNSetShowsFullNames(NO);
    if (SNCustomEmojiNames().count) SNSetCustomEmoji(@{});
    if (![SNLanguage() isEqualToString:@"en"]) SNSetLanguage(@"en");
    SNSetImageFetcher(nil);
    SNSetReadOnly(NO);
    SNSetTraceFile(nil);
}

/// `names`: a case runs when its name contains one of them; with none, the cases of `kind`.
static BOOL Selected(const SNCaseEntry *entry, SNCaseKind kind, NSArray<NSString *> *names) {
    if ((entry->kind == SNCaseSnapshot) != (kind == SNCaseSnapshot)) return NO;
    if (!names.count) return entry->kind == kind;
    NSString *name = @(entry->name);
    for (NSString *part in names)
        if ([name containsString:part]) return YES;
    return NO;
}

/// The report of a run whose cases ran in shards: each case's lines, in name order, from the
/// shards' outputs. A shard that died reports a failure.
static int Merge(NSArray<NSString *> *outputs, NSArray<NSTask *> *tasks, SNCaseKind kind, CFTimeInterval start) {
    NSMutableArray<NSString *> *blocks = [NSMutableArray new];
    NSMutableArray<NSArray *> *times = [NSMutableArray new];
    int failed = 0;
    for (NSUInteger i = 0; i < outputs.count; i++) {
        NSString *output = [NSString stringWithContentsOfFile:outputs[i] encoding:NSUTF8StringEncoding error:nil] ?: @"";
        NSString *last = nil;
        for (NSString *block in [output componentsSeparatedByString:@"\n-- "]) {
            NSString *text = [block hasPrefix:@"-- "] ? [block substringFromIndex:3] : block;
            if (!text.length) continue;
            [blocks addObject:[@"-- " stringByAppendingString:text]];
            NSString *name = [text componentsSeparatedByString:@"\n"].firstObject;
            last = name;
            // The case's time is its last line.
            double ms = 0;
            for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
                if ([line hasPrefix:@"FAIL "]) failed++;
                if ([line hasPrefix:@"   "] && [line hasSuffix:@" ms"]) ms = line.doubleValue;
            }
            [times addObject:@[ @(ms), name ]];
        }
        if (tasks[i].terminationReason == NSTaskTerminationReasonUncaughtSignal) {
            [blocks addObject:[NSString stringWithFormat:@"FAIL shard %lu died (signal %d) in %@", (unsigned long)i, tasks[i].terminationStatus, last ?: @"its first case"]];
            failed++;
        }
    }
    [blocks sortUsingSelector:@selector(compare:)];
    for (NSString *block in blocks) printf("%s%s", block.UTF8String, [block hasSuffix:@"\n"] ? "" : "\n");
    [times sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) { return [b[0] compare:a[0]]; }];
    printf("slowest:");
    for (NSUInteger i = 0; i < MIN(times.count, (NSUInteger)10); i++)
        printf(" %s %.2f s%s", [times[i][1] UTF8String], [times[i][0] doubleValue] / 1000, i + 1 < MIN(times.count, (NSUInteger)10) ? "," : "");
    printf("\n%lu %s, %d failed, %.1f s in %lu shards\n", (unsigned long)times.count, kind == SNCaseSnapshot ? "snapshots" : "tests", failed,
           CACurrentMediaTime() - start, (unsigned long)tasks.count);
    return failed ? 1 : 0;
}

/// Runs the selected cases in `jobs` copies of this process at once (most cases wait on timers
/// and run loops, not the CPU), each taking every jobs-th case by name; `arguments` are this run's.
static int RunShards(int jobs, NSArray<NSString *> *arguments, SNCaseKind kind) {
    CFTimeInterval start = CACurrentMediaTime();
    NSString *folder = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"sn-selftest-%d", getpid()]];
    [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
    NSMutableArray<NSTask *> *tasks = [NSMutableArray new];
    NSMutableArray<NSString *> *outputs = [NSMutableArray new];
    for (int i = 0; i < jobs; i++) {
        NSString *output = [folder stringByAppendingPathComponent:[NSString stringWithFormat:@"%d.txt", i]];
        [NSFileManager.defaultManager createFileAtPath:output contents:nil attributes:nil];
        NSTask *task = [NSTask new];
        task.executableURL = NSBundle.mainBundle.executableURL;
        task.arguments = [arguments arrayByAddingObjectsFromArray:@[ @"--shard", [NSString stringWithFormat:@"%d/%d", i, jobs] ]];
        task.standardOutput = [NSFileHandle fileHandleForWritingAtPath:output];
        [outputs addObject:output];
        [tasks addObject:task];
        if (![task launchAndReturnError:nil]) return 1;
    }
    for (NSTask *task in tasks) [task waitUntilExit];
    int result = Merge(outputs, tasks, kind, start);
    [NSFileManager.defaultManager removeItemAtPath:folder error:nil];
    return result;
}

/// `--jobs N` (default: up to 8, one per core) and `--shard I/N` (one of a run's shards) out of
/// `arguments`; what is left are names.
static NSMutableArray<NSString *> *Options(NSArray<NSString *> *arguments, int *jobs, int *shard) {
    NSMutableArray<NSString *> *names = [arguments mutableCopy];
    *jobs = (int)MIN(NSProcessInfo.processInfo.activeProcessorCount, 8);
    *shard = -1;
    NSUInteger at = [names indexOfObject:@"--jobs"];
    if (at != NSNotFound && at + 1 < names.count) {
        *jobs = MAX(1, names[at + 1].intValue);
        [names removeObjectsInRange:NSMakeRange(at, 2)];
    }
    at = [names indexOfObject:@"--shard"];
    if (at != NSNotFound && at + 1 < names.count) {
        NSArray<NSString *> *parts = [names[at + 1] componentsSeparatedByString:@"/"];
        *shard = parts.firstObject.intValue;
        *jobs = MAX(1, parts.lastObject.intValue);
        [names removeObjectsInRange:NSMakeRange(at, 2)];
    }
    return names;
}

static int Run(NSString *root, SNCaseKind kind, NSArray<NSString *> *arguments, NSArray<NSString *> *names, int jobs, int shard) {
    repository = [NSURL fileURLWithPath:root isDirectory:YES];
    // Headless: no Dock icon, no menu bar, and the app can never become active.
    NSApplication.sharedApplication.activationPolicy = NSApplicationActivationPolicyProhibited;
    qsort(cases, (size_t)caseCount, sizeof *cases, CompareNames);
    int selected = 0;
    for (int i = 0; i < caseCount; i++) selected += Selected(&cases[i], kind, names);
    if (shard < 0 && jobs > 1 && selected > 1) return RunShards(MIN(jobs, selected), arguments, kind);
    NSTimeZone *zone = NSTimeZone.defaultTimeZone;
    SNCaseEntry *ran[512];
    int count = 0, index = 0;
    CFTimeInterval start = CACurrentMediaTime();
    for (int i = 0; i < caseCount; i++) {
        if (!Selected(&cases[i], kind, names) || (shard >= 0 && index++ % jobs != shard)) continue;
        printf("-- %s\n", cases[i].name);
        ResetGlobals(zone);
        CFTimeInterval began = CACurrentMediaTime();
        @autoreleasepool {
            cases[i].function();
        }
        cases[i].seconds = CACurrentMediaTime() - began;
        printf("   %.0f ms\n", cases[i].seconds * 1000);
        ran[count++] = &cases[i];
    }
    // A shard's report is merged by the run that started it.
    if (shard >= 0) return failures ? 1 : 0;
    qsort(ran, (size_t)count, sizeof *ran, CompareTimes);
    printf("slowest:");
    for (int i = 0; i < MIN(count, 10); i++) printf(" %s %.2f s%s", ran[i]->name, ran[i]->seconds, i + 1 < MIN(count, 10) ? "," : "");
    printf("\n%d %s, %d failed, %.1f s\n", count, kind == SNCaseSnapshot ? "snapshots" : "tests", failures, CACurrentMediaTime() - start);
    return failures ? 1 : 0;
}

int SNRunSelfTest(NSString *root, NSArray<NSString *> *arguments) {
    int jobs, shard;
    NSMutableArray<NSString *> *names = Options(arguments, &jobs, &shard);
    BOOL slow = [names containsObject:@"--slow"];
    [names removeObject:@"--slow"];
    NSArray *base = [@[ @"--selftest", root ] arrayByAddingObjectsFromArray:slow ? @[ @"--slow" ] : @[]];
    return Run(root, slow ? SNCaseSlow : SNCaseTest, [base arrayByAddingObjectsFromArray:names], names, jobs, shard);
}

int SNRunSnapshots(NSString *root, NSString *output, NSArray<NSString *> *arguments) {
    int jobs, shard;
    NSMutableArray<NSString *> *names = Options(arguments, &jobs, &shard);
    SNSetSnapshotOutput([NSURL fileURLWithPath:output isDirectory:YES]);
    return Run(root, SNCaseSnapshot, [@[ @"--snapshot", root, output ] arrayByAddingObjectsFromArray:names], names, jobs, shard);
}
