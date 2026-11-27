// Native macOS FairPlay CBCS audio engine (AVQueuePlayer + in-memory HLS v6 VOD + AVContentKeySession).
#import "audio/fairplay.h"
#import "model/json.h"
#import "model/playlist.h"

#import <CoreMedia/CoreMedia.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <math.h>
#import <os/lock.h>
#import <stdlib.h>

static NSString *const kSPFairPlayErrorDomain = @"local.spotify-native.fairplay";
static void *kSPPlayerItemStatusContext = &kSPPlayerItemStatusContext;

NSArray<NSString *> *SPTrackWithRecommendations(NSString *trackURI,
                                                NSArray<NSString *> *radioURIs,
                                                NSArray<NSString *> *fallbackURIs) {
    if (!trackURI.length) return @[];
    NSMutableArray<NSString *> *after = [NSMutableArray new];
    NSMutableSet<NSString *> *seen = [NSMutableSet setWithObject:trackURI];

    for (NSString *uri in radioURIs) {
        if (!uri.length || [seen containsObject:uri]) continue;
        [seen addObject:uri];
        [after addObject:uri];
    }
    if (after.count == 0) {
        for (NSString *uri in fallbackURIs) {
            if (!uri.length || [seen containsObject:uri]) continue;
            [seen addObject:uri];
            [after addObject:uri];
        }
    }
    NSMutableArray<NSString *> *result = [NSMutableArray arrayWithCapacity:1 + after.count];
    [result addObject:trackURI];
    [result addObjectsFromArray:after];
    return [result copy];
}

static NSInteger ParseCBCSFormatValue(id rawFormat) {
    if ([rawFormat isKindOfClass:NSNumber.class]) {
        NSInteger n = [(NSNumber *)rawFormat integerValue];
        if (n == 15 || n == 14) return n;
    }
    NSString *s = SPJSONString(rawFormat);
    if ([s isEqualToString:@"MP4_256_CBCS"] || [s isEqualToString:@"15"]) return 15;
    if ([s isEqualToString:@"MP4_128_CBCS"] || [s isEqualToString:@"14"]) return 14;
    return 0;
}

static BOOL SelectCBCSFromArray(NSArray *files, NSString **outFileID, NSInteger *outFormat) {
    NSString *chosenID = nil;
    NSInteger chosenFmt = 0;
    for (id raw in files) {
        NSDictionary *f = SPJSONDict(raw);
        NSString *fid = SPJSONString(f[@"file_id"]);
        NSInteger fmt = ParseCBCSFormatValue(f[@"format"]);
        if (!fid.length) continue;
        if (fmt == 15) {
            chosenID = fid;
            chosenFmt = 15;
            break;
        }
        if ((fmt == 14 || fmt == 0) && !chosenID) {
            chosenID = fid;
            chosenFmt = fmt ?: 15;
        }
    }
    if (!chosenID) return NO;
    if (outFileID) *outFileID = chosenID;
    if (outFormat) *outFormat = chosenFmt;
    return YES;
}

BOOL SPFairPlaySelectCBCSFile(NSDictionary *trackMeta, NSString **outFileID, NSInteger *outFormat) {
    if (!trackMeta) return NO;
    // 1. Harmony track-playback/v1/media response: { item: { manifest: { file_ids_mp4_cbcs: [...] } } }
    NSDictionary *manifest = SPJSONDict(SPJSONDict(trackMeta[@"item"])[@"manifest"]) ?: SPJSONDict(trackMeta[@"manifest"]);
    NSArray *cbcs = SPJSONArray(manifest[@"file_ids_mp4_cbcs"]) ?: SPJSONArray(trackMeta[@"file_ids_mp4_cbcs"]);
    if (cbcs.count > 0 && SelectCBCSFromArray(cbcs, outFileID, outFormat)) {
        return YES;
    }
    // 2. Fallback metadata/4/track shape: { file: [...], alternative: [{ file: [...] }] }
    NSArray *files = SPJSONArray(trackMeta[@"file"]);
    NSString *chosenID = nil;
    NSInteger chosenFmt = 0;
    for (id raw in files) {
        NSDictionary *f = SPJSONDict(raw);
        NSString *fid = SPJSONString(f[@"file_id"]);
        NSInteger fmt = ParseCBCSFormatValue(f[@"format"]);
        if (!fid.length || !fmt) continue;
        if (fmt == 15) { chosenID = fid; chosenFmt = 15; break; }
        if (fmt == 14 && !chosenID) { chosenID = fid; chosenFmt = 14; }
    }
    if (!chosenID) {
        for (id altRaw in SPJSONArray(trackMeta[@"alternative"])) {
            if (SPFairPlaySelectCBCSFile(SPJSONDict(altRaw), outFileID, outFormat)) return YES;
        }
        return NO;
    }
    if (outFileID) *outFileID = chosenID;
    if (outFormat) *outFormat = chosenFmt;
    return YES;
}

NSString *SPFairPlayBuildHLSManifest(NSString *fileID,
                                     NSString *cdnURL,
                                     NSDictionary *seektable,
                                     NSError **outError) {
    if (!fileID.length || !cdnURL.length || !seektable) {
        if (outError) *outError = [NSError errorWithDomain:kSPFairPlayErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey : @"Missing fileID, cdnURL, or seektable"}];
        return nil;
    }
    NSInteger offset = SPJSONInt(seektable[@"offset"], 0);
    double timescale = SPJSONDouble(seektable[@"timescale"], 0.0);
    NSArray *segments = SPJSONArray(seektable[@"segments"]);
    if (offset <= 0 || timescale <= 0.0 || segments.count == 0) {
        if (outError) *outError = [NSError errorWithDomain:kSPFairPlayErrorDomain code:2 userInfo:@{NSLocalizedDescriptionKey : @"Malformed seektable v2"}];
        return nil;
    }

    double maxSegDur = 10.0;
    NSMutableString *body = [NSMutableString stringWithCapacity:segments.count * 96];
    NSInteger pos = offset;
    for (id seg in segments) {
        NSInteger sz = 0;
        double durTicks = 0.0;
        if ([seg isKindOfClass:NSArray.class]) {
            NSArray *arr = (NSArray *)seg;
            if (arr.count < 2) continue;
            sz = SPJSONInt(arr[0], 0);
            durTicks = SPJSONDouble(arr[1], 0.0);
        } else if ([seg isKindOfClass:NSDictionary.class]) {
            NSDictionary *d = (NSDictionary *)seg;
            sz = SPJSONInt(d[@"size"], 0);
            durTicks = SPJSONDouble(d[@"duration"], 0.0);
        }
        if (sz <= 0 || durTicks <= 0.0) continue;
        double durSec = durTicks / timescale;
        if (durSec > maxSegDur) maxSegDur = durSec;
        [body appendFormat:@"#EXTINF:%.6f,\n#EXT-X-BYTERANGE:%ld@%ld\n%@\n", durSec, (long)sz, (long)pos, cdnURL];
        pos += sz;
    }

    NSInteger targetDuration = (NSInteger)ceil(maxSegDur);
    NSMutableString *m3u8 = [NSMutableString stringWithFormat:
        @"#EXTM3U\n"
        @"#EXT-X-VERSION:6\n"
        @"#EXT-X-TARGETDURATION:%ld\n"
        @"#EXT-X-MEDIA-SEQUENCE:0\n"
        @"#EXT-X-PLAYLIST-TYPE:VOD\n"
        @"#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"skd://%@\",KEYFORMATVERSIONS=\"1\",KEYFORMAT=\"com.apple.streamingkeydelivery\"\n"
        @"#EXT-X-MAP:URI=\"%@\",BYTERANGE=\"%ld@0\"\n",
        (long)targetDuration, fileID, cdnURL, (long)offset];
    [m3u8 appendString:body];
    [m3u8 appendString:@"#EXT-X-ENDLIST\n"];
    return [m3u8 copy];
}

