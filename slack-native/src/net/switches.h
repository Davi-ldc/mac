// The environment switches for running against the real workspace while the app is verified:
// SN_TRACE=1 appends a line per API call and websocket frame to
// ~/Library/Logs/slack-native/trace.log (moved to trace.log.1 at 1 MB), and SN_READONLY=1 keeps the app from changing anything
// in Slack (mutating calls fail locally, typing is not sent). Both are read once, at first use.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Where trace lines go: nil (no tracing) unless SN_TRACE=1. Tests point it at a file of their own.
NSURL *_Nullable SNTraceFile(void);
void SNSetTraceFile(NSURL *_Nullable file);
/// Whether there is a trace file, without a lock: what guards work done only for a trace line.
BOOL SNTracing(void);
/// Appends "<local time>\t<name>\t<HTTP status>\t<ok or error>\t<ms>\t<response bytes>", with "-"
/// for a status of 0 and a negative duration. Callers pass names and outcomes only: never
/// tokens, cookies, request parameters or message content. A macro so that, with tracing off,
/// none of the arguments is computed.
#define SNTrace(...) (SNTracing() ? SNWriteTrace(__VA_ARGS__) : (void)0)
void SNWriteTrace(NSString *name, NSInteger status, NSString *outcome, double milliseconds, NSUInteger bytes);

/// The launch timeline: "launch:<step>" with the milliseconds since the process started (the
/// kernel's start time, so dyld and static initializers count), the first time each step is
/// reached, once "main" was.
#define SNTraceLaunch(step) (SNTracing() ? SNWriteLaunchStep(step) : (void)0)
void SNWriteLaunchStep(NSString *step);

/// SN_READONLY=1 (tests set it).
BOOL SNReadOnly(void);
void SNSetReadOnly(BOOL readOnly);
/// Whether a Web API method may change something in Slack. Reads are named for what they return
/// (list, info, history, get...), so any other method counts as a write: one this does not know
/// is refused in read-only mode rather than sent.
/// Edge API paths ("edge:users/info") are reads.
BOOL SNIsMutatingMethod(NSString *method);

NS_ASSUME_NONNULL_END
