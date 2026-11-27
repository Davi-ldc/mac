// Zero-cache artwork sharing backed by weak map table + ImageIO thumbnail decode + post-CA deferred release.
#import "render/images.h"

#import <ImageIO/ImageIO.h>
#import <objc/runtime.h>
#import <stdatomic.h>

@interface SPAtomicIntBox : NSObject {
  @public
    atomic_int _value;
}
@end

@implementation SPAtomicIntBox
@end

@interface SPPicture : NSObject {
  @public
    CGImageRef _image;
    SPAtomicIntBox *_pixels;
    BOOL _done;
    BOOL _original;
    NSString *_sizeKey;
    NSString *_urlKey;
    NSHashTable<NSView *> *_views;
}
@end

static SPImageFetcher gFetcher = nil;
static BOOL gNetworkEnabled = YES;
static NSUInteger gInFlight = 0;
static NSMapTable<NSString *, SPPicture *> *gPictures = nil;
static NSMutableArray<NSSet<SPPicture *> *> *gDeferredReleases = nil;
static NSMutableDictionary<NSString *, NSNumber *> *gFailedTimestamps = nil;
static NSTimeInterval gRetryBackoff = 5.0;

static void PruneDeadPictureKeys(void) {
    if (!gPictures) return;
    NSArray<NSString *> *keys = gPictures.keyEnumerator.allObjects;
    for (NSString *k in keys) {
        if ([gPictures objectForKey:k] == nil) {
            [gPictures removeObjectForKey:k];
        }
    }
}

@implementation SPPicture
- (void)dealloc {
    if (_image) CGImageRelease(_image);
    if (NSThread.isMainThread && gPictures) {
        if (_sizeKey && [gPictures objectForKey:_sizeKey] == nil) {
            [gPictures removeObjectForKey:_sizeKey];
        }
        if (_urlKey && [gPictures objectForKey:_urlKey] == nil) {
            [gPictures removeObjectForKey:_urlKey];
        }
    }
}
@end

static NSURLSession *ImageURLSession(void) {
    static NSURLSession *session = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        cfg.URLCache = nil;
        cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        cfg.timeoutIntervalForRequest = 15.0;
        cfg.HTTPMaximumConnectionsPerHost = 6;
        session = [NSURLSession sessionWithConfiguration:cfg];
    });
    return session;
}

void SPSetImageFetcher(SPImageFetcher fetcher) {
    gFetcher = [fetcher copy];
}

void SPSetImageNetworkEnabled(BOOL enabled) {
    gNetworkEnabled = enabled;
}

NSUInteger SPImageLoadsInFlight(void) {
    return gInFlight;
}

NSUInteger SPImageLiveCount(void) {
    if (!gPictures) return 0;
    @autoreleasepool {
        NSHashTable *unique = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
        for (NSString *key in gPictures) {
            SPPicture *pic = [gPictures objectForKey:key];
            if (pic) [unique addObject:pic];
        }
        return unique.count;
    }
}

NSUInteger SPImageDeferredReleaseCount(void) {
    return gDeferredReleases.count;
}

NSUInteger SPImageMapKeyCount(void) {
    if (!gPictures) return 0;
    return gPictures.count;
}

void SPImageResetFailedURLs(void) {
    [gFailedTimestamps removeAllObjects];
}

void SPSetImageRetryBackoff(NSTimeInterval seconds) {
    gRetryBackoff = MAX(0.0, seconds);
}

static CGImageRef DecodeThumbnail(NSData *data, CGFloat pixels, BOOL *isOriginal) {
    if (!data.length || pixels <= 0) return NULL;
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!source) return NULL;

    NSDictionary *props = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
    CGFloat w = [props[(__bridge id)kCGImagePropertyPixelWidth] doubleValue];
    CGFloat h = [props[(__bridge id)kCGImagePropertyPixelHeight] doubleValue];
    CGFloat natural = MAX(w, h);
    BOOL original = (natural > 0 && natural <= 2.0 * pixels);
    if (isOriginal) *isOriginal = original;

    CGFloat target = original ? natural : ceil(pixels);
    NSDictionary *opts = @{
        (__bridge id)kCGImageSourceCreateThumbnailFromImageAlways : @YES,
        (__bridge id)kCGImageSourceThumbnailMaxPixelSize : @(MAX(1.0, target)),
        (__bridge id)kCGImageSourceCreateThumbnailWithTransform : @YES,
        (__bridge id)kCGImageSourceShouldCacheImmediately : @YES,
    };
    CGImageRef image = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)opts);
    CFRelease(source);
    return image;
}

