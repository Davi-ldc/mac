// Owns site icons: finding each site's own icon, fetching it, and keeping it in memory and
// on disk (one PNG per host in the icons folder, fetched once per site).
#import "icons.h"
#import "support.h"
#import "theme.h"
#import "webicons.h"

NSNotificationName const DKWebIconDidLoadNotification = @"DKWebIconDidLoadNotification";

// Neither an icon nor a page worth reading for its icon links is larger.
static const NSUInteger kMaxBytes = 1 << 20;
// A site whose icon could not be fetched is asked again after this long.
static const NSTimeInterval kRetrySeconds = 300;
// An icon this many pixels across fills a row on a Retina screen, so the search stops there.
static const CGFloat kEnoughPixels = 2 * DKIconSize;
// Raycast rounds the corners of site icons, which shows on opaque square ones.
static const CGFloat kCornerRadius = 6;

static NSCache<NSString *, NSImage *> *cache;
static NSMutableSet<NSString *> *fetching;
static NSMutableDictionary<NSString *, NSDate *> *failedAt;

static NSURL *IconFile(NSString *host) {
    return [DKSupportSubdirectory(@"icons") URLByAppendingPathComponent:[host stringByAppendingPathExtension:@"png"]];
}

static void Finish(NSString *host, NSImage *_Nullable image) {
    [fetching removeObject:host];
    if (!image) {
        failedAt[host] = NSDate.date;
        return;
    }
    NSBitmapImageRep *bitmap = DKIconBitmap(image, kCornerRadius);
    [[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToURL:IconFile(host) atomically:YES];
    NSImage *icon = [[NSImage alloc] initWithSize:bitmap.size];
    [icon addRepresentation:bitmap];
    [cache setObject:icon forKey:host];
    [NSNotificationCenter.defaultCenter postNotificationName:DKWebIconDidLoadNotification object:nil];
}

/// Pixels across the image's largest representation; a vector image has any size.
static CGFloat Pixels(NSImage *image) {
    CGFloat pixels = 0;
    for (NSImageRep *rep in image.representations)
        pixels = MAX(pixels, [rep isKindOfClass:NSBitmapImageRep.class] ? MIN(rep.pixelsWide, rep.pixelsHigh) : CGFLOAT_MAX);
    return pixels;
}

static BOOL SameSite(NSString *a, NSString *b) {
    NSString * (^bare)(NSString *) = ^(NSString *host) {
        host = host.lowercaseString;
        return [host hasPrefix:@"www."] ? [host substringFromIndex:4] : host;
    };
    return a && b && [bare(a) isEqualToString:bare(b)];
}

/// The icons a page declares with <link rel="apple-touch-icon">, "icon" and the like. Touch
/// icons come first, since they are drawn to be shown as a tile, as a launcher row shows
/// them (and as Raycast picks them); then the rest, largest first by declared size.
static NSArray<NSURL *> *DeclaredIcons(NSString *html, NSURL *page) {
    NSRegularExpression *links = [NSRegularExpression regularExpressionWithPattern:@"<link\\b[^>]*>"
                                                                           options:NSRegularExpressionCaseInsensitive error:nil];
    NSRegularExpression *attributes =
        [NSRegularExpression regularExpressionWithPattern:@"([a-z-]+)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
                                                  options:NSRegularExpressionCaseInsensitive error:nil];
    NSMutableArray<NSArray *> *found = [NSMutableArray new];
    for (NSTextCheckingResult *link in [links matchesInString:html options:0 range:NSMakeRange(0, html.length)]) {
        NSString *tag = [html substringWithRange:link.range];
        NSMutableDictionary<NSString *, NSString *> *values = [NSMutableDictionary new];
        for (NSTextCheckingResult *attribute in [attributes matchesInString:tag options:0 range:NSMakeRange(0, tag.length)])
            for (NSUInteger group = 2; group <= 4; group++)
                if ([attribute rangeAtIndex:group].location != NSNotFound)
                    values[[tag substringWithRange:[attribute rangeAtIndex:1]].lowercaseString] =
                        [tag substringWithRange:[attribute rangeAtIndex:group]];
        NSArray<NSString *> *rel = [values[@"rel"].lowercaseString componentsSeparatedByString:@" "];
        BOOL touch = [rel containsObject:@"apple-touch-icon"] || [rel containsObject:@"apple-touch-icon-precomposed"];
        if (!touch && ![rel containsObject:@"icon"]) continue;
        NSString *href = [values[@"href"] stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
        NSURL *url = href.length ? [NSURL URLWithString:href relativeToURL:page].absoluteURL : nil;
        if (![url.scheme hasPrefix:@"http"]) continue;
        double size = 0;
        for (NSString *declared in [values[@"sizes"] componentsSeparatedByString:@" "]) size = MAX(size, declared.doubleValue);
        if ([values[@"sizes"] isEqualToString:@"any"] || [values[@"type"] containsString:@"svg"] ||
            [url.pathExtension isEqualToString:@"svg"])
            size = DBL_MAX;
        [found addObject:@[ @(touch), @(size), url ]];
    }
    [found sortWithOptions:NSSortStable usingComparator:^NSComparisonResult(NSArray *a, NSArray *b) {
        NSComparisonResult touch = [b[0] compare:a[0]];
        return touch != NSOrderedSame ? touch : [b[1] compare:a[1]];
    }];
    NSMutableArray<NSURL *> *urls = [NSMutableArray new];
    for (NSArray *entry in found) [urls addObject:entry[2]];
    return urls;
}

/// Finds one site's icon. It tries in turn the icons the home page declares (only while the
/// page stays on the site: Gmail's sends a signed-out visitor to Google's sign-in page,
/// whose icon is Google's), Apple's and the browsers' conventional paths, then Raycast's
/// and Google's favicon services; the first image kEnoughPixels across wins, or else the
/// largest found. Each lookup has its own session, since a shared one reuses connections
/// that died while the launcher sat idle, and a request on one hangs until the timeout.
@interface DKWebIconLookup : NSObject <NSURLSessionDataDelegate>
@end

@implementation DKWebIconLookup {
    NSString *_host;
    NSURLSession *_session;
    /// Nil while the home page is being read.
    NSMutableArray<NSURL *> *_candidates;
    NSMutableData *_body;
    NSImage *_best;
    CGFloat _bestPixels;
}

+ (void)lookUp:(NSString *)host {
    DKWebIconLookup *lookup = [DKWebIconLookup new];
    lookup->_host = host;
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.timeoutIntervalForResource = 15;
    // The session holds its delegate, and so the lookup, until -next invalidates it.
    lookup->_session = [NSURLSession sessionWithConfiguration:configuration delegate:lookup
                                                delegateQueue:NSOperationQueue.mainQueue];
    // Raycast draws GitHub as a light mark rather than its dark favicon. GitHub serves that
    // mark for dark mode but picks it with a script, so it is named here.
    if (SameSite(host, @"github.com"))
        [lookup search:@[ [NSURL URLWithString:@"https://github.githubassets.com/favicons/favicon-dark.svg"] ]];
    else
        [lookup fetch:[NSURL URLWithString:[@"https://" stringByAppendingString:host]]];
}

- (void)fetch:(NSURL *)url {
    _body = nil;
    [[_session dataTaskWithURL:url] resume];
}

- (void)search:(NSArray<NSURL *> *)first {
    NSURL *site = [NSURL URLWithString:[@"https://" stringByAppendingString:_host]];
    NSURLComponents *raycast = [NSURLComponents componentsWithString:@"https://api.ray.so/favicon"];
    raycast.queryItems = @[ [NSURLQueryItem queryItemWithName:@"url" value:_host], [NSURLQueryItem queryItemWithName:@"size" value:@"64"] ];
    NSURLComponents *google = [NSURLComponents componentsWithString:@"https://www.google.com/s2/favicons"];
    google.queryItems = @[ [NSURLQueryItem queryItemWithName:@"domain" value:_host], [NSURLQueryItem queryItemWithName:@"sz" value:@"64"] ];
    _candidates = [first mutableCopy];
    [_candidates addObjectsFromArray:@[ [site URLByAppendingPathComponent:@"apple-touch-icon.png"],
                                        [site URLByAppendingPathComponent:@"favicon.ico"], raycast.URL, google.URL ]];
    [self next];
}

- (void)next {
    if (_bestPixels >= kEnoughPixels || !_candidates.count) {
        [_session finishTasksAndInvalidate];
        return Finish(_host, _best);
    }
    NSURL *url = _candidates.firstObject;
    [_candidates removeObjectAtIndex:0];
    [self fetch:url];
}

// A home page moving to another site is not followed (see DKWebIconLookup); its redirect
// then ends the request, and is refused below like any response that is not a 200.
- (void)URLSession:(NSURLSession *)session
                          task:(NSURLSessionTask *)task
    willPerformHTTPRedirection:(NSHTTPURLResponse *)response
                    newRequest:(NSURLRequest *)request
             completionHandler:(void (^)(NSURLRequest *))completion {
    completion(_candidates || SameSite(request.URL.host, _host) ? request : nil);
}

- (void)URLSession:(NSURLSession *)session
              dataTask:(NSURLSessionDataTask *)task
    didReceiveResponse:(NSURLResponse *)response
     completionHandler:(void (^)(NSURLSessionResponseDisposition))completion {
    BOOL accepted = [response isKindOfClass:NSHTTPURLResponse.class] && ((NSHTTPURLResponse *)response).statusCode == 200 &&
                    response.expectedContentLength <= (long long)kMaxBytes;
    if (accepted) _body = [NSMutableData new];
    completion(accepted ? NSURLSessionResponseAllow : NSURLSessionResponseCancel);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    [_body appendData:data];
    if (_body.length > kMaxBytes) [task cancel];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    NSData *body = error ? nil : _body;
    if (!_candidates) {
        NSString *html = body ? [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding] : nil;
        return [self search:html ? DeclaredIcons(html, task.response.URL) : @[]];
    }
    NSImage *image = body ? [[NSImage alloc] initWithData:body] : nil;
    // Pages served in place of a missing icon are not images.
    if (image.isValid && Pixels(image) > _bestPixels) {
        _best = image;
        _bestPixels = Pixels(image);
    }
    [self next];
}

@end

NSImage *DKWebIcon(NSString *host) {
    if (!cache) {
        cache = [NSCache new];
        fetching = [NSMutableSet new];
        failedAt = [NSMutableDictionary new];
    }
    NSImage *icon = [cache objectForKey:host];
    if (icon) return icon;
    NSDate *failed = failedAt[host];
    if (![fetching containsObject:host] && !(failed && -failed.timeIntervalSinceNow < kRetrySeconds)) {
        icon = [[NSImage alloc] initWithContentsOfURL:IconFile(host)];
        if (icon) {
            [cache setObject:icon forKey:host];
            return icon;
        }
        [fetching addObject:host];
        [DKWebIconLookup lookUp:host];
    }
    NSString *safari = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:@"com.apple.Safari"].path;
    return DKFileIcon(safari ?: @"/Applications/Safari.app");
}