@interface SPOfflineSPCDelegate : NSObject <AVContentKeySessionDelegate>
@property (nonatomic, strong) NSData *cert;
@property (nonatomic) BOOL useUTF16LE;
@property (nonatomic, strong) dispatch_semaphore_t sem;
@property (nonatomic, strong, nullable) NSData *spc;
@property (nonatomic, strong, nullable) NSError *error;
@end

@implementation SPOfflineSPCDelegate

- (void)contentKeySession:(AVContentKeySession *)session didProvideContentKeyRequest:(AVContentKeyRequest *)keyRequest {
    NSString *ident = [keyRequest.identifier isKindOfClass:NSString.class] ? (NSString *)keyRequest.identifier : [keyRequest.identifier description];
    NSString *assetID = [ident hasPrefix:@"skd://"] ? [ident substringFromIndex:6] : ident;
    NSData *contentID = self.useUTF16LE
        ? [assetID dataUsingEncoding:NSUTF16LittleEndianStringEncoding]
        : [assetID dataUsingEncoding:NSUTF8StringEncoding];
    [keyRequest makeStreamingContentKeyRequestDataForApp:self.cert
                                       contentIdentifier:contentID
                                                 options:nil
                                       completionHandler:^(NSData *spcData, NSError *error) {
        self.spc = spcData;
        self.error = error;
        dispatch_semaphore_signal(self.sem);
    }];
}

@end

NSData *SPFairPlayGenerateOfflineSPC(NSData *certDER,
                                     NSString *fileID,
                                     BOOL useUTF16LE,
                                     NSError **outError) {
    if (!certDER.length || !fileID.length) {
        if (outError) *outError = [NSError errorWithDomain:kSPFairPlayErrorDomain code:3 userInfo:@{NSLocalizedDescriptionKey : @"Missing cert or fileID"}];
        return nil;
    }
    AVContentKeySession *cks = [AVContentKeySession contentKeySessionWithKeySystem:AVContentKeySystemFairPlayStreaming];
    SPOfflineSPCDelegate *del = [SPOfflineSPCDelegate new];
    del.cert = certDER;
    del.useUTF16LE = useUTF16LE;
    del.sem = dispatch_semaphore_create(0);
    dispatch_queue_t q = dispatch_queue_create("local.spotify-native.fairplay.offline", DISPATCH_QUEUE_SERIAL);
    [cks setDelegate:del queue:q];
    [cks processContentKeyRequestWithIdentifier:[NSString stringWithFormat:@"skd://%@", fileID]
                             initializationData:nil
                                        options:nil];
    long timedOut = dispatch_semaphore_wait(del.sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
    if (timedOut != 0) {
        if (outError) *outError = [NSError errorWithDomain:kSPFairPlayErrorDomain code:4 userInfo:@{NSLocalizedDescriptionKey : @"Timed out generating offline SPC"}];
        return nil;
    }
    if (del.error || !del.spc.length) {
        if (outError) *outError = del.error ?: [NSError errorWithDomain:kSPFairPlayErrorDomain code:5 userInfo:@{NSLocalizedDescriptionKey : @"Empty SPC generated"}];
        return nil;
    }
    return del.spc;
}

@implementation SPFairPlayEngine {
    SPNetClient *_net;
    SPStore *_store;
    dispatch_queue_t _drmQueue;
    os_unfair_lock _drmLock;

    AVQueuePlayer *_player;
    AVPlayerItem *_observedItem;
    AVContentKeySession *_keySession;
    NSData *_applicationCertificate;
    NSString *_cachedLicenseURL;
    NSMutableDictionary<NSString *, NSData *> *_playlistsByFileID;
    NSMutableArray<NSString *> *_recentFileIDs;

    NSMutableArray<NSString *> *_originalQueue;
    NSMutableArray<NSString *> *_queue;
    NSMutableArray<NSString *> *_userQueued;
    NSInteger _currentIndex;
    NSString *_contextURI;
    BOOL _shuffling;
    SPRepeatMode _repeatMode;
    NSInteger _volumePercent;
    int64_t _positionMs;
    int64_t _durationMs;
    int64_t _timestampMs;
    SPAudioEngineStatus _status;
    SPPlaybackState *_playbackState;
    uint64_t _playGeneration;
}

@synthesize delegate = _delegate;

- (instancetype)initWithNetClient:(SPNetClient *)netClient store:(SPStore *)store {
    if (!(self = [super init])) return nil;
    _net = netClient;
    _store = store;
    _drmQueue = dispatch_queue_create("local.spotify-native.fairplay.drm", DISPATCH_QUEUE_SERIAL);
    _drmLock = OS_UNFAIR_LOCK_INIT;
    _playlistsByFileID = [NSMutableDictionary new];
    _recentFileIDs = [NSMutableArray new];
    _originalQueue = [NSMutableArray new];
    _queue = [NSMutableArray new];
    _userQueued = [NSMutableArray new];
    _currentIndex = -1;
    _volumePercent = 80;
    // Verified live against spclient fairplay-license/v1/audio/license?assetId=hex: UTF-8 returns 200 OK CKC (UTF-16LE returns 500).
    _useUTF16LEAssetID = NO;
    _status = SPAudioEngineStatusIdle;
    return self;
}

- (void)dealloc {
    [self detachObservedItem];
    [_player pause];
    [_player removeAllItems];
    [_keySession setDelegate:nil queue:nil];
}

- (NSData *)applicationCertificate {
    os_unfair_lock_lock(&_drmLock);
    NSData *cert = _applicationCertificate;
    os_unfair_lock_unlock(&_drmLock);
    return cert;
}

- (void)setApplicationCertificate:(NSData *)applicationCertificate {
    NSData *copy = [applicationCertificate copy];
    os_unfair_lock_lock(&_drmLock);
    _applicationCertificate = copy;
    os_unfair_lock_unlock(&_drmLock);
}

- (NSString *)cachedLicenseURL {
    os_unfair_lock_lock(&_drmLock);
    NSString *url = _cachedLicenseURL;
    os_unfair_lock_unlock(&_drmLock);
    return url;
}

- (void)setCachedLicenseURL:(NSString *)licenseURL {
    NSString *copy = [licenseURL copy];
    os_unfair_lock_lock(&_drmLock);
    _cachedLicenseURL = copy;
    os_unfair_lock_unlock(&_drmLock);
}

- (SPAudioEngineKind)kind { return SPAudioEngineKindFairPlay; }
- (SPAudioEngineStatus)status { return _status; }
- (NSInteger)volumePercent { return _volumePercent; }
- (SPPlaybackState *)playbackState { return _playbackState; }
- (NSArray<NSString *> *)queueURIs { return [_queue copy]; }
- (NSInteger)currentQueueIndex { return _currentIndex; }

- (void)detachObservedItem {
    if (!_observedItem) return;
    AVPlayerItem *item = _observedItem;
    _observedItem = nil;
    [NSNotificationCenter.defaultCenter removeObserver:self name:AVPlayerItemDidPlayToEndTimeNotification object:item];
    [NSNotificationCenter.defaultCenter removeObserver:self name:AVPlayerItemFailedToPlayToEndTimeNotification object:item];
    [item removeObserver:self forKeyPath:@"status" context:kSPPlayerItemStatusContext];
}

- (void)attachObserversToItem:(AVPlayerItem *)item {
    [self detachObservedItem];
    if (!item) return;
    _observedItem = item;
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(playerItemDidPlayToEnd:)
                                               name:AVPlayerItemDidPlayToEndTimeNotification
                                             object:item];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(playerItemFailedToPlayToEnd:)
                                               name:AVPlayerItemFailedToPlayToEndTimeNotification
                                             object:item];
    [item addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionNew context:kSPPlayerItemStatusContext];
}

