// 30 fps Core Animation playing-track equalizer waveform that automatically pauses when paused or occluded.
#import <AppKit/AppKit.h>

#import "theme/theme.h"

NS_ASSUME_NONNULL_BEGIN

@interface SPWaveformView : NSView
@property (nonatomic) BOOL playing;
@property (nonatomic) SPColorToken barColor;
@property (nonatomic, readonly) BOOL isAnimating;
/// Explicit override used by occlusion notifications and headless tests.
@property (nonatomic) BOOL occluded;
@end

NS_ASSUME_NONNULL_END
