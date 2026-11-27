// Phase 0 FairPlay Streaming probe for spotify-native.
//
// Modes:
//   --offline                  Offline self-check (local AVContentKeySession UTF-8 & UTF-16LE SPC + HLS v6 manifest + RAM)
//   --live --oauth-login       1-command live check: PKCE browser login (no Keychain writes) -> Client-Token -> CKC + 5s AVPlayer playback
//   --live --token T --client-token CT [--track-id ID] [--utf16le | --utf8 | --both] [--cert PATH]

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <mach/mach.h>

#import "audio/fairplay.h"
#import "auth/auth.h"
#import "model/json.h"

static NSString *HexPrefix(NSData *data, NSUInteger maxBytes) {
    const uint8_t *b = (const uint8_t *)data.bytes;
    NSUInteger n = MIN(data.length, maxBytes);
    NSMutableString *s = [NSMutableString stringWithCapacity:n * 2];
    for (NSUInteger i = 0; i < n; i++) [s appendFormat:@"%02x", b[i]];
    return s;
}

static double ResidentMemoryMB(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) == KERN_SUCCESS) {
        return (double)info.phys_footprint / (1024.0 * 1024.0);
    }
    return 0.0;
}

static NSData *SyncHTTP(NSURLRequest *req, NSHTTPURLResponse **outHTTP, NSError **outErr) {
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSData *body = nil;
    __block NSURLResponse *resp = nil;
    __block NSError *err = nil;
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.URLCache = nil;
    NSURLSession *sess = [NSURLSession sessionWithConfiguration:cfg];
    [[sess dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        body = d; resp = r; err = e;
        dispatch_semaphore_signal(sem);
    }] resume];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    [sess invalidateAndCancel];
    if (outHTTP && [resp isKindOfClass:NSHTTPURLResponse.class]) *outHTTP = (NSHTTPURLResponse *)resp;
    if (outErr) *outErr = err;
    return body;
}

@interface SPProbeKeyDelegate : NSObject <AVContentKeySessionDelegate>
@property (nonatomic, strong) NSData *cert;
@property (nonatomic, copy) NSString *licenseURL;
@property (nonatomic, copy) NSString *accessToken;
@property (nonatomic, copy) NSString *clientToken;
@property (nonatomic) BOOL useUTF16LE;
@property (nonatomic) BOOL offlineOnly;
@property (atomic) BOOL done;
@property (atomic) BOOL succeeded;
@property (nonatomic) NSInteger httpStatus;
@property (nonatomic, copy) NSDictionary *responseHeaders;
@property (nonatomic, copy) NSString *errorMsg;
@end

@implementation SPProbeKeyDelegate