- (void)playerItemDidPlayToEnd:(NSNotification *)note {
    AVPlayerItem *endedItem = note.object;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (endedItem && endedItem != self->_observedItem) return;
        [self handleCurrentTrackEnded];
    });
}

- (void)playerItemFailedToPlayToEnd:(NSNotification *)note {
    AVPlayerItem *failedItem = note.object;
    NSError *err = note.userInfo[AVPlayerItemFailedToPlayToEndTimeErrorKey] ?: failedItem.error;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (failedItem && failedItem != self->_observedItem) return;
        [self handlePlaybackFailureWithError:err];
    });
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey, id> *)change
                       context:(void *)context {
    if (context != kSPPlayerItemStatusContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    AVPlayerItem *item = [object isKindOfClass:AVPlayerItem.class] ? (AVPlayerItem *)object : nil;
    if (!item) return;
    AVPlayerItemStatus st = item.status;
    NSError *err = item.error;
    CMTime dur = item.duration;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (item != self->_observedItem) return;
        if (st == AVPlayerItemStatusFailed) {
            [self handlePlaybackFailureWithError:err];
        } else if (st == AVPlayerItemStatusReadyToPlay && self->_durationMs <= 0 && CMTIME_IS_NUMERIC(dur)) {
            double sec = CMTimeGetSeconds(dur);
            if (isfinite(sec) && sec > 0) {
                self->_durationMs = (int64_t)llround(sec * 1000.0);
                [self emitPlaybackState];
            }
        }
    });
}

- (void)handleCurrentTrackEnded {
    if (_repeatMode == SPRepeatTrack && _currentIndex >= 0 && _currentIndex < (NSInteger)_queue.count) {
        if (_player) {
            [_player seekToTime:kCMTimeZero];
            [_player play];
            _positionMs = 0;
            _timestampMs = (int64_t)llround(NSDate.date.timeIntervalSince1970 * 1000.0);
            [self setStatus:SPAudioEngineStatusPlaying error:nil];
            [self emitPlaybackState];
            return;
        }
        _positionMs = 0;
        _timestampMs = (int64_t)llround(NSDate.date.timeIntervalSince1970 * 1000.0);
        [self emitPlaybackState];
        return;
    }
    [self skipNext];
}

- (void)handlePlaybackFailureWithError:(NSError *)error {
    NSError *outErr = error ?: [NSError errorWithDomain:kSPFairPlayErrorDomain code:11 userInfo:@{NSLocalizedDescriptionKey : @"AVPlayerItem playback failed"}];
    [_player pause];
    [self setStatus:SPAudioEngineStatusFailed error:outErr];
    [self emitPlaybackState];
}

- (void)simulateCurrentItemDidEnd {
    [self handleCurrentTrackEnded];
}

- (void)simulateCurrentItemDidFailWithError:(NSError *)error {
    [self handlePlaybackFailureWithError:error];
}

- (void)setStatus:(SPAudioEngineStatus)status error:(NSError *)error {
    _status = status;
    if ([self.delegate respondsToSelector:@selector(audioEngine:didChangeStatus:error:)]) {
        [self.delegate audioEngine:self didChangeStatus:status error:error];
    }
}

