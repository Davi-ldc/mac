// Owns reaching Slack's file URLs from the file views.
#import <dlfcn.h>

#import "net/switches.h"
#import "ui/files/filenet.h"

void *SNLoadAVFoundation(void) {
    static void *handle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ handle = dlopen("/System/Library/Frameworks/AVFoundation.framework/AVFoundation", RTLD_LAZY | RTLD_LOCAL); });
    return handle;
}

static NSArray<NSHTTPCookie *> * (^credentialCookies)(void);
static NSString *credentialAgent;

void SNSetFileCredentials(NSArray<NSHTTPCookie *> * (^cookies)(void), NSString *userAgent) {
    credentialCookies = [cookies copy];
    credentialAgent = [userAgent copy];
}

static NSArray<NSHTTPCookie *> *Cookies(void) { return credentialCookies ? credentialCookies() : nil; }

AVURLAsset *SNFileAsset(NSURL *url) {
    NSArray<NSHTTPCookie *> *cookies = Cookies();
    if (!cookies) return nil;
    void *av = SNLoadAVFoundation();
    Class assetClass = av ? NSClassFromString(@"AVURLAsset") : Nil;
    if (!assetClass) return nil;
    CFStringRef const *cookiesKey = (CFStringRef const *)dlsym(av, "AVURLAssetHTTPCookiesKey");
    CFStringRef const *agentKey = (CFStringRef const *)dlsym(av, "AVURLAssetHTTPUserAgentKey");
    // AVFoundation sends each cookie only to the hosts it applies to, redirects included.
    NSMutableDictionary *options = [NSMutableDictionary new];
    if (cookiesKey && *cookiesKey) options[(__bridge NSString *)*cookiesKey] = cookies;
    if (credentialAgent && agentKey && *agentKey) options[(__bridge NSString *)*agentKey] = credentialAgent;
    return [assetClass URLAssetWithURL:url options:options];
}

/// `name` in `folder`, numbered like Finder ("report (1).pdf") when taken.
static NSURL *FreeName(NSURL *folder, NSString *name) {
    NSString *base = name.stringByDeletingPathExtension, *extension = name.pathExtension;
    NSURL *url = [folder URLByAppendingPathComponent:name];
    for (NSInteger n = 1; [NSFileManager.defaultManager fileExistsAtPath:url.path]; n++) {
        NSString *numbered = [NSString stringWithFormat:@"%@ (%ld)", base, (long)n];
        url = [folder URLByAppendingPathComponent:extension.length ? [numbered stringByAppendingPathExtension:extension] : numbered];
    }
    return url;
}

/// A session of its own per transfer: its jar holds copies of the session's cookies, so they go
/// only where they apply (redirects included), and a download (which may be large) streams to
/// disk instead of into memory as the image fetcher's reads do. nil without credentials.
static NSURLSession *FileSession(void) {
    NSArray<NSHTTPCookie *> *cookies = Cookies();
    if (!cookies) return nil;
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    for (NSHTTPCookie *cookie in cookies) [configuration.HTTPCookieStorage setCookie:cookie];
    if (credentialAgent) configuration.HTTPAdditionalHeaders = @{@"User-Agent" : credentialAgent};
    return [NSURLSession sessionWithConfiguration:configuration];
}

void SNFetchFileText(SNFile *file, void (^completion)(NSString *)) {
    NSURLSession *session = file.privateURL ? FileSession() : nil;
    if (!session) {
        completion(nil);
        return;
    }
    NSURL *url = file.privateURL;
    NSDate *start = NSDate.date;
    [[session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
        NSData *body = http.statusCode == 200 ? data : nil;
        NSString *text = body ? [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding] ?: [[NSString alloc] initWithData:body encoding:NSISOLatin1StringEncoding] : nil;
        SNTrace([@"file:" stringByAppendingString:url.host ?: @"-"], http.statusCode, text ? @"ok" : error ? [NSString stringWithFormat:@"error %ld", (long)error.code] : @"failed",
                -start.timeIntervalSinceNow * 1000, data.length);
        dispatch_async(dispatch_get_main_queue(), ^{ completion(text); });
    }] resume];
    [session finishTasksAndInvalidate];
}

void SNDownloadFile(SNFile *file, void (^completion)(NSURL *)) {
    NSURL *url = file.downloadURL ?: file.privateURL;
    NSURLSession *session = url ? FileSession() : nil;
    if (!session) {
        if (completion) completion(nil);
        return;
    }
    NSString *name = [(file.name.length ? file.name : file.fileID) stringByReplacingOccurrencesOfString:@"/" withString:@"-"];
    NSDate *start = NSDate.date;
    [[session downloadTaskWithURL:url completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
        NSURL *folder = [NSFileManager.defaultManager URLForDirectory:NSDownloadsDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:NULL];
        NSURL *saved = location && folder && http.statusCode == 200 ? FreeName(folder, name) : nil;
        if (saved && ![NSFileManager.defaultManager moveItemAtURL:location toURL:saved error:NULL]) saved = nil;
        // The host only: the path names the file.
        SNTrace([@"download:" stringByAppendingString:url.host ?: @"-"], http.statusCode, saved ? @"ok" : error ? [NSString stringWithFormat:@"error %ld", (long)error.code] : @"failed",
                -start.timeIntervalSinceNow * 1000, (NSUInteger)MAX(0, response.expectedContentLength));
        dispatch_async(dispatch_get_main_queue(), ^{
            if (saved) [NSDistributedNotificationCenter.defaultCenter postNotificationName:@"com.apple.DownloadFileFinished" object:saved.path];
            if (completion) completion(saved);
        });
    }] resume];
    [session finishTasksAndInvalidate];
}