static void StartLoad(SPPicture *picture, NSURL *url) {
    gInFlight++;
    __weak SPPicture *weakPicture = picture;
    SPAtomicIntBox *targetBox = picture->_pixels;

    void (^onBytes)(NSData * _Nullable) = ^(NSData *data) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            int pixels = atomic_load(&targetBox->_value);
            BOOL original = NO;
            CGImageRef img = data ? DecodeThumbnail(data, pixels, &original) : NULL;
            if (img && !original) {
                int wanted = atomic_load(&targetBox->_value);
                if (wanted > pixels) {
                    CGImageRelease(img);
                    img = DecodeThumbnail(data, wanted, &original);
                }
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                if (gInFlight > 0) gInFlight--;
                SPPicture *arrived = weakPicture;
                if (!arrived) {
                    if (img) CGImageRelease(img);
                    return;
                }
                arrived->_image = img;
                arrived->_done = YES;
                arrived->_original = (img != NULL && original);
                if (img != NULL) {
                    if (arrived->_urlKey) [gFailedTimestamps removeObjectForKey:arrived->_urlKey];
                    for (NSView *v in arrived->_views) {
                        v.needsDisplay = YES;
                    }
                } else {
                    // Never poison gPictures with a failed SPPicture; record a transient backoff timestamp instead.
                    if (arrived->_sizeKey && [gPictures objectForKey:arrived->_sizeKey] == arrived) {
                        [gPictures removeObjectForKey:arrived->_sizeKey];
                    }
                    if (arrived->_urlKey && [gPictures objectForKey:arrived->_urlKey] == arrived) {
                        [gPictures removeObjectForKey:arrived->_urlKey];
                    }
                    if (arrived->_urlKey && gRetryBackoff > 0.0) {
                        if (!gFailedTimestamps) gFailedTimestamps = [NSMutableDictionary new];
                        if (gFailedTimestamps.count > 256) [gFailedTimestamps removeAllObjects];
                        gFailedTimestamps[arrived->_urlKey] = @(NSDate.date.timeIntervalSince1970);
                    }
                }
                arrived->_views = nil;
            });
        });
    };

    if (gFetcher) {
        gFetcher(url, onBytes);
        return;
    }
    if (url.isFileURL) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            onBytes([NSData dataWithContentsOfURL:url]);
        });
        return;
    }
    if (!gNetworkEnabled) {
        onBytes(nil);
        return;
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    NSURLSessionDataTask *task = [ImageURLSession() dataTaskWithRequest:req
                                                      completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSHTTPURLResponse *http = [resp isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)resp : nil;
        if (err || (http && (http.statusCode < 200 || http.statusCode >= 300))) {
            onBytes(nil);
            return;
        }
        onBytes(data);
    }];
    [task resume];
}