- (void)emitPlaybackState {
    NSString *currentURI = (_currentIndex >= 0 && _currentIndex < (NSInteger)_queue.count) ? _queue[(NSUInteger)_currentIndex] : nil;
    NSMutableArray<SPQueueTrack *> *prev = [NSMutableArray new];
    for (NSInteger i = 0; i < _currentIndex && i < (NSInteger)_queue.count; i++) {
        [prev addObject:[[SPQueueTrack alloc] initWithURI:_queue[(NSUInteger)i] uid:@"" provider:@"context" isHidden:NO]];
    }
    NSMutableArray<SPQueueTrack *> *next = [NSMutableArray new];
    for (NSString *quri in _userQueued) {
        [next addObject:[[SPQueueTrack alloc] initWithURI:quri uid:@"" provider:@"queue" isHidden:NO]];
    }
    for (NSInteger i = _currentIndex + 1; i < (NSInteger)_queue.count; i++) {
        [next addObject:[[SPQueueTrack alloc] initWithURI:_queue[(NSUInteger)i] uid:@"" provider:@"context" isHidden:NO]];
    }

    SPPlaybackState *state = [[SPPlaybackState alloc] initWithActiveDeviceID:_net.auth.deviceID
                                                                  contextURI:_contextURI
                                                                 contextName:nil
                                                             currentTrackURI:currentURI
                                                                 timestampMs:_timestampMs
                                                     positionAsOfTimestampMs:_positionMs
                                                                  durationMs:_durationMs
                                                                   isPlaying:(_status == SPAudioEngineStatusPlaying)
                                                                    isPaused:(_status == SPAudioEngineStatusPaused)
                                                                   shuffling:_shuffling
                                                                  repeatMode:_repeatMode
                                                                 canSkipNext:(next.count > 0 || _repeatMode != SPRepeatOff)
                                                                  canShuffle:YES
                                                            canRepeatContext:YES
                                                              canRepeatTrack:YES
                                                                  prevTracks:prev
                                                                  nextTracks:next];
    _playbackState = state;
    [_store setPlaybackState:state];
    if ([self.delegate respondsToSelector:@selector(audioEngine:didUpdatePlaybackState:)]) {
        [self.delegate audioEngine:self didUpdatePlaybackState:state];
    }
}

- (void)startWithCompletion:(void (^)(NSError *))completion {
    if (_dryRunMode) {
        [self setStatus:SPAudioEngineStatusReady error:nil];
        if (completion) completion(nil);
        return;
    }
    [self setStatus:SPAudioEngineStatusStarting error:nil];
    if (!_player) {
        _player = [AVQueuePlayer new];
        _player.volume = (float)_volumePercent / 100.0f;
    }
    if (!_keySession) {
        _keySession = [AVContentKeySession contentKeySessionWithKeySystem:AVContentKeySystemFairPlayStreaming];
        [_keySession setDelegate:self queue:_drmQueue];
    }
    if (self.applicationCertificate.length) {
        [self setStatus:SPAudioEngineStatusReady error:nil];
        if (completion) completion(nil);
        return;
    }
    [_net fetchFairPlayCertificateWithCompletion:^(NSData *certDER, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (err || !certDER.length) {
                [self setStatus:SPAudioEngineStatusFailed error:err];
                if (completion) completion(err);
                return;
            }
            self.applicationCertificate = certDER;
            [self setStatus:SPAudioEngineStatusReady error:nil];
            if (completion) completion(nil);
        });
    }];
}

- (void)stop {
    _playGeneration++;
    [self detachObservedItem];
    [_player pause];
    [_player removeAllItems];
    dispatch_sync(_drmQueue, ^{
        [self->_playlistsByFileID removeAllObjects];
        [self->_recentFileIDs removeAllObjects];
    });
    _positionMs = 0;
    [self setStatus:SPAudioEngineStatusIdle error:nil];
    [self emitPlaybackState];
}

static NSMutableArray<NSString *> *FisherYatesShuffledCopy(NSArray<NSString *> *source, NSInteger keepFirstIndex) {
    NSMutableArray<NSString *> *pool = [source mutableCopy];
    NSString *pinned = nil;
    if (keepFirstIndex >= 0 && keepFirstIndex < (NSInteger)pool.count) {
        pinned = pool[(NSUInteger)keepFirstIndex];
        [pool removeObjectAtIndex:(NSUInteger)keepFirstIndex];
    }
    for (NSUInteger i = pool.count; i > 1; i--) {
        NSUInteger j = arc4random_uniform((uint32_t)i);
        [pool exchangeObjectAtIndex:(i - 1) withObjectAtIndex:j];
    }
    if (pinned) {
        [pool insertObject:pinned atIndex:0];
    }
    return pool;
}

- (nullable NSArray<NSString *> *)localTracksForContextURI:(NSString *)contextURI {
    if (!contextURI.length) return nil;
    if ([contextURI isEqualToString:SPLikedSongsPlaylistURI] ||
        [contextURI isEqualToString:SPLikedSongsCollectionURI] ||
        [contextURI hasSuffix:@":collection"]) {
        if (_store.libraryTracks.count == 0) return nil;
        NSMutableArray<NSString *> *uris = [NSMutableArray arrayWithCapacity:_store.libraryTracks.count];
        for (SPTrack *t in _store.libraryTracks) {
            if (t.uri.length) [uris addObject:t.uri];
        }
        return uris.count ? uris : nil;
    }
    NSString *albumID = SPURIIDFromURIOfKind(contextURI, @"album");
    if (albumID.length) {
        SPAlbum *al = [_store albumWithID:albumID];
        if (al.detailsLoaded && al.trackIDs.count > 0) {
            NSMutableArray<NSString *> *uris = [NSMutableArray arrayWithCapacity:al.trackIDs.count];
            for (NSString *tid in al.trackIDs) {
                [uris addObject:[NSString stringWithFormat:@"spotify:track:%@", tid]];
            }
            return uris;
        }
        return nil;
    }
    NSString *playlistID = SPURIIDFromURIOfKind(contextURI, @"playlist");
    if (playlistID.length) {
        SPPlaylist *pl = [_store playlistWithID:playlistID];
        if (pl.detailsLoaded && pl.items.count > 0) {
            NSMutableArray<NSString *> *uris = [NSMutableArray arrayWithCapacity:pl.items.count];
            for (SPPlaylistItem *item in pl.items) {
                if (item.trackID.length) [uris addObject:[NSString stringWithFormat:@"spotify:track:%@", item.trackID]];
            }
            return uris.count ? uris : nil;
        }
        return nil;
    }
    NSString *artistID = SPURIIDFromURIOfKind(contextURI, @"artist");
    if (artistID.length) {
        SPArtist *ar = [_store artistWithID:artistID];
        if (ar.topTrackIDs.count > 0) {
            NSMutableArray<NSString *> *uris = [NSMutableArray arrayWithCapacity:ar.topTrackIDs.count];
            for (NSString *tid in ar.topTrackIDs) {
                [uris addObject:[NSString stringWithFormat:@"spotify:track:%@", tid]];
            }
            return uris;
        }
        NSMutableArray<NSString *> *local = [NSMutableArray new];
        for (SPTrack *t in _store.libraryTracks) {
            if ([t.artistID isEqualToString:artistID] && t.uri.length) [local addObject:t.uri];
        }
        if (ar.detailsLoaded && local.count > 0) return local;
        return nil;
    }
    if ([contextURI hasPrefix:@"spotify:track:"]) {
        return @[ contextURI ];
    }
    return nil;
}

