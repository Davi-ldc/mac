// Owns `deskkit --bench`: a data folder of its own, the scenarios that drive the launcher
// through its paths, and the report.
//
// A path is timed from the call that stands for the hotkey or the key press to the end of
// the run loop pass that commits its frame to the window server ("frame"). That is where
// deskkit's own work ends: the window server shows the frame at its next refresh. The time
// includes the main thread's waits (on the window server, on Launch Services), which
// "frame, main thread's work only" leaves out. Whatever the main thread still does in the
// 50 ms after is reported as "after frame".
//
// The panel opens as DESKKIT_SHOW opens it, behind other windows and without focus, and key
// presses are events handed straight to it, so a run needs no hotkey and leaves whoever is
// at the Mac alone. A first open needs a process that has never opened the panel, so the
// scenarios run in child processes and the parent only seeds, collects and prints.
#import <Carbon/Carbon.h>
#import <mach/mach.h>
#import <pthread/qos.h>
#import <sys/resource.h>

#import "apps.h"
#import "bench.h"
#import "clipboard.h"
#import "clipboardscreen.h"
#import "crypto.h"
#import "panel.h"
#import "picker.h"
#import "quicklinkscreens.h"
#import "ranking.h"
#import "support.h"

static NSString *const kKeychainService = @"local.deskkit.bench";
static const NSUInteger kDefaultClips = 150, kImageClips = 3, kNewestTextClips = 3;
static const NSUInteger kFirstOpens = 12, kRuns = 40, kPausedOpens = 5;
static const NSTimeInterval kSettleSeconds = 0.05;
/// How long memory is watched after an action. What a redraw takes can be gone within a second.
static const NSTimeInterval kMemorySeconds = 2;
/// Every so many runs, one counts allocations instead of time: the count slows the run.
static const NSUInteger kCountEvery = 8;
static const double kKeysPerSecond = 12;

#pragma mark Samples

static uint64_t Now(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
/// Time the main thread has spent running, which leaves out its waits.
static uint64_t Worked(void) { return clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID); }

/// One sample for the report: the parent reads these lines from its children.
static void Emit(NSString *scenario, const char *stage, double value) {
    printf("%s\t%s\t%.4f\n", scenario.UTF8String, stage, value);
}

static struct {
    const char *stage;
    uint64_t at;
} marks[16];
static int markCount;
/// Start of the run being timed; 0 between runs.
static uint64_t started;
static uint64_t frameAt, workedAtFrame, wokeAt, busyAfterFrame;
static _Atomic unsigned long allocations;

void DKBenchMark(const char *stage) {
    if (!started || markCount == sizeof marks / sizeof *marks) return;
    marks[markCount].stage = stage;
    marks[markCount++].at = Now();
}

/// Runs last in each pass of the run loop, after Core Animation has committed the pass's
/// drawing.
static void PassEnded(CFRunLoopObserverRef observer, CFRunLoopActivity activity, void *info) {
    if (activity == kCFRunLoopAfterWaiting) {
        wokeAt = Now();
        return;
    }
    if (!started) return;
    if (!frameAt) {
        frameAt = Now();
        workedAtFrame = Worked();
    } else if (wokeAt) {
        busyAfterFrame += Now() - wokeAt;
    }
    wokeAt = 0;
}

typedef void(malloc_logger_t)(uint32_t type, uintptr_t arg1, uintptr_t arg2, uintptr_t arg3, uintptr_t result, uint32_t skip);
/// libmalloc calls this, when set, on every allocation and release.
extern malloc_logger_t *malloc_logger;

static void CountAllocation(uint32_t type, uintptr_t arg1, uintptr_t arg2, uintptr_t arg3, uintptr_t result, uint32_t skip) {
    const uint32_t allocate = 2;
    if (type & allocate) allocations++;
}

/// Handles events and timers as -[NSApplication run] does, for `seconds`.
static void Spin(NSTimeInterval seconds) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    do {
        @autoreleasepool {
            NSEvent *event = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:until inMode:NSDefaultRunLoopMode dequeue:YES];
            if (event) [NSApp sendEvent:event];
        }
    } while (until.timeIntervalSinceNow > 0);
}