- (void)contentKeySession:(AVContentKeySession *)session didProvideContentKeyRequest:(AVContentKeyRequest *)keyRequest {
    NSString *ident = [keyRequest.identifier isKindOfClass:NSString.class] ? (NSString *)keyRequest.identifier : [keyRequest.identifier description];
    NSString *assetID = [ident hasPrefix:@"skd://"] ? [ident substringFromIndex:6] : ident;
    fprintf(stderr, "[FairPlay] didProvideContentKeyRequest ident=%s\n", ident.UTF8String ?: "?");
    NSData *contentID = self.useUTF16LE
        ? [assetID dataUsingEncoding:NSUTF16LittleEndianStringEncoding]
        : [assetID dataUsingEncoding:NSUTF8StringEncoding];

    [keyRequest makeStreamingContentKeyRequestDataForApp:self.cert
                                       contentIdentifier:contentID
                                                 options:nil
                                       completionHandler:^(NSData *spcData, NSError *error) {
        if (error || !spcData.length) {
            self.errorMsg = [NSString stringWithFormat:@"SPC failed: %@", error];
            [keyRequest processContentKeyResponseError:error ?: [NSError errorWithDomain:@"SPProbe" code:-1 userInfo:nil]];
            self.done = YES;
            return;
        }
        fprintf(stderr, "[FairPlay] SPC encoding=%s bytes=%lu head=%s\n",
                self.useUTF16LE ? "utf16le" : "utf8",
                (unsigned long)spcData.length,
                HexPrefix(spcData, 16).UTF8String);
        if (self.offlineOnly) {
            self.succeeded = YES;
            self.done = YES;
            [keyRequest processContentKeyResponseError:[NSError errorWithDomain:@"SPProbe" code:0 userInfo:nil]];
            return;
        }

        NSString *sep = [self.licenseURL containsString:@"?"] ? @"&" : @"?";
        NSString *fullURL = [NSString stringWithFormat:@"%@%@assetId=hex", self.licenseURL, sep];
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:fullURL]];
        req.HTTPMethod = @"POST";
        req.HTTPBody = spcData;
        [req setValue:[NSString stringWithFormat:@"Bearer %@", self.accessToken] forHTTPHeaderField:@"Authorization"];
        [req setValue:self.clientToken forHTTPHeaderField:@"Client-Token"];
        [req setValue:@"OSX_ARM64" forHTTPHeaderField:@"App-Platform"];
        [req setValue:@"https://xpui.app.spotify.com" forHTTPHeaderField:@"Origin"];
        [req setValue:@"https://xpui.app.spotify.com" forHTTPHeaderField:@"Referer"];
        [req setValue:@"application/octet-stream" forHTTPHeaderField:@"Content-Type"];

        NSHTTPURLResponse *http = nil;
        NSError *netErr = nil;
        NSData *ckc = SyncHTTP(req, &http, &netErr);
        self.httpStatus = http ? http.statusCode : -1;
        self.responseHeaders = http.allHeaderFields ?: @{};
        fprintf(stderr, "[FairPlay] License POST %s -> HTTP %ld (%lu bytes)\n",
                fullURL.UTF8String, (long)self.httpStatus, (unsigned long)ckc.length);
        for (NSString *k in self.responseHeaders) {
            fprintf(stderr, "           header %s: %s\n", k.UTF8String, [[self.responseHeaders[k] description] UTF8String]);
        }

        if (netErr || self.httpStatus != 200 || !ckc.length) {
            NSString *bodyStr = ckc.length ? [[NSString alloc] initWithData:ckc encoding:NSUTF8StringEncoding] : @"";
            self.errorMsg = [NSString stringWithFormat:@"HTTP %ld err=%@ body=%@", (long)self.httpStatus, netErr.localizedDescription ?: @"none", bodyStr ?: @""];
            [keyRequest processContentKeyResponseError:netErr ?: [NSError errorWithDomain:@"SPProbe" code:self.httpStatus userInfo:nil]];
            self.done = YES;
            return;
        }
        fprintf(stderr, "[FairPlay] CKC received bytes=%lu head=%s\n", (unsigned long)ckc.length, HexPrefix(ckc, 16).UTF8String);
        AVContentKeyResponse *resp = [AVContentKeyResponse contentKeyResponseWithFairPlayStreamingKeyResponseData:ckc];
        [keyRequest processContentKeyResponse:resp];
        self.succeeded = YES;
        self.done = YES;
    }];
}

@end

@interface SPProbeHLSLoader : NSObject <AVAssetResourceLoaderDelegate>
@property (nonatomic, strong) NSData *playlistData;
@property (atomic) BOOL called;
@end

@implementation SPProbeHLSLoader
- (BOOL)resourceLoader:(AVAssetResourceLoader *)resourceLoader shouldWaitForLoadingOfRequestedResource:(AVAssetResourceLoadingRequest *)loadingRequest {
    self.called = YES;
    fprintf(stderr, "[HLS] resourceLoader called url=%s\n", loadingRequest.request.URL.absoluteString.UTF8String ?: "?");
    if (loadingRequest.contentInformationRequest) {
        loadingRequest.contentInformationRequest.contentType = UTTypeM3UPlaylist.identifier;
        loadingRequest.contentInformationRequest.contentLength = (long long)self.playlistData.length;
        loadingRequest.contentInformationRequest.byteRangeAccessSupported = YES;
    }
    if (loadingRequest.dataRequest) {
        NSUInteger offset = (NSUInteger)MAX(0LL, loadingRequest.dataRequest.requestedOffset);
        if (offset < self.playlistData.length) {
            NSUInteger avail = self.playlistData.length - offset;
            NSUInteger reqLen = loadingRequest.dataRequest.requestsAllDataToEndOfResource
                ? avail
                : MIN(avail, (NSUInteger)MAX(0L, loadingRequest.dataRequest.requestedLength));
            [loadingRequest.dataRequest respondWithData:[self.playlistData subdataWithRange:NSMakeRange(offset, reqLen)]];
        }
    }
    [loadingRequest finishLoading];
    return YES;
}
@end