- (void)startContextTracks:(NSArray<NSString *> *)uris
        startingAtTrackURI:(NSString *)trackURI
                trackIndex:(NSInteger)trackIndex
                generation:(uint64_t)gen
                completion:(void (^)(NSError *))completion {
    if (_playGeneration != gen) {
        if (completion) completion(nil);
        return;
    }
    if (!uris.count) {
        if (trackURI.length) {
            uris = @[ trackURI ];
        } else {
            NSError *err = [NSError errorWithDomain:kSPFairPlayErrorDomain code:6 userInfo:@{NSLocalizedDescriptionKey : @"Context resolved to zero playable tracks"}];
            if (completion) completion(err);
            return;
        }
    }

    [_originalQueue setArray:uris];
    NSInteger startIdx = 0;
    if (trackURI.length) {
        if (trackIndex >= 0 && trackIndex < (NSInteger)uris.count && [uris[(NSUInteger)trackIndex] isEqualToString:trackURI]) {
            startIdx = trackIndex;
        } else {
            NSUInteger found = [uris indexOfObject:trackURI];
            if (found != NSNotFound) {
                startIdx = (NSInteger)found;
            } else {
                [_originalQueue insertObject:trackURI atIndex:0];
                startIdx = 0;
            }
        }
    } else if (trackIndex >= 0 && trackIndex < (NSInteger)uris.count) {
        startIdx = trackIndex;
    }

    if (_shuffling) {
        // When clicking Shuffle Play with no specific track, pick a random first track; when clicking a specific track, keep it first.
        NSInteger pinIdx = trackURI.length ? startIdx : (NSInteger)arc4random_uniform((uint32_t)_originalQueue.count);
        [_queue setArray:FisherYatesShuffledCopy(_originalQueue, pinIdx)];
        _currentIndex = 0;
    } else {
        [_queue setArray:_originalQueue];
        _currentIndex = startIdx;
    }
    [self loadAndPlayCurrentForGeneration:gen completion:completion];
}

- (void)resolveRemoteContextURI:(NSString *)contextURI
             startingAtTrackURI:(NSString *)trackURI
                     trackIndex:(NSInteger)trackIndex
                     generation:(uint64_t)gen
                     completion:(void (^)(NSError *))completion {
    __weak typeof(self) weakSelf = self;
    void (^fallbackFetch)(void) = ^{
        SPFairPlayEngine *s = weakSelf;
        if (!s || s->_playGeneration != gen) { if (completion) completion(nil); return; }
        NSString *albumID = SPURIIDFromURIOfKind(contextURI, @"album");
        if (albumID.length) {
            [s->_net fetchAlbumWithID:albumID completion:^(SPAlbum *album, NSArray<SPTrack *> *tracks, NSError *err) {
                (void)err;
                dispatch_async(dispatch_get_main_queue(), ^{
                    SPFairPlayEngine *st = weakSelf;
                    if (!st || st->_playGeneration != gen) { if (completion) completion(nil); return; }
                    if (tracks.count) [st->_store upsertTracks:tracks];
                    if (album) [st->_store upsertAlbums:@[ album ]];
                    NSMutableArray<NSString *> *uris = [NSMutableArray arrayWithCapacity:tracks.count];
                    for (SPTrack *t in tracks) if (t.uri.length) [uris addObject:t.uri];
                    [st startContextTracks:uris startingAtTrackURI:trackURI trackIndex:trackIndex generation:gen completion:completion];
                });
            }];
            return;
        }
        NSString *playlistID = SPURIIDFromURIOfKind(contextURI, @"playlist");
        if (playlistID.length) {
            [s->_net fetchPlaylistWithID:playlistID offset:0 limit:300 completion:^(SPPlaylist *pl, NSArray<SPTrack *> *tracks, NSError *err) {
                (void)err;
                dispatch_async(dispatch_get_main_queue(), ^{
                    SPFairPlayEngine *st = weakSelf;
                    if (!st || st->_playGeneration != gen) { if (completion) completion(nil); return; }
                    if (tracks.count) [st->_store upsertTracks:tracks];
                    if (pl) [st->_store upsertPlaylists:@[ pl ]];
                    NSMutableArray<NSString *> *uris = [NSMutableArray arrayWithCapacity:tracks.count];
                    for (SPTrack *t in tracks) if (t.uri.length) [uris addObject:t.uri];
                    [st startContextTracks:uris startingAtTrackURI:trackURI trackIndex:trackIndex generation:gen completion:completion];
                });
            }];
            return;
        }
        NSString *artistID = SPURIIDFromURIOfKind(contextURI, @"artist");
        if (artistID.length) {
            [s->_net fetchArtistOverviewWithID:artistID fullCompletion:^(SPArtist *artist, NSArray<SPAlbum *> *albums, NSArray<SPTrack *> *topTracks, NSError *err) {
                (void)err;
                dispatch_async(dispatch_get_main_queue(), ^{
                    SPFairPlayEngine *st = weakSelf;
                    if (!st || st->_playGeneration != gen) { if (completion) completion(nil); return; }
                    if (albums.count) [st->_store upsertAlbums:albums];
                    if (topTracks.count) [st->_store upsertTracks:topTracks];
                    if (artist) [st->_store upsertArtists:@[ artist ]];
                    NSMutableArray<NSString *> *uris = [NSMutableArray arrayWithCapacity:topTracks.count];
                    for (SPTrack *t in topTracks) if (t.uri.length) [uris addObject:t.uri];
                    [st startContextTracks:uris startingAtTrackURI:trackURI trackIndex:trackIndex generation:gen completion:completion];
                });
            }];
            return;
        }
        [s startContextTracks:@[] startingAtTrackURI:trackURI trackIndex:trackIndex generation:gen completion:completion];
    };

    [_net resolveContextURI:contextURI deviceID:_net.auth.deviceID maxPages:5 completion:^(NSArray<NSString *> *trackURIs, NSString *nextPageURL, NSError *err) {
        (void)nextPageURL;
        (void)err;
        dispatch_async(dispatch_get_main_queue(), ^{
            SPFairPlayEngine *s = weakSelf;
            if (!s || s->_playGeneration != gen) { if (completion) completion(nil); return; }
            if (trackURIs.count > 0) {
                [s startContextTracks:trackURIs startingAtTrackURI:trackURI trackIndex:trackIndex generation:gen completion:completion];
            } else {
                fallbackFetch();
            }
        });
    }];
}