static SPPicture *PictureForURL(NSURL *url, CGFloat pixels) {
    if (!gPictures) gPictures = [NSMapTable strongToWeakObjectsMapTable];
    if (gPictures.count > 128) PruneDeadPictureKeys();
    int wanted = (int)ceil(MAX(1.0, pixels));
    NSString *urlKey = url.absoluteString;
    NSString *key = [NSString stringWithFormat:@"%@#%d", urlKey, wanted];

    // Exact URL+pixel-size hit (ignore dead failed entries).
    SPPicture *picture = [gPictures objectForKey:key];
    if (picture && (!picture->_done || picture->_image != NULL)) return picture;

    // Also share by URL when an existing live entry is loading or already covers the requested pixel size.
    SPPicture *shared = [gPictures objectForKey:urlKey];
    if (shared && !shared->_done) {
        int current = atomic_load(&shared->_pixels->_value);
        while (wanted > current && !atomic_compare_exchange_weak(&shared->_pixels->_value, &current, wanted)) {}
        return shared;
    }
    if (shared && shared->_image != NULL && (atomic_load(&shared->_pixels->_value) >= wanted || shared->_original)) {
        return shared;
    }

    // Respect brief retry backoff after a transient failure so hover redraws don't storm offline.
    NSNumber *failedAt = gFailedTimestamps[urlKey];
    if (failedAt) {
        if ((NSDate.date.timeIntervalSince1970 - failedAt.doubleValue) < gRetryBackoff) {
            return nil;
        }
        [gFailedTimestamps removeObjectForKey:urlKey];
    }

    picture = [SPPicture new];
    picture->_pixels = [SPAtomicIntBox new];
    atomic_init(&picture->_pixels->_value, wanted);
    picture->_sizeKey = key;
    picture->_urlKey = urlKey;
    picture->_views = [NSHashTable weakObjectsHashTable];
    [gPictures setObject:picture forKey:key];
    [gPictures setObject:picture forKey:urlKey];
    StartLoad(picture, url);
    return picture;
}

/// Releases previous image sets on kCFRunLoopBeforeWaiting at order 2500000 (AFTER Core Animation commit at 2000000)
/// so resize/scroll redraws in the same frame re-acquire bitmaps without flashing or re-downloading.
static void ScheduleDeferredRelease(NSSet<SPPicture *> *previous) {
    static CFRunLoopObserverRef observer = NULL;
    if (!observer) {
        gDeferredReleases = [NSMutableArray new];
        observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault,
            kCFRunLoopBeforeWaiting,
            true,
            2500000,
            ^(CFRunLoopObserverRef obs, CFRunLoopActivity activity) {
                (void)obs;
                (void)activity;
                [gDeferredReleases removeAllObjects];
                PruneDeadPictureKeys();
            });
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, kCFRunLoopCommonModes);
    }
    [gDeferredReleases addObject:previous];
}

@interface SPImageHolder ()
- (instancetype)initWithView:(NSView *)view;
@end

@implementation SPImageHolder {
    __weak NSView *_view;
    NSMutableSet<SPPicture *> *_held;
}

- (instancetype)initWithView:(NSView *)view {
    if (!(self = [super init])) return nil;
    _view = view;
    _held = [NSMutableSet new];
    return self;
}

- (CGImageRef)imageWithURL:(NSURL *)url pixels:(CGFloat)pixels {
    if (!url || pixels <= 0) return NULL;
    __block CGImageRef result = NULL;
    @autoreleasepool {
        SPPicture *picture = PictureForURL(url, pixels);
        if (!picture) return NULL;
        [_held addObject:picture];
        NSView *view = _view;
        if (!picture->_done && view) {
            [picture->_views addObject:view];
        }
        result = picture->_image;
    }
    return result;
}

- (void)removeAllImages {
    if (!_held.count) return;
    NSMutableSet<SPPicture *> *previous = _held;
    _held = [NSMutableSet new];
    ScheduleDeferredRelease(previous);
}

- (void)removeFailedImages {
    if (!_held.count) return;
    NSMutableSet<SPPicture *> *keep = [NSMutableSet setWithCapacity:_held.count];
    for (SPPicture *p in _held) {
        if (!p->_done || p->_image != NULL) {
            [keep addObject:p];
        } else if (p->_urlKey) {
            [gFailedTimestamps removeObjectForKey:p->_urlKey];
        }
    }
    _held = keep;
}

@end

void SPReleaseViewImages(NSView *view) {
    if (!view) return;
    SPImageHolder *holder = objc_getAssociatedObject(view, @selector(imageHolder));
    [holder removeAllImages];
    for (NSView *sub in view.subviews) {
        SPReleaseViewImages(sub);
    }
}

@implementation NSView (SPImageHolder)

- (SPImageHolder *)imageHolder {
    SPImageHolder *holder = objc_getAssociatedObject(self, @selector(imageHolder));
    if (!holder) {
        holder = [[SPImageHolder alloc] initWithView:self];
        objc_setAssociatedObject(self, @selector(imageHolder), holder, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return holder;
}

@end