static NSData *LoadCert(NSString *certPath, BOOL allowNetwork) {
    if (certPath.length) {
        NSData *d = [NSData dataWithContentsOfFile:certPath];
        if (d.length) return d;
    }
    NSString *exeDir = [[NSProcessInfo.processInfo.arguments.firstObject stringByStandardizingPath] stringByDeletingLastPathComponent];
    NSString *repoFixture = [[exeDir stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"tests/fixtures/fairplay-cert.der"];
    for (NSString *candidate in @[
        @"tests/fixtures/fairplay-cert.der",
        repoFixture,
        @"/tmp/sp-fairplay-spike/cert.der",
    ]) {
        NSData *d = [NSData dataWithContentsOfFile:candidate];
        if (d.length) {
            fprintf(stderr, "[Init] Loaded local FairPlay cert from %s (%lu bytes)\n", candidate.UTF8String, (unsigned long)d.length);
            return d;
        }
    }
    if (!allowNetwork) return nil;
    NSURL *url = [NSURL URLWithString:@"https://spclient.wg.spotify.com/fairplay-license/v1/application-certificate"];
    NSHTTPURLResponse *http = nil;
    NSError *err = nil;
    NSData *d = SyncHTTP([NSURLRequest requestWithURL:url], &http, &err);
    fprintf(stderr, "[Init] Fetched FairPlay cert from Spotify HTTP %ld (%lu bytes)\n", (long)(http ? http.statusCode : -1), (unsigned long)d.length);
    return (http.statusCode == 200 && d.length) ? d : nil;
}

static int RunOfflineCheck(NSData *certData) {
    NSString *dummyFileID = @"0123456789abcdef0123456789abcdef01234567";
    for (int mode = 0; mode < 2; mode++) {
        BOOL utf16 = (mode == 1);
        NSError *err = nil;
        NSData *spc = SPFairPlayGenerateOfflineSPC(certData, dummyFileID, utf16, &err);
        if (!spc.length) {
            fprintf(stderr, "[FAIL] Offline SPC (%s) failed: %s\n", utf16 ? "utf16le" : "utf8", err.localizedDescription.UTF8String ?: "unknown");
            fprintf(stderr, "VERDICT: FAIL\n");
            return 2;
        }
        fprintf(stderr, "[OK] Offline SPC encoding=%s bytes=%lu head=%s\n",
                utf16 ? "utf16le" : "utf8", (unsigned long)spc.length, HexPrefix(spc, 16).UTF8String);
    }

    NSDictionary *syntheticSeektable = @{
        @"seektableVersion" : @2,
        @"offset" : @1024,
        @"timescale" : @44100,
        @"segments" : @[
            @{@"size" : @160000, @"duration" : @441000},
            @{@"size" : @155000, @"duration" : @441000},
        ],
    };
    NSError *mErr = nil;
    NSString *m3u8 = SPFairPlayBuildHLSManifest(dummyFileID, @"https://audio-ak.spotifycdn.com/mock.mp4", syntheticSeektable, &mErr);
    if (!m3u8 || ![m3u8 containsString:@"#EXT-X-VERSION:6"] || ![m3u8 containsString:@"METHOD=SAMPLE-AES"]) {
        fprintf(stderr, "[FAIL] Offline HLS manifest check failed: %s\n", mErr.localizedDescription.UTF8String ?: "invalid");
        fprintf(stderr, "VERDICT: FAIL\n");
        return 3;
    }
    fprintf(stderr, "[OK] HLS v6 VOD manifest built (%lu bytes)\n", (unsigned long)m3u8.length);

    // Also verify AVPlayer actually loads our in-memory HLS playlist and invokes didProvideContentKeyRequest.
    AVContentKeySession *cks = [AVContentKeySession contentKeySessionWithKeySystem:AVContentKeySystemFairPlayStreaming];
    SPProbeKeyDelegate *del = [SPProbeKeyDelegate new];
    del.cert = certData;
    del.useUTF16LE = YES;
    del.offlineOnly = YES;
    dispatch_queue_t qKey = dispatch_queue_create("local.spotify-native.probe.offline.key", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_t qHLS = dispatch_queue_create("local.spotify-native.probe.offline.hls", DISPATCH_QUEUE_SERIAL);
    [cks setDelegate:del queue:qKey];
    SPProbeHLSLoader *loader = [SPProbeHLSLoader new];
    loader.playlistData = [m3u8 dataUsingEncoding:NSUTF8StringEncoding];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"sp-hls://track/%@.m3u8", dummyFileID]] options:nil];
    [asset.resourceLoader setDelegate:loader queue:qHLS];
    [cks addContentKeyRecipient:asset];
    AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:asset];
    AVPlayer *player = [AVPlayer playerWithPlayerItem:item];
    [player play];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5.0];
    while (!del.done && [NSDate date].timeIntervalSinceReferenceDate < deadline.timeIntervalSinceReferenceDate) {
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    fprintf(stderr, "[Offline AVPlayer] loaderCalled=%d keyDone=%d keyOK=%d itemStatus=%ld err=%s\n",
            loader.called, del.done, del.succeeded, (long)item.status, item.error.description.UTF8String ?: "none");
    [player pause];

    fprintf(stderr, "[Info] Resident RAM (phys_footprint): %.2f MB\n", ResidentMemoryMB());
    fprintf(stderr, "VERDICT: %s (offline FairPlay SPC + HLS self-check)\n", del.succeeded ? "PASS" : "FAIL");
    return del.succeeded ? 0 : 3;
}

