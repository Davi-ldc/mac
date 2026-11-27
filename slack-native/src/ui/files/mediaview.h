// Videos and audio in a message, as the client's VideoMessageFile and AudioPlayer draw them: the
// poster with the play pill and length, playing in place with its controls on hover; an audio
// clip's flat player with its waveform, an uploaded recording's card player. Nothing plays until
// the reader presses play; the player is made then (SNMediaPlayer) and released when the view is
// hidden, leaves its window or is recycled by the list, so files scrolled past cost only their
// poster.
#import "ui/files/fileview.h"
#import "ui/files/player.h"

NS_ASSUME_NONNULL_BEGIN

@interface SNMediaFileView : SNFileView
/// The playing file's player; nil before play and after release.
@property (nonatomic, readonly, nullable) SNMediaPlayer *media;
/// What the play button does: plays (making the player), or pauses what plays.
- (void)togglePlayback;
/// A click at `point` (view coordinates), for tests: the controls under it, else play/pause.
- (void)clickAt:(NSPoint)point;
@end

/// The video's box (getDimensions: by the column's width, orientation and Slack's height caps)
/// or the audio player's card.
NSSize SNMediaViewSize(SNFile *file, SNFileStyle style, CGFloat width);
SNMediaFileView *SNMakeMediaView(SNFile *file, SNFileStyle style, NSString *context);

NS_ASSUME_NONNULL_END
