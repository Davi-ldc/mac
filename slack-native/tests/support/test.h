// The self-test's and the snapshots' registries. A test file anywhere under tests/ declares its
// cases with SN_TEST or SN_SNAPSHOT and needs no list to be edited:
//
//   SN_TEST(DecodesUsers) { SNExpect(user != nil, "user decoded"); }
//
// Tests run headless, in name order, on the main thread, without network, each after the
// process-wide settings a store changes are reset; several processes share the cases (J=1 in
// make: one). SN_SLOW_TEST cases (real media,
// seconds of waiting) run only in `make test-slow` or when named: `make test T="Name Other"` runs
// the cases whose names contain one of the words.
#import <AppKit/AppKit.h>

#import "source/source.h"

NS_ASSUME_NONNULL_BEGIN

typedef void (*SNTestFunction)(void);
typedef NS_ENUM(int, SNCaseKind) { SNCaseTest, SNCaseSlow, SNCaseSnapshot };
void SNRegisterTest(const char *name, SNTestFunction function, SNCaseKind kind);

#define SN_CASE(name, kind)                                                                        \
    static void name(void);                                                                        \
    __attribute__((constructor)) static void name##Register(void) { SNRegisterTest(#name, name, kind); } \
    static void name(void)
#define SN_TEST(name) SN_CASE(name, SNCaseTest)
#define SN_SLOW_TEST(name) SN_CASE(name, SNCaseSlow)
#define SN_SNAPSHOT(name) SN_CASE(name, SNCaseSnapshot)

/// Prints the check and counts it as failed when `condition` is false. The changes made so far are
/// delivered first (SNFlushChanges), so a check sees what the window shows once the turn ends.
#define SNExpect(condition, ...) SNCheck((SNFlushChanges(), (condition)), (__VA_ARGS__), __FILE__, __LINE__)
void SNCheck(BOOL condition, const char *what, const char *file, int line);

/// The repository root given on the command line.
NSURL *SNRepository(void);
/// tests/fixtures: public, made-up data in the API's shape.
NSURL *SNPublicFixture(void);
/// design/fixtures: private data laid out like the reference captures; nil when design/ is absent.
NSURL *_Nullable SNPrivateFixture(void);
/// Runs the main run loop for `seconds` so timers, animations and loads finish.
void SNSettle(NSTimeInterval seconds);

/// A change of one kind naming `value` (nil for kinds without values).
SNChange *SNChangeOf(SNChangeKind kind, NSString *_Nullable value);
/// Calls `block` with each change `source` delivers (SNFlushChanges, or the end of a run-loop turn)
/// until SNStopObserving.
id SNObserveChanges(id<SNSource> source, void (^block)(SNChange *change));
void SNStopObserving(id observer);

/// Entry points for main(): run the registered cases and return 1 when a check failed.
/// `arguments`: names to filter by, --slow for the slow cases, --jobs N for how many processes
/// share the cases (1: this one alone).
int SNRunSelfTest(NSString *repository, NSArray<NSString *> *arguments);
int SNRunSnapshots(NSString *repository, NSString *output, NSArray<NSString *> *arguments);

NS_ASSUME_NONNULL_END