static BOOL AttemptLivePlayback(NSData *certData,
                                NSString *token,
                                NSString *clientToken,
                                NSString *fileID,
                                NSString *licenseURL,
                                NSData *m3u8Data,
                                BOOL useUTF16LE) {
    fprintf(stderr, "\n--- Live FairPlay Attempt (%s) ---\n", useUTF16LE ? "utf16le" : "utf8");
    AVContentKeySession *cks = [AVContentKeySession contentKeySessionWithKeySystem:AVContentKeySystemFairPlayStreaming];
    SPProbeKeyDelegate *del = [SPProbeKeyDelegate new];
    del.cert = certData;
    del.licenseURL = licenseURL;
    del.accessToken = token;
    del.clientToken = clientToken;
    del.useUTF16LE = useUTF16LE;

    dispatch_queue_t qKey = dispatch_queue_create("local.spotify-native.probe.live.key", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_t qHLS = dispatch_queue_create("local.spotify-native.probe.live.hls", DISPATCH_QUEUE_SERIAL);
    [cks setDelegate:del queue:qKey];

    SPProbeHLSLoader *loader = [SPProbeHLSLoader new];
    loader.playlistData = m3u8Data;
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"sp-hls://track/%@.m3u8", fileID]] options:nil];
    [asset.resourceLoader setDelegate:loader queue:qHLS];
    [cks addContentKeyRecipient:asset];

    AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:asset];
    AVPlayer *player = [AVPlayer playerWithPlayerItem:item];
    [player play];

    NSDate *keyDeadline = [NSDate dateWithTimeIntervalSinceNow:15.0];
    while (!del.done && item.status != AVPlayerItemStatusFailed &&
           [NSDate date].timeIntervalSinceReferenceDate < keyDeadline.timeIntervalSinceReferenceDate) {
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    if (!del.succeeded) {
        fprintf(stderr, "[FAIL] Key exchange (%s): %s (loaderCalled=%d itemStatus=%ld itemErr=%s)\n",
                useUTF16LE ? "utf16le" : "utf8",
                del.errorMsg.UTF8String ?: "timeout",
                loader.called, (long)item.status, item.error.description.UTF8String ?: "none");
        for (AVPlayerItemErrorLogEvent *ev in item.errorLog.events) {
            fprintf(stderr, "       errorLog: %ld %s %s\n", (long)ev.errorStatusCode,
                    ev.errorDomain.UTF8String ?: "", ev.errorComment.UTF8String ?: "");
        }
        [player pause];
        return NO;
    }
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:5.0]];
    double playedSec = CMTimeGetSeconds(player.currentTime);
    fprintf(stderr, "[Live] AVPlayer status=%ld itemStatus=%ld currentTime=%.2fs error=%s RAM=%.2f MB\n",
            (long)player.status, (long)item.status, playedSec,
            item.error.description.UTF8String ?: "none", ResidentMemoryMB());
    for (AVPlayerItemErrorLogEvent *ev in item.errorLog.events) {
        fprintf(stderr, "       errorLog: %ld %s %s\n", (long)ev.errorStatusCode,
                ev.errorDomain.UTF8String ?: "", ev.errorComment.UTF8String ?: "");
    }
    [player pause];
    return item.status == AVPlayerItemStatusReadyToPlay && playedSec > 0.5;
}