- (void)playTrackURI:(NSString *)trackURI
        inContextURI:(NSString *)contextURI
          trackIndex:(NSInteger)trackIndex
          completion:(void (^)(NSError *))completion {
    _playGeneration++;
    uint64_t gen = _playGeneration;
    _contextURI = [contextURI copy];

    if (contextURI.length) {
        NSArray<NSString *> *localURIs = [self localTracksForContextURI:contextURI];
        if (localURIs.count > 0) {
            [self startContextTracks:localURIs startingAtTrackURI:trackURI trackIndex:trackIndex generation:gen completion:completion];
            return;
        }
        if (_net) {
            [self resolveRemoteContextURI:contextURI startingAtTrackURI:trackURI trackIndex:trackIndex generation:gen completion:completion];
            return;
        }
    }

    if (trackURI.length) {
        [self startContextTracks:@[ trackURI ] startingAtTrackURI:trackURI trackIndex:0 generation:gen completion:completion];
    } else {
        NSError *err = [NSError errorWithDomain:kSPFairPlayErrorDomain code:6 userInfo:@{NSLocalizedDescriptionKey : @"Invalid track or context URI"}];
        if (completion) completion(err);
    }
}

- (void)playTrackURIs:(NSArray<NSString *> *)trackURIs completion:(void (^)(NSError *))completion {
    if (!trackURIs.count) {
        if (completion) completion(nil);
        return;
    }
    _playGeneration++;
    uint64_t gen = _playGeneration;
    _contextURI = nil;
    [_originalQueue setArray:trackURIs];
    if (_shuffling) {
        [_queue setArray:FisherYatesShuffledCopy(trackURIs, 0)];
    } else {
        [_queue setArray:trackURIs];
    }
    _currentIndex = 0;
    [self loadAndPlayCurrentForGeneration:gen completion:completion];
}

- (void)playTrackURIWithRadio:(NSString *)trackURI
                 fallbackURIs:(NSArray<NSString *> *)fallbackURIs
                   completion:(void (^)(NSError *))completion {
    if (!trackURI.length) {
        if (completion) completion(nil);
        return;
    }
    _playGeneration++;
    uint64_t gen = _playGeneration;
    NSArray<NSString *> *fallbackCopy = [fallbackURIs copy];

    [_net fetchRadioSeedForTrackURI:trackURI deviceID:_net.auth.deviceID completion:^(NSArray<NSString *> *radioURIs, NSError *err) {
        (void)err;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self->_playGeneration != gen) {
                if (completion) completion(nil);
                return; // Superseded by a newer click.
            }
            NSArray<NSString *> *combined = SPTrackWithRecommendations(trackURI, radioURIs, fallbackCopy);
            self->_contextURI = nil;
            [self->_originalQueue setArray:combined];
            [self->_queue setArray:combined];
            self->_currentIndex = 0;
            [self loadAndPlayCurrentForGeneration:gen completion:completion];
        });
    }];
}

- (void)loadAndPlayCurrentForGeneration:(uint64_t)gen completion:(void (^)(NSError *))completion {
    if (_currentIndex < 0 || _currentIndex >= (NSInteger)_queue.count) {
        if (completion) completion(nil);
        return;
    }
    NSString *uri = _queue[(NSUInteger)_currentIndex];
    NSString *trackID = SPURITrackIDFromString(uri);
    SPTrack *cached = trackID ? [_store trackWithID:trackID] : nil;
    _positionMs = 0;
    _durationMs = cached ? cached.durationMs : 0;
    _timestampMs = (int64_t)llround(NSDate.date.timeIntervalSince1970 * 1000.0);

    if (_dryRunMode) {
        [self setStatus:SPAudioEngineStatusPlaying error:nil];
        [self emitPlaybackState];
        if (completion) completion(nil);
        return;
    }

    if (!trackID.length) {
        NSError *err = [NSError errorWithDomain:kSPFairPlayErrorDomain code:6 userInfo:@{NSLocalizedDescriptionKey : @"Invalid track URI"}];
        if (completion) completion(err);
        return;
    }

    void (^resolveStream)(NSString *, NSInteger, SPTrack *, NSInteger) = ^(NSString *fileID, NSInteger fileFmt, SPTrack *track, NSInteger metaDurationMs) {
        dispatch_group_t grp = dispatch_group_create();
        __block NSDictionary *st = nil;
        __block NSString *cdn = nil;
        __block NSString *lic = nil;
        __block NSError *stErr = nil;
        __block NSError *cdnErr = nil;
        __block NSError *licErr = nil;

        dispatch_group_enter(grp);
        [self->_net fetchSeektableForFileID:fileID completion:^(NSDictionary *s, NSError *e) {
            st = s;
            stErr = e;
            dispatch_group_leave(grp);
        }];
        dispatch_group_enter(grp);
        [self->_net resolveStorageForFileID:fileID format:fileFmt completion:^(NSString *u, NSError *e) {
            cdn = u;
            cdnErr = e;
            dispatch_group_leave(grp);
        }];
        dispatch_group_enter(grp);
        [self->_net fetchFairPlayLicenseURLWithCompletion:^(NSString *u, NSError *e) {
            lic = u;
            licErr = e;
            dispatch_group_leave(grp);
        }];

        dispatch_group_notify(grp, dispatch_get_main_queue(), ^{
            if (self->_playGeneration != gen) return;
            NSError *stepErr = stErr ?: cdnErr ?: licErr;
            if (stepErr || !st || !cdn) {
                [self setStatus:SPAudioEngineStatusFailed error:stepErr];
                if (completion) completion(stepErr);
                return;
            }
            NSError *m3u8Err = nil;
            NSString *m3u8 = SPFairPlayBuildHLSManifest(fileID, cdn, st, &m3u8Err);
            if (!m3u8) {
                [self setStatus:SPAudioEngineStatusFailed error:m3u8Err];
                if (completion) completion(m3u8Err);
                return;
            }
            if (track) [self->_store upsertTracks:@[ track ]];
            if (track && track.durationMs > 0) self->_durationMs = track.durationMs;
            else if (metaDurationMs > 0 && self->_durationMs <= 0) self->_durationMs = metaDurationMs;
            self.cachedLicenseURL = lic;
            NSData *m3u8Data = [m3u8 dataUsingEncoding:NSUTF8StringEncoding];
            dispatch_sync(self->_drmQueue, ^{
                self->_playlistsByFileID[fileID] = m3u8Data;
                [self->_recentFileIDs removeObject:fileID];
                [self->_recentFileIDs addObject:fileID];
                while (self->_recentFileIDs.count > 2) {
                    NSString *evict = self->_recentFileIDs.firstObject;
                    [self->_recentFileIDs removeObjectAtIndex:0];
                    [self->_playlistsByFileID removeObjectForKey:evict];
                }
            });

            NSURL *assetURL = [NSURL URLWithString:[NSString stringWithFormat:@"sp-hls://track/%@.m3u8", fileID]];
            AVURLAsset *asset = [AVURLAsset URLAssetWithURL:assetURL options:nil];
            [asset.resourceLoader setDelegate:self queue:self->_drmQueue];
            [self->_keySession addContentKeyRecipient:asset];
            AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:asset];
            [self attachObserversToItem:item];
            [self->_player removeAllItems];
            [self->_player insertItem:item afterItem:nil];
            self->_player.volume = (float)self->_volumePercent / 100.0f;
            [self->_player play];
            self->_timestampMs = (int64_t)llround(NSDate.date.timeIntervalSince1970 * 1000.0);
            [self setStatus:SPAudioEngineStatusPlaying error:nil];
            [self emitPlaybackState];
            if (completion) completion(nil);
        });
    };

    [_net fetchTrackCBCSManifestForURI:uri completion:^(NSDictionary *manifestEntry, NSError *manifestErr) {
        NSString *fileID = nil;
        NSInteger fileFmt = 0;
        if (manifestEntry && SPFairPlaySelectCBCSFile(manifestEntry, &fileID, &fileFmt)) {
            NSInteger durMs = SPJSONInt(SPJSONDict(SPJSONDict(manifestEntry[@"item"])[@"metadata"])[@"duration"], 0);
            resolveStream(fileID, fileFmt, nil, durMs);
            return;
        }
        // Fallback to metadata/4/track when track-playback/v1/media does not supply CBCS files.
        [self->_net fetchTrackMetadataWithID:trackID completion:^(NSDictionary *rawMeta, SPTrack *track, NSError *err) {
            NSString *fbID = nil;
            NSInteger fbFmt = 0;
            if (!err && rawMeta && SPFairPlaySelectCBCSFile(rawMeta, &fbID, &fbFmt)) {
                resolveStream(fbID, fbFmt, track, track ? track.durationMs : 0);
                return;
            }
            NSError *finalErr = manifestErr ?: err ?: [NSError errorWithDomain:kSPFairPlayErrorDomain code:7 userInfo:@{NSLocalizedDescriptionKey : @"Track has no MP4_*_CBCS FairPlay audio file"}];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self->_playGeneration != gen) return;
                [self setStatus:SPAudioEngineStatusFailed error:finalErr];
                if (completion) completion(finalErr);
            });
        }];
    }];
}

