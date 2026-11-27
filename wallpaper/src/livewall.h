#import <AVFoundation/AVFoundation.h>
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Prints "livewall: <message>" and exits with `code`.
void LWFail(int code, NSString *format, ...) NS_FORMAT_FUNCTION(2, 3) __attribute__((noreturn));

/// A reason to keep the video frozen. Playback runs only while no hold is active.
typedef NS_OPTIONS(uint8_t, LWHold) {
    /// The first batch of samples is not queued yet.
    LWHoldPreroll = 1 << 0,
    /// Paused from outside, by signal.
    LWHoldRequested = 1 << 1,
    /// No part of the window is on screen.
    LWHoldHidden = 1 << 2,
    /// Nobody has touched the Mac for a while.
    LWHoldAway = 1 << 3,
};

/// The playback clock. Only the main thread changes it; feed queues read its time.
@interface LWClock : NSObject
@property(readonly) CMTimebaseRef timebase;
- (void)setHold:(LWHold)hold active:(BOOL)active;
@end

/// Reads the compressed samples of one video track, over and over, without decoding them.
@interface LWFeed : NSObject
- (instancetype)initWithPath:(NSString *)path;
/// Enqueues samples until the renderer has enough buffered. Returns an error message
/// when playback cannot go on.
- (nullable NSString *)pumpInto:(AVSampleBufferVideoRenderer *)renderer
                       timebase:(CMTimebaseRef)timebase;
@end

/// Plays a video file in an endless loop on an `AVSampleBufferDisplayLayer`.
///
/// Samples reach the layer still compressed, so decoding and presentation stay inside the
/// system's video pipeline: no render pass or per-frame wakeup of our own. The layer pulls
/// samples ahead of time and shows each one when the clock reaches its timestamp.
@interface LWPlayer : NSObject
@property(readonly) AVSampleBufferDisplayLayer *layer;
@property(readonly) AVSampleBufferVideoRenderer *renderer;
/// Queues the first samples; they start showing once the clock has no hold left.
- (instancetype)initWithPath:(NSString *)path clock:(LWClock *)clock;
@end

/// Where the video window goes. The default is the wallpaper position; the overrides
/// exist for power experiments that isolate area, glass and occlusion effects.
typedef struct {
    /// Screen rectangle in AppKit coordinates (origin at the bottom left); empty for the
    /// whole primary screen.
    NSRect frame;
    /// Float above app windows instead of sitting at desktop level.
    BOOL aboveWindows;
} LWPlacement;

/// `LIVEWALL_FRAME=x,y,w,h` and `LIVEWALL_ABOVE=1`; without them, the wallpaper position.
LWPlacement LWPlacementFromEnvironment(void);

/// Opens a borderless, click-through window, by default covering the primary screen at
/// desktop level: above the system wallpaper, below desktop icons and every app window.
///
/// `onVisibility` is told whether any part of the window is on screen, as the window
/// server sees it: false behind the lock screen, a full-screen app or a sleeping display.
NSWindow *LWOpenDesktopWindow(CALayer *layer, LWPlacement placement,
                              void (^onVisibility)(BOOL visible));

/// A signal source only observes a signal; its default action (terminate) has to be
/// switched off separately, and before startup does anything slow.
void LWIgnoreControlSignals(void);
/// `SIGUSR1` pauses and `SIGUSR2` resumes, which is how the power bench alternates
/// between playing and frozen without killing the process.
void LWHandleControlSignals(LWClock *clock);

/// Freezes the wallpaper while nobody is at the Mac.
void LWHoldWhileAway(LWClock *clock);

/// Reports to stderr what the renderer actually put on screen: frame rate, dropped
/// frames and how many frames went straight to the display instead of a GPU composite.
void LWReportStats(AVSampleBufferVideoRenderer *renderer);

NS_ASSUME_NONNULL_END