static int RunLiveCheck(NSData *certData,
                        NSString *token,
                        NSString *clientToken,
                        NSString *trackID,
                        int encodingMode) {
    NSString *gid = SPBase62ToHexGID(trackID);
    if (!gid.length) {
        fprintf(stderr, "[FAIL] Invalid base62 track ID: %s\n", trackID.UTF8String);
        return 1;
    }

    // 1. Track manifest via track-playback/v1/media (Harmony's actual CBCS endpoint)
    NSString *trackURI = [NSString stringWithFormat:@"spotify:track:%@", trackID];
    NSString *mediaURL = [NSString stringWithFormat:
        @"https://spclient.wg.spotify.com/track-playback/v1/media/%@?manifestFileFormat=file_ids_mp4_cbcs",
        trackURI];
    NSMutableURLRequest *mediaReq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:mediaURL]];
    [mediaReq setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
    [mediaReq setValue:clientToken forHTTPHeaderField:@"Client-Token"];
    [mediaReq setValue:@"application/json" forHTTPHeaderField:@"Accept"];

    NSHTTPURLResponse *http = nil;
    NSError *err = nil;
    NSData *mediaData = SyncHTTP(mediaReq, &http, &err);
    fprintf(stderr, "[Live] track-playback/v1/media HTTP %ld (%lu bytes)\n", (long)(http ? http.statusCode : -1), (unsigned long)mediaData.length);

    NSString *fileID = nil;
    NSInteger fileFormat = 0;
    NSString *trackName = nil;

    if (http.statusCode == 200 && mediaData.length) {
        NSDictionary *root = SPJSONDict([NSJSONSerialization JSONObjectWithData:mediaData options:0 error:nil]);
        NSDictionary *mediaMap = SPJSONDict(root[@"media"]);
        NSDictionary *entry = SPJSONDict(mediaMap[trackURI]);
        if (!entry && mediaMap.count > 0) entry = SPJSONDict(mediaMap.allValues.firstObject);
        NSDictionary *item = SPJSONDict(entry[@"item"]);
        trackName = SPJSONString(SPJSONDict(item[@"metadata"])[@"name"]);
        NSDictionary *manifest = SPJSONDict(item[@"manifest"]);
        fprintf(stderr, "[Live] manifest keys: %s\n", [[manifest.allKeys componentsJoinedByString:@", "] UTF8String] ?: "none");
        NSArray *cbcs = SPJSONArray(manifest[@"file_ids_mp4_cbcs"]);
        for (id raw in cbcs) {
            NSDictionary *f = SPJSONDict(raw);
            NSString *fid = SPJSONString(f[@"file_id"]);
            NSInteger fmt = SPJSONInt(f[@"format"], 0);
            NSString *fmtStr = SPJSONString(f[@"format"]);
            if (!fmt && [fmtStr isEqualToString:@"MP4_256_CBCS"]) fmt = 15;
            else if (!fmt && [fmtStr isEqualToString:@"MP4_128_CBCS"]) fmt = 14;
            fprintf(stderr, "[Live]   cbcs candidate: file_id=%s format=%ld (%s) bitrate=%ld\n",
                    fid.UTF8String ?: "?", (long)fmt, fmtStr.UTF8String ?: "-", (long)SPJSONInt(f[@"bitrate"], 0));
            if (fid.length && (fmt == 15 || !fileID.length)) {
                fileID = fid;
                fileFormat = fmt ?: 15;
                if (fmt == 15) break;
            }
        }
    } else if (mediaData.length) {
        NSString *snip = [[NSString alloc] initWithData:[mediaData subdataWithRange:NSMakeRange(0, MIN(mediaData.length, 300))] encoding:NSUTF8StringEncoding];
        fprintf(stderr, "[Live] track-playback error body: %s\n", snip.UTF8String ?: "");
    }

    // Fallback: inspect metadata/4/track/{gid} if track-playback did not return CBCS
    if (!fileID.length) {
        NSMutableURLRequest *metaReq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"https://spclient.wg.spotify.com/metadata/4/track/%@?market=from_token", gid]]];
        [metaReq setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
        [metaReq setValue:clientToken forHTTPHeaderField:@"Client-Token"];
        [metaReq setValue:@"OSX_ARM64" forHTTPHeaderField:@"App-Platform"];
        [metaReq setValue:@"https://xpui.app.spotify.com" forHTTPHeaderField:@"Origin"];
        [metaReq setValue:@"application/json" forHTTPHeaderField:@"Accept"];

        NSData *metaData = SyncHTTP(metaReq, &http, &err);
        fprintf(stderr, "[Live] metadata/4 HTTP %ld (%lu bytes)\n", (long)(http ? http.statusCode : -1), (unsigned long)metaData.length);
        if (http.statusCode == 200 && metaData.length) {
            NSDictionary *meta = SPJSONDict([NSJSONSerialization JSONObjectWithData:metaData options:0 error:nil]);
            trackName = trackName ?: SPJSONString(meta[@"name"]);
            if (!SPFairPlaySelectCBCSFile(meta, &fileID, &fileFormat)) {
                NSMutableArray *fmts = [NSMutableArray new];
                for (id raw in SPJSONArray(meta[@"file"])) {
                    NSString *fmt = SPJSONString(SPJSONDict(raw)[@"format"]);
                    if (fmt.length) [fmts addObject:fmt];
                }
                for (id altRaw in SPJSONArray(meta[@"alternative"])) {
                    NSDictionary *alt = SPJSONDict(altRaw);
                    if (!fileID.length && SPFairPlaySelectCBCSFile(alt, &fileID, &fileFormat)) break;
                    for (id raw in SPJSONArray(alt[@"file"])) {
                        NSString *fmt = SPJSONString(SPJSONDict(raw)[@"format"]);
                        if (fmt.length) [fmts addObject:[@"alt:" stringByAppendingString:fmt]];
                    }
                }
                fprintf(stderr, "[Live] metadata/4 formats: %s\n", [[fmts componentsJoinedByString:@", "] UTF8String] ?: "none");
            }
        }
    }

    if (!fileID.length) {
        fprintf(stderr, "[FAIL] No MP4_*_CBCS file found via track-playback/v1/media or metadata/4\nVERDICT: FAIL\n");
        return 2;
    }
    fprintf(stderr, "[Live] Track '%s' -> file_id=%s format=%ld\n",
            trackName.UTF8String ?: "?", fileID.UTF8String, (long)fileFormat);

    // 2. Seektable v2
    NSData *stData = SyncHTTP([NSURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"https://seektables.spotifycdn.com/v1/seektable/%@", fileID]]], &http, &err);
    NSDictionary *st = stData.length ? SPJSONDict([NSJSONSerialization JSONObjectWithData:stData options:0 error:nil]) : nil;
    fprintf(stderr, "[Live] seektable HTTP %ld timescale=%ld offset=%ld segments=%lu\n",
            (long)(http ? http.statusCode : -1), (long)SPJSONInt(st[@"timescale"], 0),
            (long)SPJSONInt(st[@"offset"], 0), (unsigned long)SPJSONArray(st[@"segments"]).count);

    // 3. storage-resolve
    NSMutableURLRequest *srReq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithFormat:
        @"https://spclient.wg.spotify.com/storage-resolve/v2/files/audio/interactive/%ld/%@?version=10000000&product=9&platform=39&alt=json",
        (long)fileFormat, fileID]]];
    [srReq setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
    [srReq setValue:clientToken forHTTPHeaderField:@"Client-Token"];
    [srReq setValue:@"OSX_ARM64" forHTTPHeaderField:@"App-Platform"];
    [srReq setValue:@"https://xpui.app.spotify.com" forHTTPHeaderField:@"Origin"];
    NSData *srData = SyncHTTP(srReq, &http, &err);
    NSDictionary *sr = srData.length ? SPJSONDict([NSJSONSerialization JSONObjectWithData:srData options:0 error:nil]) : nil;
    NSString *cdnURL = SPJSONString(SPJSONArray(sr[@"cdnurl"]).firstObject);
    fprintf(stderr, "[Live] storage-resolve HTTP %ld cdnurl=%s\n", (long)(http ? http.statusCode : -1), cdnURL ? "OK" : "MISSING");

    // 4. melody license_url
    NSMutableURLRequest *melReq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://spclient.wg.spotify.com/melody/v1/license_url?keysystem=com.apple.fps.1_0&mediatype=audio&sdk_name=harmony&sdk_version=4.82.0-04bdb077a"]];
    [melReq setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
    [melReq setValue:clientToken forHTTPHeaderField:@"Client-Token"];
    [melReq setValue:@"OSX_ARM64" forHTTPHeaderField:@"App-Platform"];
    [melReq setValue:@"https://xpui.app.spotify.com" forHTTPHeaderField:@"Origin"];
    NSData *melData = SyncHTTP(melReq, &http, &err);
    NSDictionary *mel = melData.length ? SPJSONDict([NSJSONSerialization JSONObjectWithData:melData options:0 error:nil]) : nil;
    NSString *licURI = SPJSONString(mel[@"uri"]);
    NSString *licenseURL = licURI.length ? [NSString stringWithFormat:@"https://spclient.wg.spotify.com/%@", licURI]
                                         : @"https://spclient.wg.spotify.com/fairplay-license/v1/audio/license";
    fprintf(stderr, "[Live] melody/v1/license_url HTTP %ld -> %s\n", (long)(http ? http.statusCode : -1), licenseURL.UTF8String);

    if (!st || !cdnURL.length) {
        fprintf(stderr, "VERDICT: FAIL (missing seektable or CDN URL)\n");
        return 3;
    }

    NSString *m3u8 = SPFairPlayBuildHLSManifest(fileID, cdnURL, st, &err);
    NSData *m3u8Data = [m3u8 dataUsingEncoding:NSUTF8StringEncoding];

    BOOL ok = NO;
    if (encodingMode == 0) {
        // UTF-8 verified live (HTTP 200 CKC); keep UTF-16LE fallback for diagnostics.
        ok = AttemptLivePlayback(certData, token, clientToken, fileID, licenseURL, m3u8Data, NO);
        if (!ok) ok = AttemptLivePlayback(certData, token, clientToken, fileID, licenseURL, m3u8Data, YES);
    } else if (encodingMode == 1) {
        ok = AttemptLivePlayback(certData, token, clientToken, fileID, licenseURL, m3u8Data, YES);
    } else {
        ok = AttemptLivePlayback(certData, token, clientToken, fileID, licenseURL, m3u8Data, NO);
    }

    fprintf(stderr, "\n========================================\n");
    fprintf(stderr, "VERDICT: %s (RAM %.2f MB)\n", ok ? "PASS" : "FAIL", ResidentMemoryMB());
    fprintf(stderr, "========================================\n");
    return ok ? 0 : 4;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        BOOL live = NO;
        BOOL oauthLogin = NO;
        int encodingMode = 0; // 0 = try utf16le then utf8, 1 = utf16le only, 2 = utf8 only
        NSString *certPath = nil;
        NSString *token = nil;
        NSString *clientToken = nil;
        NSString *trackID = @"4cOdK2wGLETKBW3PvgPWqT";

        for (int i = 1; i < argc; i++) {
            NSString *arg = @(argv[i]);
            if ([arg isEqualToString:@"--offline"]) live = NO;
            else if ([arg isEqualToString:@"--live"]) live = YES;
            else if ([arg isEqualToString:@"--oauth-login"]) oauthLogin = YES;
            else if ([arg isEqualToString:@"--utf16le"]) encodingMode = 1;
            else if ([arg isEqualToString:@"--utf8"]) encodingMode = 2;
            else if ([arg isEqualToString:@"--both"]) encodingMode = 0;
            else if ([arg isEqualToString:@"--cert"] && i + 1 < argc) certPath = @(argv[++i]);
            else if ([arg isEqualToString:@"--token"] && i + 1 < argc) token = @(argv[++i]);
            else if ([arg isEqualToString:@"--client-token"] && i + 1 < argc) clientToken = @(argv[++i]);
            else if ([arg isEqualToString:@"--track-id"] && i + 1 < argc) trackID = @(argv[++i]);
        }

        NSData *certData = LoadCert(certPath, live);
        if (!certData.length) {
            fprintf(stderr, "[FAIL] Could not load FairPlay application certificate\nVERDICT: FAIL\n");
            return 1;
        }

        if (!live) {
            return RunOfflineCheck(certData);
        }

        if (oauthLogin) {
            fprintf(stderr, "[Auth] Starting ephemeral Spotify PKCE loopback login (nothing saved to Keychain)...\n");
            SPAuth *auth = [[SPAuth alloc] initWithSecretStore:nil];
            __block BOOL done = NO;
            __block NSError *authErr = nil;
            __block SPSessionBlob *blob = nil;
            [auth authorizeWithBrowserOpener:nil persist:NO timeout:180.0 completion:^(SPSessionBlob *b, NSError *e) {
                blob = b;
                authErr = e;
                done = YES;
            }];
            while (!done) {
                [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
            }
            if (authErr || !blob.accessToken.length) {
                fprintf(stderr, "[FAIL] OAuth login failed: %s\nVERDICT: FAIL\n", authErr.localizedDescription.UTF8String ?: "unknown");
                return 1;
            }
            token = blob.accessToken;
            fprintf(stderr, "[Auth] OAuth access token obtained for user '%s'\n", blob.username.UTF8String);

            done = NO;
            __block NSString *ct = nil;
            __block NSError *ctErr = nil;
            [auth clientTokenWithCompletion:^(NSString *c, NSError *e) {
                ct = c; ctErr = e; done = YES;
            }];
            while (!done) {
                [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
            }
            if (ctErr || !ct.length) {
                fprintf(stderr, "[FAIL] Client-Token fetch failed: %s\nVERDICT: FAIL\n", ctErr.localizedDescription.UTF8String ?: "unknown");
                return 1;
            }
            clientToken = ct;
            fprintf(stderr, "[Auth] Client-Token obtained (%lu chars)\n", (unsigned long)clientToken.length);
        }

        if (!token.length || !clientToken.length) {
            fprintf(stderr, "Usage:\n"
                            "  fairplay_probe --offline [--cert <path>]\n"
                            "  fairplay_probe --live --oauth-login [--track-id <b62>] [--utf16le|--utf8|--both]\n"
                            "  fairplay_probe --live --token <bearer> --client-token <ct> [--track-id <b62>]\n");
            return 1;
        }
        return RunLiveCheck(certData, token, clientToken, trackID, encodingMode);
    }
}
