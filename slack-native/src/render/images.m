// Owns fetching and decoding pictures once, and their sharing by the views that hold them.
#import <ImageIO/ImageIO.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <stdatomic.h>

#import "render/images.h"

/// A failed picture is not retried on every redraw, but recovers after transient hiccups or on
/// reconnect (SNRetryFailedImages).
static const CFTimeInterval kFailureRetryBackoff = 30;

/// Thread-safe requested pixel size shared between main thread (PictureFor) and background decode.
@interface SNAtomicPixels : NSObject {
  @public
    atomic_int _value;
}
@end

@implementation SNAtomicPixels
@end

/// One picture: fetched and decoded once, at the size its first holder asked for.
@interface SNPicture : NSObject {
  @public
    CGImageRef _image;
    /// Requested pixel size (may grow while in flight if another view asks for a larger size).
    SNAtomicPixels *_pixels;
    /// Decoded (or failed): `_image` is all there will be.
    BOOL _done;
    /// Decoded whole (at most twice the size asked): it serves the view at any size.
    BOOL _original;
    /// Monotonic time when a load failed (0 while loading or succeeded).
    CFTimeInterval _failedAt;
    /// Views to redraw when it arrives.
    NSHashTable<NSView *> *_views;
}
@end

@implementation SNPicture
- (void)dealloc { CGImageRelease(_image); }
@end

static SNImageFetcher fetcher;
static NSUInteger inFlight;
/// URL -> its picture, while a holder has it.
static NSMapTable<NSString *, SNPicture *> *pictures;
/// Live holders, so reconnect can clear failed pictures and trigger redraws.
static NSHashTable<SNImageHolder *> *holders;

void SNSetImageFetcher(SNImageFetcher newFetcher) { fetcher = [newFetcher copy]; }

NSUInteger SNImageLoadsInFlight(void) { return inFlight; }

/// Decoded at `pixels`, or whole when the picture is at most twice that (Slack's sized avatars and
/// emoji): then it serves the view at any scale it moves to, and `original` says so.
static CGImageRef Decode(NSData *data, CGFloat pixels, BOOL *original) {
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!source) return NULL;
    NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
    CGFloat natural = MAX([properties[(__bridge id)kCGImagePropertyPixelWidth] doubleValue], [properties[(__bridge id)kCGImagePropertyPixelHeight] doubleValue]);
    *original = natural > 0 && natural <= 2 * pixels;
    NSDictionary *options = @{
        (__bridge id)kCGImageSourceCreateThumbnailFromImageAlways : @YES,
        (__bridge id)kCGImageSourceThumbnailMaxPixelSize : @(*original ? natural : pixels),
        (__bridge id)kCGImageSourceCreateThumbnailWithTransform : @YES,
        // Decoded now, on the loading queue, instead of on the main thread at first draw.
        (__bridge id)kCGImageSourceShouldCacheImmediately : @YES,
    };
    CGImageRef image = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
    CFRelease(source);
    return image;
}

static void Load(SNPicture *picture, NSURL *url) {
    inFlight++;
    // A picture every holder let go of before it arrived is not kept; never promote weakPicture
    // off the main thread so SNPicture and its NSView hash table always deallocate on main.
    __weak SNPicture *weakPicture = picture;
    SNAtomicPixels *targetPixels = picture->_pixels;
    void (^finish)(NSData *) = ^(NSData *data) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            int pixels = atomic_load(&targetPixels->_value);
            BOOL original = NO;
            CGImageRef image = data ? Decode(data, pixels, &original) : NULL;
            // If another view requested a larger size while decoding, re-decode from the same bytes.
            if (image && !original) {
                int wanted = atomic_load(&targetPixels->_value);
                if (wanted > pixels) {
                    CGImageRelease(image);
                    image = Decode(data, wanted, &original);
                }
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                inFlight--;
                SNPicture *arrived = weakPicture;
                if (!arrived) {
                    CGImageRelease(image);
                    return;
                }
                arrived->_image = image;
                arrived->_done = YES;
                arrived->_original = image && original;
                arrived->_failedAt = image ? 0 : CACurrentMediaTime();
                for (NSView *view in arrived->_views) view.needsDisplay = YES;
                arrived->_views = nil;
            });
        });
    };
    if (fetcher) {
        fetcher(url, finish);
        return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ finish(url.isFileURL ? [NSData dataWithContentsOfURL:url] : nil); });
}

