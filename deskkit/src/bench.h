// `deskkit --bench`: how long the launcher's paths take, measured without hotkeys or focus.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class DKPicker;

/// Runs each path many times behind other windows, with a data folder and a Keychain item of
/// its own, and prints every stage's p50 and p95 in milliseconds, with memory and CPU.
/// `arguments` follow --bench: nothing for the whole report, a number for a clipboard
/// history of that many entries, one scenario ("first-root", "first-history", "open",
/// "type", "type-calc", "type-history", "select", "select-history", "memory", "screens", "parts") for its
/// part alone, or "sample" and a scenario to profile it with sample(1) into /tmp.
int DKBench(NSArray<NSString *> *arguments);
/// The picker calls this as it reaches a stage of a path: "built" (its views exist), "query"
/// (the search text changed), "results" (the rows are computed), "listed" (the list shows
/// them), "picture" (the detail pane has an image entry's picture, which is made off the
/// main thread and can come after the frame). Does nothing unless the bench is timing a run.
void DKBenchMark(const char *stage);
/// The launcher as DKStartLauncher makes it, without its hotkeys.
DKPicker *DKBenchLauncher(void);

NS_ASSUME_NONNULL_END