/// A fixed piece of arithmetic, about a millisecond on this Mac's fastest core at full
/// speed. A thread that wakes from idle may get a slower core or a slowed one, and every
/// time in the report stretches with it: this is the yardstick for comparing two reports.
static void EmitReference(const char *moment) {
    uint64_t start = Now();
    volatile uint64_t x = 88172645463325252ull;
    for (int i = 0; i < 200000; i++) {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
    }
    Emit(@"reference work", moment, (Now() - start) / 1e6);
}

/// Times `action` and the frame it leads to. `returned` names the moment the action's call
/// returns: "ordered" for a show, "handled" for a key press.
static void Measure(NSString *scenario, const char *returned, void (^action)(void)) {
    static NSUInteger runs;
    BOOL counting = ++runs % kCountEvery == 0;
    markCount = 0;
    frameAt = busyAfterFrame = 0;
    allocations = 0;
    malloc_logger = counting ? CountAllocation : NULL;
    // As in the app's event loop, what the action autoreleased goes after its frame.
    uint64_t worked = Worked();
    @autoreleasepool {
        started = Now();
        action();
        DKBenchMark(returned);
        while (!frameAt) Spin(0.001);
    }
    malloc_logger = NULL;
    Spin(kSettleSeconds);
    if (counting) {
        Emit(scenario, "allocations", allocations);
    } else {
        for (int i = 0; i < markCount; i++) Emit(scenario, marks[i].stage, (marks[i].at - started) / 1e6);
        Emit(scenario, "frame", (frameAt - started) / 1e6);
        Emit(scenario, "frame, main thread's work only", (workedAtFrame - worked) / 1e6);
        Emit(scenario, "after frame", busyAfterFrame / 1e6);
    }
    started = 0;
    // After the same idle as the runs get, and followed by one, so as not to warm the next.
    if (runs % kCountEvery == kCountEvery / 2) {
        EmitReference("after 50 ms idle");
        Spin(kSettleSeconds);
    }
}

/// Times work that draws nothing.
static void Time(NSString *scenario, const char *stage, void (^work)(void)) {
    @autoreleasepool {
        uint64_t start = Now();
        work();
        Emit(scenario, stage, (Now() - start) / 1e6);
    }
}

static double Footprint(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return 0;
    return info.phys_footprint / 1048576.0;
}

static void EmitMemory(const char *moment) { Emit(@"memory footprint (MB)", moment, Footprint()); }

/// The most memory `action` comes to take while it is watched, and what is left at the end.
static void MeasureMemory(const char *moment, void (^action)(void)) {
    @autoreleasepool {
        action();
    }
    double highest = 0;
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:kMemorySeconds];
    while (until.timeIntervalSinceNow > 0) {
        Spin(0.01);
        highest = MAX(highest, Footprint());
    }
    Emit([NSString stringWithFormat:@"memory footprint (MB), highest in the %g s after", kMemorySeconds], moment, highest);
    Emit([NSString stringWithFormat:@"memory footprint (MB), %g s after", kMemorySeconds], moment, Footprint());
}