#pragma mark - Transport Controls

- (void)pause {
    if (_status != SPAudioEngineStatusPlaying) return;
    int64_t nowMs = (int64_t)llround(NSDate.date.timeIntervalSince1970 * 1000.0);
    if (_playbackState) _positionMs = [_playbackState interpolatedPositionMsAt:nowMs];
    _timestampMs = nowMs;
    [_player pause];
    [self setStatus:SPAudioEngineStatusPaused error:nil];
    [self emitPlaybackState];
}

- (void)resume {
    if (_currentIndex < 0 && _queue.count > 0) _currentIndex = 0;
    if (_currentIndex < 0) return;
    _timestampMs = (int64_t)llround(NSDate.date.timeIntervalSince1970 * 1000.0);
    [_player play];
    [self setStatus:SPAudioEngineStatusPlaying error:nil];
    [self emitPlaybackState];
}

- (void)togglePlayPause {
    if (_status == SPAudioEngineStatusPlaying) [self pause];
    else [self resume];
}

- (void)skipNext {
    if (_userQueued.count > 0) {
        NSString *nextURI = _userQueued.firstObject;
        [_userQueued removeObjectAtIndex:0];
        NSInteger insertAt = _currentIndex + 1;
        [_queue insertObject:nextURI atIndex:(NSUInteger)MIN(insertAt, (NSInteger)_queue.count)];
        _currentIndex = insertAt;
    } else if (_repeatMode == SPRepeatTrack && _currentIndex >= 0) {
        // Stay on same track and restart.
    } else if (_currentIndex + 1 < (NSInteger)_queue.count) {
        _currentIndex++;
    } else if (_repeatMode == SPRepeatContext && _queue.count > 0) {
        _currentIndex = 0;
    } else {
        [self pause];
        return;
    }
    _playGeneration++;
    [self loadAndPlayCurrentForGeneration:_playGeneration completion:nil];
}

- (void)skipPrevious {
    int64_t livePosMs = _positionMs;
    if (_player && _player.currentItem && CMTIME_IS_NUMERIC(_player.currentTime)) {
        double secs = CMTimeGetSeconds(_player.currentTime);
        if (isfinite(secs) && secs >= 0.0) livePosMs = (int64_t)llround(secs * 1000.0);
    } else if (_playbackState) {
        int64_t nowMs = (int64_t)llround(NSDate.date.timeIntervalSince1970 * 1000.0);
        livePosMs = [_playbackState interpolatedPositionMsAt:nowMs];
    }
    if (livePosMs > 3000) {
        [self seekToMs:0];
        return;
    }
    if (_currentIndex > 0) {
        _currentIndex--;
        _playGeneration++;
        [self loadAndPlayCurrentForGeneration:_playGeneration completion:nil];
    } else {
        [self seekToMs:0];
    }
}

- (void)seekToMs:(int64_t)positionMs {
    int64_t clamped = MAX(0, positionMs);
    if (_durationMs > 0 && clamped > _durationMs) clamped = _durationMs;
    _positionMs = clamped;
    _timestampMs = (int64_t)llround(NSDate.date.timeIntervalSince1970 * 1000.0);
    if (_player) {
        [_player seekToTime:CMTimeMake(clamped, 1000)];
    }
    [self emitPlaybackState];
}

- (void)setVolumePercent:(NSInteger)percent {
    _volumePercent = MIN(100, MAX(0, percent));
    if (_player) _player.volume = (float)_volumePercent / 100.0f;
}

- (void)setShuffle:(BOOL)enabled {
    if (_shuffling == enabled) return;
    _shuffling = enabled;
    NSString *currentURI = (_currentIndex >= 0 && _currentIndex < (NSInteger)_queue.count) ? _queue[(NSUInteger)_currentIndex] : nil;
    if (_originalQueue.count > 1) {
        if (enabled) {
            NSInteger curOrig = currentURI ? (NSInteger)[_originalQueue indexOfObject:currentURI] : -1;
            [_queue setArray:FisherYatesShuffledCopy(_originalQueue, curOrig)];
            if (currentURI) _currentIndex = 0;
        } else {
            [_queue setArray:_originalQueue];
            if (currentURI) {
                NSUInteger idx = [_queue indexOfObject:currentURI];
                _currentIndex = (idx != NSNotFound) ? (NSInteger)idx : 0;
            }
        }
    }
    [self emitPlaybackState];
}