static SNPicture *PictureFor(NSURL *url, CGFloat pixels) {
    if (!pictures) pictures = [NSMapTable strongToWeakObjectsMapTable];
    NSString *key = url.absoluteString;
    int wanted = (int)ceil(pixels);
    SNPicture *picture = [pictures objectForKey:key];
    // Deduplicate inflight requests: if still loading, grow its target size instead of downloading twice.
    if (picture && !picture->_done) {
        int current = atomic_load(&picture->_pixels->_value);
        while (wanted > current && !atomic_compare_exchange_weak(&picture->_pixels->_value, &current, wanted)) {}
        return picture;
    }
    // Drawn larger than it was decoded for, it is decoded again for that size; the holders of the
    // smaller one keep theirs. Failed pictures stay cached only during the retry backoff window.
    if (picture) {
        if (picture->_image && (atomic_load(&picture->_pixels->_value) >= wanted || picture->_original)) return picture;
        if (!picture->_image && CACurrentMediaTime() - picture->_failedAt < kFailureRetryBackoff) return picture;
    }
    picture = [SNPicture new];
    picture->_pixels = [SNAtomicPixels new];
    atomic_init(&picture->_pixels->_value, wanted);
    picture->_views = [NSHashTable weakObjectsHashTable];
    [pictures setObject:picture forKey:key];
    Load(picture, url);
    return picture;
}

/// Previous holders' image sets kept alive until after Core Animation's draw/commit pass (order
/// 2000000), so a redraw in the same frame re-acquires them without re-downloading or re-decoding.
static NSMutableArray<NSSet<SNPicture *> *> *deferredReleases;

static void DeferRelease(NSSet<SNPicture *> *previous) {
    static CFRunLoopObserverRef observer;
    if (!observer) {
        deferredReleases = [NSMutableArray new];
        observer = CFRunLoopObserverCreateWithHandler(NULL, kCFRunLoopBeforeWaiting, true, 2500000,
                                                      ^(CFRunLoopObserverRef obs, CFRunLoopActivity activity) { [deferredReleases removeAllObjects]; });
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, kCFRunLoopCommonModes);
    }
    [deferredReleases addObject:previous];
}

@interface SNImageHolder ()
- (instancetype)initWithView:(NSView *)view;
@end

@implementation SNImageHolder {
    __weak NSView *_view;
    NSMutableSet<SNPicture *> *_held;
}

- (instancetype)initWithView:(NSView *)view {
    if (!(self = [super init])) return nil;
    _view = view;
    _held = [NSMutableSet new];
    if (!holders) holders = [NSHashTable weakObjectsHashTable];
    [holders addObject:self];
    return self;
}

- (BOOL)hasFailedImages {
    for (SNPicture *picture in _held)
        if (picture->_done && !picture->_image) return YES;
    return NO;
}

- (NSView *)view { return _view; }

- (CGImageRef)imageWithURL:(NSURL *)url pixels:(CGFloat)pixels {
    if (pixels <= 0) return NULL;
    SNPicture *picture = PictureFor(url, pixels);
    [_held addObject:picture];
    NSView *view = _view;
    if (!picture->_done && view) [picture->_views addObject:view];
    return picture->_image;
}

- (void)removeAllImages {
    if (!_held.count) return;
    NSMutableSet<SNPicture *> *previous = _held;
    _held = [NSMutableSet new];
    DeferRelease(previous);
}

- (void)removeFailedImages {
    [_held filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(SNPicture *picture, NSDictionary *bindings) { return !picture->_done || picture->_image; }]];
}

@end

void SNReleaseViewImages(NSView *view) {
    SNImageHolder *holder = objc_getAssociatedObject(view, @selector(imageHolder));
    [holder removeAllImages];
    for (NSView *subview in view.subviews) SNReleaseViewImages(subview);
}

void SNRetryFailedImages(void) {
    for (NSString *key in pictures.keyEnumerator.allObjects) {
        SNPicture *picture = [pictures objectForKey:key];
        if (picture && picture->_done && !picture->_image) [pictures removeObjectForKey:key];
    }
    for (SNImageHolder *holder in holders.allObjects) {
        if (![holder hasFailedImages]) continue;
        [holder removeFailedImages];
        NSView *view = [holder view];
        if (view) {
            view.needsDisplay = YES;
            if (view.superview.canDrawSubviewsIntoLayer) view.superview.needsDisplay = YES;
        }
    }
}

@implementation NSView (SNImageHolder)

- (SNImageHolder *)imageHolder {
    SNImageHolder *holder = objc_getAssociatedObject(self, @selector(imageHolder));
    if (!holder) {
        holder = [[SNImageHolder alloc] initWithView:self];
        objc_setAssociatedObject(self, @selector(imageHolder), holder, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return holder;
}

@end
