// Zero-cache artwork sharing: fetch once per URL+pixel size (URLCache = nil), ImageIO background
// thumbnail decode at exact display pixel size, weak map table while any view holds the bitmap,
// and deferred release after Core Animation commit (kCFRunLoopBeforeWaiting, order 2500000).
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Pluggable image byte fetcher (used by tests/fixtures; nil uses URLCache-free NSURLSession / file reads).
typedef void (^SPImageFetcher)(NSURL *url, void (^completion)(NSData *_Nullable data));

/// Installs a custom image fetcher, or pass nil to restore the default zero-cache HTTP/file loader.
void SPSetImageFetcher(SPImageFetcher _Nullable fetcher);

/// Enables or disables live HTTP fetching (disabled in headless tests so artwork URLs never hit the network).
void SPSetImageNetworkEnabled(BOOL enabled);

/// Per-view artwork holder (`view.imageHolder`); marks the owning view `needsDisplay = YES` when images arrive.
@interface SPImageHolder : NSObject
/// Returns the shared decoded CGImageRef for `url` at `pixels`, or NULL while loading / on failure.
/// Keeps the bitmap alive as long as this holder retains it.
- (nullable CGImageRef)imageWithURL:(NSURL *)url pixels:(CGFloat)pixels;

/// Releases all held images on a deferred post-CA run-loop observer (order 2500000) so same-frame
/// redraws/resizes re-acquire without flashing or re-downloading.
- (void)removeAllImages;

/// Drops only failed entries so subsequent requests retry.
- (void)removeFailedImages;
@end

@interface NSView (SPImageHolder)
@property (nonatomic, readonly) SPImageHolder *imageHolder;
@end

/// Recursively releases held images on `view` and all of its subviews without creating new holders.
void SPReleaseViewImages(NSView *view);

/// Number of image loads/decodes currently in flight.
NSUInteger SPImageLoadsInFlight(void);

/// Number of currently live shared bitmaps in the weak map table (diagnostic/test helper).
NSUInteger SPImageLiveCount(void);

/// Number of deferred release batches currently queued for post-CA cleanup (diagnostic/test helper).
NSUInteger SPImageDeferredReleaseCount(void);

/// Number of strong keys currently present in the shared image map table (diagnostic/test helper).
NSUInteger SPImageMapKeyCount(void);

/// Clears transient failure backoff timestamps (e.g. on network reconnect) so failed URLs retry immediately.
void SPImageResetFailedURLs(void);

/// Configures failure retry backoff duration in seconds (default 5.0; configurable for tests).
void SPSetImageRetryBackoff(NSTimeInterval seconds);

NS_ASSUME_NONNULL_END