static double CPUSeconds(void) {
    struct rusage usage;
    getrusage(RUSAGE_SELF, &usage);
    return usage.ru_utime.tv_sec + usage.ru_stime.tv_sec + (usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6;
}

/// Share of one core the process uses while `work` runs.
static void EmitCPU(const char *moment, void (^work)(void)) {
    double cpu = CPUSeconds();
    uint64_t start = Now();
    work();
    Emit(@"CPU (% of a core)", moment, 100 * (CPUSeconds() - cpu) / ((Now() - start) / 1e9));
}

#pragma mark Keys

static DKPicker *launcher;

static NSWindow *Panel(void) {
    for (NSWindow *window in NSApp.windows)
        if ([window isKindOfClass:DKPanel.class] && window.visible) return window;
    return nil;
}

/// A key press handed to the panel as the window server would deliver it.
static void Press(unsigned short keyCode, NSString *characters, NSEventModifierFlags modifiers) {
    NSWindow *panel = Panel();
    [panel sendEvent:[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:modifiers
                                     timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:panel.windowNumber
                                       context:nil characters:characters charactersIgnoringModifiers:characters
                                     isARepeat:NO keyCode:keyCode]];
}

/// A letter, a digit, a symbol on an ANSI keyboard, a space or Esc ('\x1b').
static void PressCharacter(unichar character) {
    // Indexed by virtual key code, as on an ANSI keyboard; then what shift makes of the keys.
    static const char layout[] = "asdfhgzxcv\1bqweryt123465=97-80]ou[ip\1lj'k;\\,/nm.";
    static const char shifted[] = "ASDFHGZXCV\1BQWERYT!@#$^%+(&_*)}OU{IP\1LJ\"K:|<?NM>";
    const char *found = character < 128 ? strchr(layout, character) : NULL;
    const char *shift = character < 128 && !found ? strchr(shifted, character) : NULL;
    unsigned short keyCode = found ? found - layout : shift ? shift - shifted : character == ' ' ? kVK_Space : kVK_Escape;
    Press(keyCode, [NSString stringWithCharacters:&character length:1], shift ? NSEventModifierFlagShift : 0);
}

static void PressEscape(void) { PressCharacter('\x1b'); }

static void TypeUnmeasured(NSString *text) {
    @autoreleasepool {
        for (NSUInteger i = 0; i < text.length; i++) PressCharacter([text characterAtIndex:i]);
    }
    Spin(kSettleSeconds);
}

/// Types the words letter by letter, each press a sample, with Esc clearing the field
/// after each word.
static void TypeWords(NSArray<NSString *> *words, NSString *where) {
    for (NSString *word in words) {
        for (NSUInteger i = 0; i < word.length; i++)
            Measure([NSString stringWithFormat:@"type in %@, %@ letter", where, i ? @"later" : @"first"], "handled",
                    ^{ PressCharacter([word characterAtIndex:i]); });
        Measure([NSString stringWithFormat:@"type in %@, esc clears", where], "handled", ^{ PressEscape(); });
    }
}

#pragma mark Scenarios

static void Open(DKScreen *_Nullable screen) {
    @autoreleasepool {
        [launcher showForInspection:screen];
    }
    Spin(kSettleSeconds);
}

static void Close(void) {
    @autoreleasepool {
        [launcher hide];
    }
    Spin(kSettleSeconds);
}

/// Waits for the clipboard history, which is read off the main thread.
static void AwaitHistory(void) {
    while (!DKClipboardHistory.shared.loaded) Spin(0.01);
}

/// The first open of a process, as after login, and what follows it.
static void BenchFirstOpen(BOOL history) {
    Time(@"launch", "launcher made", ^{ launcher = DKBenchLauncher(); });
    Spin(1.5);
    AwaitHistory();
    EmitMemory("idle after launch");
    Measure(history ? @"first open, clipboard history" : @"first open, root", "ordered",
            ^{ [launcher showForInspection:history ? DKClipboardPage(launcher) : nil]; });
    EmitMemory(history ? "first open, clipboard history" : "first open, root");
    if (!history) Measure(@"first key after first open", "handled", ^{ PressCharacter('s'); });
    Close();
    Spin(1.5);
    EmitMemory("closed after first open");
    EmitReference("after 1.5 s idle");
}

/// Later opens of the root and of the clipboard history, each closed with something else on
/// screen than it opens with, as an open that follows use is: first one right after the
/// other, then with the panel left closed for a while in between, as in use.
static void BenchOpen(NSUInteger runs) {
    void (^open)(NSString *, NSTimeInterval, const char *) = ^(NSString *scenario, NSTimeInterval closedFor, const char *memory) {
        BOOL history = [scenario containsString:@"history"];
        Spin(closedFor);
        Measure(scenario, "ordered", ^{ [launcher showForInspection:history ? DKClipboardPage(launcher) : nil]; });
        if (memory) {
            Spin(1);
            EmitMemory(memory);
        }
        TypeUnmeasured(@"s");
        Time(@"close", "hidden", ^{ [launcher hide]; });
    };
    for (NSUInteger i = 0; i < runs; i++) {
        open(@"open root", kSettleSeconds, NULL);
        open(@"open clipboard history", kSettleSeconds, NULL);
    }
    for (NSUInteger i = 0; i < kPausedOpens; i++) {
        open(@"open root, closed for 5 s", 5, i ? NULL : "root open, after use");
        open(@"open clipboard history, closed for 5 s", 5, i ? NULL : "clipboard history open, after use");
        Spin(5);
        EmitReference("after 5 s idle");
    }
    EmitMemory("closed, after use");
}

static void BenchTyping(NSUInteger runs) {
    NSArray<NSString *> *words = @[ @"safari", @"chrome", @"term", @"sys", @"clip", @"quick", @"gm", @"vsc", @"note", @"zzq" ];
    Open(nil);
    // Once without timing, so that the samples are of rows whose icons were already made.
    for (NSString *word in words) {
        TypeUnmeasured(word);
        TypeUnmeasured(@"\x1b");
    }
    for (NSUInteger i = 0; i < runs; i += words.count) TypeWords(words, @"root");
    Close();
}

/// Typing calculations into the root search, where every key press also reads the query.
static void BenchCalculatorTyping(NSUInteger runs) {
    NSArray<NSString *> *words = @[ @"12*34", @"10 km to mi", @"2^10+5%", @"1234,5/7" ];
    Open(nil);
    for (NSString *word in words) {
        TypeUnmeasured(word);
        TypeUnmeasured(@"\x1b");
    }
    for (NSUInteger i = 0; i < runs; i += words.count) TypeWords(words, @"root, calculations");
    Close();
}

static void BenchHistoryTyping(NSUInteger runs) {
    NSArray<NSString *> *words = @[ @"the", @"http", @"de", @"zzq" ];
    Open(DKClipboardPage(launcher));
    for (NSUInteger i = 0; i < runs; i += words.count) TypeWords(words, @"clipboard history");
    Close();
}

static void MoveSelection(NSString *scenario, unsigned short keyCode) {
    Measure(scenario, "handled", ^{ Press(keyCode, @"", NSEventModifierFlagFunction); });
}

static void BenchSelection(NSUInteger runs) {
    Open(nil);
    for (NSUInteger i = 0; i < runs; i++) MoveSelection(@"select another row, root", i / 4 % 2 ? kVK_UpArrow : kVK_DownArrow);
    Close();
}

static void BenchHistorySelection(NSUInteger runs) {
    // The history's newest entries are texts, then come the images (see Seed).
    Open(DKClipboardPage(launcher));
    for (NSUInteger i = 0; i < runs; i += kImageClips + 1) {
        for (NSUInteger row = 1; row < kNewestTextClips; row++) MoveSelection(@"select a text entry, clipboard history", kVK_DownArrow);
        for (NSUInteger row = 0; row < kImageClips; row++) MoveSelection(@"select an image entry, clipboard history", kVK_DownArrow);
        @autoreleasepool {
            for (NSUInteger row = 1; row < kNewestTextClips + kImageClips; row++) Press(kVK_UpArrow, @"", NSEventModifierFlagFunction);
        }
        Spin(kSettleSeconds);
    }
    Spin(1);
    EmitMemory("clipboard history open, moving through entries");
    Close();
}

/// What the screens with a detail pane and the actions menu take, drawn again and again.
static void BenchMemory(void) {
    void (^down)(void) = ^{ Press(kVK_DownArrow, @"", NSEventModifierFlagFunction); };
    MeasureMemory("open clipboard history", ^{ [launcher showForInspection:DKClipboardPage(launcher)]; });
    for (NSUInteger row = 1; row < kNewestTextClips; row++) MeasureMemory("select a text entry", down);
    for (NSUInteger row = 0; row < kImageClips; row++) MeasureMemory("select an image entry", down);
    MeasureMemory("open the actions menu", ^{ Press(kVK_ANSI_K, @"k", NSEventModifierFlagCommand); });
    MeasureMemory("close the actions menu", ^{ PressEscape(); });
    MeasureMemory("close", ^{ [launcher hide]; });
    Open(nil);
    TypeUnmeasured(@"search quicklinks");
    MeasureMemory("return on Search Quicklinks", ^{ Press(kVK_Return, @"\r", 0); });
    MeasureMemory("select another quicklink", down);
    MeasureMemory("close", ^{ [launcher hide]; });
}

/// Return on a command, the screen it opens, and Esc back to the root.
static void BenchScreens(NSUInteger runs) {
    Open(nil);
    for (NSUInteger i = 0; i < runs; i++) {
        for (NSString *command in @[ @"Search Quicklinks", @"Create Quicklink", @"Clipboard History" ]) {
            TypeUnmeasured(command.lowercaseString);
            Measure([@"return on " stringByAppendingString:command], "handled", ^{ Press(kVK_Return, @"\r", 0); });
            Measure(@"esc back to the root", "handled", ^{ PressEscape(); });
        }
        Measure(@"open the actions menu", "handled", ^{ Press(kVK_ANSI_K, @"k", NSEventModifierFlagCommand); });
        Measure(@"close the actions menu", "handled", ^{ PressEscape(); });
    }
    Close();
}

/// What Return does before and after the picker's part, which cannot run here: opening
/// would launch applications, and pasting goes through the general pasteboard.
static void BenchParts(NSUInteger runs) {
    NSString *parts = @"parts of opening and pasting";
    NSArray<DKClip *> *clips = [DKClipboardHistory.shared clipsMatching:@"" limit:kNewestTextClips + kImageClips];
    NSPasteboard *board = [NSPasteboard pasteboardWithUniqueName];
    for (NSUInteger i = 0; i < runs; i++) {
        Time(parts, "running applications", ^{ [NSWorkspace.sharedWorkspace.runningApplications valueForKeyPath:@"bundleURL.path"]; });
        Time(parts, "frontmost application", ^{ [NSWorkspace.sharedWorkspace.frontmostApplication processIdentifier]; });
        Time(parts, "record the use", ^{ DKRecordUse(@"bench", @""); });
        Time(parts, "find Safari", ^{ [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:@"com.apple.Safari"]; });
        __block NSData *text, *image;
        Time(parts, "read a text entry", ^{ text = [DKClipboardHistory.shared contentOf:clips.firstObject]; });
        Time(parts, "read an image entry", ^{ image = [DKClipboardHistory.shared contentOf:clips[kNewestTextClips]]; });
        Time(parts, "text to a pasteboard", ^{
            [board clearContents];
            [board setString:[[NSString alloc] initWithData:text encoding:NSUTF8StringEncoding] forType:NSPasteboardTypeString];
        });
        Time(parts, "image to a pasteboard", ^{
            [board clearContents];
            [board setData:image forType:NSPasteboardTypePNG];
        });
        Spin(0.01);
    }
    [board releaseGlobally];
}

static void BenchCPU(void) {
    NSArray<NSString *> *words = @[ @"safari", @"chrome", @"term", @"clip", @"note" ];
    Open(nil);
    Spin(0.5);
    EmitCPU("typing 12 keys a second", ^{
        for (NSString *word in words) {
            for (NSUInteger i = 0; i <= word.length; i++) {
                @autoreleasepool {
                    PressCharacter(i < word.length ? [word characterAtIndex:i] : '\x1b');
                }
                Spin(1 / kKeysPerSecond);
            }
        }
    });
    EmitCPU("open, untouched", ^{ Spin(3); });
    Close();
    Spin(0.5);
    EmitCPU("closed", ^{ Spin(3); });
}

static int RunChild(NSArray<NSString *> *arguments) {
    if (!getenv("DESKKIT_HOME")) return fprintf(stderr, "deskkit: --bench child runs only under --bench\n"), 1;
    NSApplication.sharedApplication.activationPolicy = NSApplicationActivationPolicyAccessory;
    [NSApp finishLaunching];
    // What the main thread of an app in use runs at; a child of a shell would inherit less.
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    id awake = [NSProcessInfo.processInfo beginActivityWithOptions:NSActivityUserInitiated reason:@"bench"];
    CFRunLoopObserverRef observer = CFRunLoopObserverCreate(NULL, kCFRunLoopAfterWaiting | kCFRunLoopBeforeWaiting | kCFRunLoopExit,
                                                            true, INT_MAX, PassEnded, NULL);
    CFRunLoopAddObserver(CFRunLoopGetMain(), observer, kCFRunLoopCommonModes);

    NSString *scenario = arguments.firstObject;
    NSUInteger runs = arguments.count > 1 ? arguments[1].integerValue : kRuns;
    if ([scenario hasPrefix:@"first"]) {
        BenchFirstOpen([scenario isEqualToString:@"first-history"]);
    } else {
        launcher = DKBenchLauncher();
        AwaitHistory();
        // The first open is BenchFirstOpen's to time.
        Open(nil);
        Close();
        BOOL all = [scenario isEqualToString:@"all"];
        if (all || [scenario isEqualToString:@"open"]) BenchOpen(runs);
        if (all || [scenario isEqualToString:@"type"]) BenchTyping(runs);
        if (all || [scenario isEqualToString:@"type-calc"]) BenchCalculatorTyping(runs);
        if (all || [scenario isEqualToString:@"type-history"]) BenchHistoryTyping(runs);
        if (all || [scenario isEqualToString:@"select"]) BenchSelection(runs);
        if (all || [scenario isEqualToString:@"select-history"]) BenchHistorySelection(runs);
        if (all || [scenario isEqualToString:@"memory"]) BenchMemory();
        if (all || [scenario isEqualToString:@"screens"]) BenchScreens(runs);
        if (all || [scenario isEqualToString:@"parts"]) BenchParts(runs);
        if (all) BenchCPU();
    }
    [NSProcessInfo.processInfo endActivity:awake];
    return 0;
}

#pragma mark Seeding

static uint32_t Random(uint32_t *state) { return (*state = *state * 1664525 + 1013904223) >> 8; }

static NSString *Prose(NSUInteger words, NSUInteger wordsPerLine, uint32_t *state) {
    NSArray<NSString *> *vocabulary = [@"the quick tuition weekly school deposit launcher window history panel "
                                       @"default report number height de return static value before after" componentsSeparatedByString:@" "];
    NSMutableString *text = [NSMutableString new];
    for (NSUInteger i = 0; i < words; i++)
        [text appendFormat:@"%@%@", vocabulary[Random(state) % vocabulary.count], (i + 1) % wordsPerLine ? @" " : @"\n"];
    return text;
}

/// Something copied: mostly single lines and links, some paragraphs, now and then a long
/// text. The index keeps every entry different, as the history drops repeats.
static NSString *CopiedText(NSUInteger index, uint32_t *state) {
    switch (index % 10) {
        case 0: case 5: return [NSString stringWithFormat:@"https://example.com/%@/%lu", Prose(1, 2, state), (unsigned long)index];
        case 3: case 7: return [NSString stringWithFormat:@"%lu %@", (unsigned long)index, Prose(40 + Random(state) % 160, 12, state)];
        case 9: return [NSString stringWithFormat:@"%lu %@", (unsigned long)index, Prose(800 + Random(state) % 700, 10, state)];
        default: return [NSString stringWithFormat:@"%@%lu", Prose(3 + Random(state) % 10, 100, state), (unsigned long)index];
    }
}

/// A PNG the size of a screenshot: flat rectangles, as windows are, and a patch of noise
/// that compresses as badly as a photo.
static NSData *Screenshot(NSInteger width, NSInteger height, uint32_t *state) {
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:width pixelsHigh:height
                                                                    bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
                                                                   colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
    for (int i = 0; i < 200; i++) {
        [[NSColor colorWithWhite:(Random(state) % 100) / 100.0 alpha:1] setFill];
        NSRectFill(NSMakeRect(Random(state) % width, Random(state) % height, Random(state) % (width / 2), Random(state) % (height / 2)));
    }
    [NSGraphicsContext restoreGraphicsState];
    for (NSInteger y = 0; y < height / 4; y++) {
        uint32_t *row = (uint32_t *)(bitmap.bitmapData + y * bitmap.bytesPerRow);
        for (NSInteger x = 0; x < width / 4; x++) row[x] = Random(state) | 0xff000000;
    }
    return [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}

static NSURL *BenchHome(void) { return [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"deskkit-bench"]]; }

static void RemoveBenchData(void) {
    [NSFileManager.defaultManager removeItemAtURL:BenchHome() error:nil];
    DKKeychainDelete(kKeychainService, @"clipboard");
}

/// Fills the bench's folder: this Mac's quicklinks and icons, so rows look as they do in
/// use, launcher uses for a full Suggestions section, and a clipboard history of `clips`
/// entries whose newest are texts, then images, then the rest.
static BOOL Seed(NSUInteger clips) {
    RemoveBenchData();
    NSFileManager *files = NSFileManager.defaultManager;
    NSURL *real = [[files URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject
        URLByAppendingPathComponent:@"deskkit"];
    setenv("DESKKIT_HOME", BenchHome().fileSystemRepresentation, 1);
    setenv("DESKKIT_KEYCHAIN_SERVICE", kKeychainService.UTF8String, 1);
    for (NSString *name in @[ @"icons", @"quicklinks.plist" ])
        [files copyItemAtURL:[real URLByAppendingPathComponent:name] toURL:[DKSupportDirectory() URLByAppendingPathComponent:name]
                       error:nil];

    DKStartApplicationIndex();
    NSArray<NSDictionary *> *applications = DKApplications();
    for (NSUInteger i = 0; i < 8 && i * 7 < applications.count; i++)
        for (NSUInteger uses = i; uses < 8; uses++) DKRecordUse(applications[i * 7][@"path"], @"");

    DKClipboardHistory *history = DKClipboardHistory.shared;
    [history load];
    NSDate *patience = [NSDate dateWithTimeIntervalSinceNow:60];
    while (!history.loaded && patience.timeIntervalSinceNow > 0)
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    NSPasteboard *board = [NSPasteboard pasteboardWithUniqueName];
    uint32_t state = 1;
    void (^copy)(NSString *, id) = ^(NSString *type, id content) {
        [board clearContents];
        if ([content isKindOfClass:NSString.class]) [board setString:content forType:type];
        else [board setData:content forType:type];
        [history recordPasteboard:board];
    };
    NSUInteger texts = clips - kImageClips;
    for (NSUInteger i = 0; i < texts - kNewestTextClips; i++) copy(NSPasteboardTypeString, CopiedText(i, &state));
    for (NSNumber *width in @[ @400, @1600, @3472 ])
        copy(NSPasteboardTypePNG, Screenshot(width.integerValue, width.integerValue * 2266 / 3472, &state));
    for (NSUInteger i = texts - kNewestTextClips; i < texts; i++) copy(NSPasteboardTypeString, CopiedText(i, &state));
    [board releaseGlobally];
    // Entries appear once sealed and written.
    while ([history clipsMatching:@"" limit:clips].count < clips && patience.timeIntervalSinceNow > 0)
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    return [history clipsMatching:@"" limit:clips].count == clips;
}

#pragma mark Report

static NSTask *Child(NSArray<NSString *> *arguments) {
    NSTask *child = [NSTask new];
    child.executableURL = NSBundle.mainBundle.executableURL;
    child.arguments = [@[ @"--bench", @"child" ] arrayByAddingObjectsFromArray:arguments];
    return child;
}

/// The samples one child prints.
static NSArray<NSString *> *Samples(NSArray<NSString *> *arguments) {
    NSTask *child = Child(arguments);
    NSPipe *output = [NSPipe pipe];
    child.standardOutput = output;
    if (![child launchAndReturnError:nil]) return @[];
    NSData *printed = [output.fileHandleForReading readDataToEndOfFile];
    [child waitUntilExit];
    return [[[NSString alloc] initWithData:printed encoding:NSUTF8StringEncoding] componentsSeparatedByString:@"\n"];
}

static double Percentile(NSArray<NSNumber *> *sorted, double share) {
    return sorted[(NSUInteger)MAX(0, ceil(share * sorted.count) - 1)].doubleValue;
}

static void Print(NSArray<NSString *> *samples) {
    // Scenarios, and the stages of each, in the order they first appear.
    NSMutableArray<NSString *> *scenarios = [NSMutableArray new];
    NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *stages = [NSMutableDictionary new];
    NSMutableDictionary<NSString *, NSMutableArray<NSNumber *> *> *values = [NSMutableDictionary new];
    for (NSString *sample in samples) {
        NSArray<NSString *> *fields = [sample componentsSeparatedByString:@"\t"];
        if (fields.count != 3) continue;
        NSString *row = [NSString stringWithFormat:@"%@\t%@", fields[0], fields[1]];
        if (!stages[fields[0]]) {
            stages[fields[0]] = [NSMutableArray new];
            [scenarios addObject:fields[0]];
        }
        if (!values[row]) {
            values[row] = [NSMutableArray new];
            [stages[fields[0]] addObject:fields[1]];
        }
        [values[row] addObject:@(fields[2].doubleValue)];
    }
    for (NSString *scenario in scenarios) {
        printf("\n%-42s %5s %9s %9s %9s\n", scenario.UTF8String, "n", "p50", "p95", "max");
        for (NSString *stage in stages[scenario]) {
            NSString *row = [NSString stringWithFormat:@"%@\t%@", scenario, stage];
            NSArray<NSNumber *> *sorted = [values[row] sortedArrayUsingSelector:@selector(compare:)];
            printf("  %-40s %5lu %9.2f %9.2f %9.2f\n", stage.UTF8String, (unsigned long)sorted.count, Percentile(sorted, 0.5),
                   Percentile(sorted, 0.95), sorted.lastObject.doubleValue);
        }
    }
}

/// The whole report, or only `scenario` (see RunChild).
static int Report(NSUInteger clips, NSString *_Nullable scenario) {
    if (!Seed(clips)) return fprintf(stderr, "deskkit: could not write the bench's clipboard history\n"), 1;
    printf("%lu applications, %lu clipboard entries, %ld Hz screen; times in ms from the hotkey or key press\n",
           (unsigned long)DKApplications().count, (unsigned long)clips, (long)NSScreen.mainScreen.maximumFramesPerSecond);
    NSMutableArray<NSString *> *samples = [NSMutableArray new];
    NSUInteger firstOpens = !scenario ? kFirstOpens : [scenario hasPrefix:@"first"] ? kFirstOpens : 0;
    for (NSString *first in scenario ? @[ scenario ] : @[ @"first-root", @"first-history" ])
        for (NSUInteger i = 0; i < firstOpens; i++) [samples addObjectsFromArray:Samples(@[ first ])];
    if (!firstOpens || !scenario) [samples addObjectsFromArray:Samples(@[ scenario ?: @"all" ])];
    RemoveBenchData();
    Print(samples);
    return 0;
}

/// Profiles one scenario, repeated for as long as sample(1) watches it.
static int Sample(NSString *scenario) {
    if (!Seed(kDefaultClips)) return 1;
    NSTask *child = Child(@[ scenario, @"1000000" ]);
    child.standardOutput = NSFileHandle.fileHandleWithNullDevice;
    if (![child launchAndReturnError:nil]) return 1;
    NSString *file = [NSString stringWithFormat:@"/tmp/deskkit-%@.sample.txt", scenario];
    NSTask *sample = [NSTask launchedTaskWithExecutableURL:[NSURL fileURLWithPath:@"/usr/bin/sample"]
                                                 arguments:@[ @(child.processIdentifier).stringValue, @"10", @"1", @"-file", file ]
                                                     error:nil terminationHandler:nil];
    [sample waitUntilExit];
    [child terminate];
    [child waitUntilExit];
    RemoveBenchData();
    return 0;
}

int DKBench(NSArray<NSString *> *arguments) {
    NSString *first = arguments.firstObject;
    if ([first isEqualToString:@"child"]) return RunChild([arguments subarrayWithRange:NSMakeRange(1, arguments.count - 1)]);
    if ([first isEqualToString:@"sample"] && arguments.count > 1) return Sample(arguments[1]);
    if (first.integerValue > 0) return Report(first.integerValue, nil);
    return Report(kDefaultClips, first);
}