- (void)setRepeatMode:(SPRepeatMode)mode {
    _repeatMode = mode;
    [self emitPlaybackState];
}

- (void)enqueueTrackURI:(NSString *)trackURI {
    if (!trackURI.length) return;
    [_userQueued addObject:trackURI];
    [self emitPlaybackState];
}

- (void)skipToQueueIndex:(NSInteger)queueIndex {
    if (queueIndex < 0) return;
    if (queueIndex < (NSInteger)_userQueued.count) {
        if (queueIndex > 0) {
            [_userQueued removeObjectsInRange:NSMakeRange(0, (NSUInteger)queueIndex)];
        }
        NSString *target = _userQueued.firstObject;
        [_userQueued removeObjectAtIndex:0];
        NSInteger insertAt = _currentIndex + 1;
        [_queue insertObject:target atIndex:(NSUInteger)MIN(insertAt, (NSInteger)_queue.count)];
        _currentIndex = insertAt;
    } else {
        NSInteger queueOffset = queueIndex - (NSInteger)_userQueued.count;
        NSInteger targetIdx = _currentIndex + 1 + queueOffset;
        if (targetIdx < 0 || targetIdx >= (NSInteger)_queue.count) return;
        [_userQueued removeAllObjects];
        _currentIndex = targetIdx;
    }
    _playGeneration++;
    [self loadAndPlayCurrentForGeneration:_playGeneration completion:nil];
}

#pragma mark - AVAssetResourceLoaderDelegate (In-Memory HLS)

- (BOOL)resourceLoader:(AVAssetResourceLoader *)resourceLoader
shouldWaitForLoadingOfRequestedResource:(AVAssetResourceLoadingRequest *)loadingRequest {
    NSURL *url = loadingRequest.request.URL;
    if (![url.scheme isEqualToString:@"sp-hls"]) return NO;
    NSString *fileID = [url.lastPathComponent stringByDeletingPathExtension];
    NSData *m3u8Data = _playlistsByFileID[fileID];
    if (!m3u8Data.length) {
        [loadingRequest finishLoadingWithError:[NSError errorWithDomain:kSPFairPlayErrorDomain code:404 userInfo:nil]];
        return YES;
    }
    if (loadingRequest.contentInformationRequest) {
        loadingRequest.contentInformationRequest.contentType = UTTypeM3UPlaylist.identifier;
        loadingRequest.contentInformationRequest.contentLength = (long long)m3u8Data.length;
        loadingRequest.contentInformationRequest.byteRangeAccessSupported = YES;
    }
    AVAssetResourceLoadingDataRequest *dr = loadingRequest.dataRequest;
    if (dr) {
        long long totalLen = (long long)m3u8Data.length;
        long long offset = dr.currentOffset > 0 ? dr.currentOffset : dr.requestedOffset;
        if (offset >= 0 && offset < totalLen) {
            NSUInteger available = (NSUInteger)(totalLen - offset);
            NSUInteger toSend = dr.requestsAllDataToEndOfResource
                ? available
                : MIN(available, (NSUInteger)MAX(0, dr.requestedLength));
            if (toSend > 0) {
                [dr respondWithData:[m3u8Data subdataWithRange:NSMakeRange((NSUInteger)offset, toSend)]];
            }
        }
    }
    [loadingRequest finishLoading];
    return YES;
}

#pragma mark - AVContentKeySessionDelegate (FairPlay SPC -> CKC)

- (void)exchangeSPC:(NSData *)spcData
      forKeyRequest:(AVContentKeyRequest *)keyRequest
         licenseURL:(NSString *)licURL
            retried:(BOOL)retried {
    [self->_net exchangeFairPlaySPC:spcData licenseURL:licURL completion:^(NSData *ckcData, NSHTTPURLResponse *resp, NSError *licErr) {
        if (!retried && resp && (resp.statusCode == 400 || resp.statusCode == 403)) {
            [self->_net fetchFairPlayLicenseURLWithCompletion:^(NSString *freshURL, NSError *refreshErr) {
                (void)refreshErr;
                NSString *retryURL = freshURL.length ? freshURL : licURL;
                self.cachedLicenseURL = retryURL;
                [self exchangeSPC:spcData forKeyRequest:keyRequest licenseURL:retryURL retried:YES];
            }];
            return;
        }
        if (licErr || !ckcData.length) {
            [keyRequest processContentKeyResponseError:licErr ?: [NSError errorWithDomain:kSPFairPlayErrorDomain code:10 userInfo:nil]];
            return;
        }
        AVContentKeyResponse *keyResp = [AVContentKeyResponse contentKeyResponseWithFairPlayStreamingKeyResponseData:ckcData];
        [keyRequest processContentKeyResponse:keyResp];
    }];
}

- (void)contentKeySession:(AVContentKeySession *)session didProvideContentKeyRequest:(AVContentKeyRequest *)keyRequest {
    NSData *cert = self.applicationCertificate;
    if (!cert.length) {
        [keyRequest processContentKeyResponseError:[NSError errorWithDomain:kSPFairPlayErrorDomain code:8 userInfo:@{NSLocalizedDescriptionKey : @"Missing FairPlay cert"}]];
        return;
    }
    NSString *ident = [keyRequest.identifier isKindOfClass:NSString.class] ? (NSString *)keyRequest.identifier : [keyRequest.identifier description];
    NSString *assetID = [ident hasPrefix:@"skd://"] ? [ident substringFromIndex:6] : ident;
    NSData *contentID = self.useUTF16LEAssetID
        ? [assetID dataUsingEncoding:NSUTF16LittleEndianStringEncoding]
        : [assetID dataUsingEncoding:NSUTF8StringEncoding];

    [keyRequest makeStreamingContentKeyRequestDataForApp:cert
                                       contentIdentifier:contentID
                                                 options:nil
                                       completionHandler:^(NSData *spcData, NSError *error) {
        if (error || !spcData.length) {
            [keyRequest processContentKeyResponseError:error ?: [NSError errorWithDomain:kSPFairPlayErrorDomain code:9 userInfo:nil]];
            return;
        }
        NSString *licURL = self.cachedLicenseURL ?: @"https://spclient.wg.spotify.com/fairplay-license/v1/audio/license";
        [self exchangeSPC:spcData forKeyRequest:keyRequest licenseURL:licURL retried:NO];
    }];
}

@end
