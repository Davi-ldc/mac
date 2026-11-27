// Avatars, icons, emoji and thumbnails. A picture is fetched once and decoded once at the size
// it is drawn (the caller picks Slack's sized URL for that size: SNUser avatarURLForPixels:), and
// every view drawing it shares that one bitmap. Views hold the pictures they show through an
// SNImageHolder; a picture lives while some holder has it and goes with the last one, so memory
// follows what is on screen with no budget or eviction.
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Gets the bytes behind an image URL and calls `completion` with them (or nil) on any thread.
typedef void (^SNImageFetcher)(NSURL *url, void (^completion)(NSData *_Nullable data));
/// nil, the default, reads file URLs only. The network layer installs one that sends the
/// session's credentials (Slack's file URLs need them); fixture runs install a local one.
void SNSetImageFetcher(SNImageFetcher _Nullable fetcher);

/// The pictures one view shows (NSView imageHolder); the view is redrawn when one it asked for
/// arrives.
@interface SNImageHolder : NSObject
/// The picture at `url` with its longer side at least `pixels` long (or the original, if
/// smaller), held from now on: NULL while it loads (the view is redrawn when it arrives) or when
/// it could not be loaded, which is not asked again while held.
- (nullable CGImageRef)imageWithURL:(NSURL *)url pixels:(CGFloat)pixels;
/// Lets go of every picture (the view shows something else now).
- (void)removeAllImages;
/// Lets go of the pictures that could not be loaded, so asking again tries again.
- (void)removeFailedImages;
@end

@interface NSView (SNImageHolder)
/// The pictures the view draws, made at first use; they go with the view.
@property (nonatomic, readonly) SNImageHolder *imageHolder;
@end

/// Releases every picture held by `view` and any of its subviews (without creating new holders).
void SNReleaseViewImages(NSView *view);
/// Drops every failed picture across live holders and marks their views for redraw (on reconnect).
void SNRetryFailedImages(void);

/// Loads still running; the snapshot harness waits for none.
NSUInteger SNImageLoadsInFlight(void);

NS_ASSUME_NONNULL_END
