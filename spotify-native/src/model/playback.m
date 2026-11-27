// Immutable Spotify playback, queue, and Connect cluster models with protobuf decoders.
#import "model/playback.h"
#import "model/json.h"
#import "model/protobuf.h"

SPRepeatMode SPRepeatModeNext(SPRepeatMode mode) {
    switch (mode) {
        case SPRepeatOff: return SPRepeatContext;
        case SPRepeatContext: return SPRepeatTrack;
        case SPRepeatTrack: return SPRepeatOff;
    }
}

@implementation SPQueueTrack

- (instancetype)initWithURI:(NSString *)uri uid:(NSString *)uid provider:(NSString *)provider isHidden:(BOOL)isHidden {
    if (!(self = [super init])) return nil;
    _uri = [uri copy];
    _trackID = SPURIIDFromURIOfKind(uri, @"track");
    _uid = [uid copy];
    _provider = [provider copy];
    _isHidden = isHidden;
    _isDelimiter = [uri isEqualToString:@"spotify:delimiter"];
    return self;
}

- (id)copyWithZone:(NSZone *)zone { return self; }

+ (instancetype)queueTrackFromProtobufData:(NSData *)data {
    NSString *uri = @"";
    NSString *uid = @"";
    NSString *provider = @"";
    BOOL hidden = NO;
    for (SPProtobufField *f in SPProtobufReadFields(data)) {
        switch (f.number) {
            case 1: uri = f.stringValue; break;
            case 2: uid = f.stringValue; break;
            case 3: {
                NSString *k = @"", *v = @"";
                [f readMapEntryKey:&k value:&v];
                if ([k isEqualToString:@"hidden"] && [v isEqualToString:@"true"]) hidden = YES;
                break;
            }
            case 6: provider = f.stringValue; break;
            default: break;
        }
    }
    return [[self alloc] initWithURI:uri uid:uid provider:provider isHidden:hidden];
}

@end

@implementation SPPlaybackState

- (instancetype)initWithActiveDeviceID:(NSString *)activeDeviceID
                            contextURI:(NSString *)contextURI
                           contextName:(NSString *)contextName
                       currentTrackURI:(NSString *)currentTrackURI
                           timestampMs:(int64_t)timestampMs
               positionAsOfTimestampMs:(int64_t)positionAsOfTimestampMs
                            durationMs:(int64_t)durationMs
                             isPlaying:(BOOL)isPlaying
                              isPaused:(BOOL)isPaused
                             shuffling:(BOOL)shuffling
                            repeatMode:(SPRepeatMode)repeatMode
                           canSkipNext:(BOOL)canSkipNext
                            canShuffle:(BOOL)canShuffle
                      canRepeatContext:(BOOL)canRepeatContext
                        canRepeatTrack:(BOOL)canRepeatTrack
                            prevTracks:(NSArray<SPQueueTrack *> *)prevTracks
                            nextTracks:(NSArray<SPQueueTrack *> *)nextTracks {
    if (!(self = [super init])) return nil;
    _activeDeviceID = [activeDeviceID copy];
    _contextURI = [contextURI copy];
    _contextName = [contextName copy];
    _currentTrackURI = [currentTrackURI copy];
    _currentTrackID = SPURIIDFromURIOfKind(currentTrackURI, @"track") ?: SPURIIDFromURI(currentTrackURI);
    _timestampMs = timestampMs;
    _positionAsOfTimestampMs = positionAsOfTimestampMs;
    _durationMs = durationMs;
    _isPlaying = isPlaying;
    _isPaused = isPaused;
    _shuffling = shuffling;
    _repeatMode = repeatMode;
    _canSkipNext = canSkipNext;
    _canShuffle = canShuffle;
    _canRepeatContext = canRepeatContext;
    _canRepeatTrack = canRepeatTrack;
    _prevTracks = [prevTracks copy];
    _nextTracks = [nextTracks copy];
    return self;
}

- (id)copyWithZone:(NSZone *)zone { return self; }

- (int64_t)interpolatedPositionMsAt:(int64_t)nowMs {
    int64_t pos = _positionAsOfTimestampMs;
    if (_isPlaying && !_isPaused && _timestampMs > 0 && nowMs > _timestampMs) {
        pos += (nowMs - _timestampMs);
    }
    if (pos < 0) pos = 0;
    if (_durationMs > 0 && pos > _durationMs) pos = _durationMs;
    return pos;
}

+ (instancetype)playbackStateFromProtobufData:(NSData *)data activeDeviceID:(NSString *)activeDeviceID {
    int64_t timestamp = 0;
    NSString *contextURI = nil;
    NSString *contextName = nil;
    NSString *trackURI = nil;
    int64_t pos = 0;
    int64_t duration = 0;
    BOOL isPlaying = NO;
    BOOL isPaused = NO;
    BOOL shuffling = NO;
    BOOL repeatingContext = NO;
    BOOL repeatingTrack = NO;
    BOOL canSkipNext = YES;
    BOOL canShuffle = YES;
    BOOL canRepeatContext = YES;
    BOOL canRepeatTrack = YES;
    NSMutableArray<SPQueueTrack *> *prevTracks = [NSMutableArray new];
    NSMutableArray<SPQueueTrack *> *nextTracks = [NSMutableArray new];

    for (SPProtobufField *f in SPProtobufReadFields(data)) {
        switch (f.number) {
            case 1: timestamp = f.int64Value; break;
            case 2:
                if (f.stringValue.length) contextURI = f.stringValue;
                break;
            case 7: {
                SPQueueTrack *t = [SPQueueTrack queueTrackFromProtobufData:f.bytesValue];
                if (t.uri.length) trackURI = t.uri;
                break;
            }
            case 10: pos = f.int64Value; break;
            case 11: duration = f.int64Value; break;
            case 12: isPlaying = f.boolValue; break;
            case 13: isPaused = f.boolValue; break;
            case 16: {
                for (SPProtobufField *opt in [f nestedFields]) {
                    if (opt.number == 1) shuffling = opt.boolValue;
                    else if (opt.number == 2) repeatingContext = opt.boolValue;
                    else if (opt.number == 3) repeatingTrack = opt.boolValue;
                }
                break;
            }
            case 17: {
                for (SPProtobufField *r in [f nestedFields]) {
                    if (r.number == 7 && r.stringValue.length) canSkipNext = NO;
                    else if (r.number == 8 && r.stringValue.length) canRepeatContext = NO;
                    else if (r.number == 9 && r.stringValue.length) canRepeatTrack = NO;
                    else if (r.number == 10 && r.stringValue.length) canShuffle = NO;
                }
                break;
            }
            case 19: [prevTracks addObject:[SPQueueTrack queueTrackFromProtobufData:f.bytesValue]]; break;
            case 20: [nextTracks addObject:[SPQueueTrack queueTrackFromProtobufData:f.bytesValue]]; break;
            case 21: {
                NSString *k = @"", *v = @"";
                [f readMapEntryKey:&k value:&v];
                if ([k isEqualToString:@"context_description"] && v.length) contextName = v;
                break;
            }
            default: break;
        }
    }

    SPRepeatMode repeatMode = repeatingTrack ? SPRepeatTrack : (repeatingContext ? SPRepeatContext : SPRepeatOff);
    return [[self alloc] initWithActiveDeviceID:activeDeviceID
                                     contextURI:contextURI
                                    contextName:contextName
                                currentTrackURI:trackURI
                                    timestampMs:timestamp
                        positionAsOfTimestampMs:pos
                                     durationMs:duration
                                      isPlaying:isPlaying && !isPaused
                                       isPaused:isPaused
                                      shuffling:shuffling
                                     repeatMode:repeatMode
                                    canSkipNext:canSkipNext
                                     canShuffle:canShuffle
                               canRepeatContext:canRepeatContext
                                 canRepeatTrack:canRepeatTrack
                                     prevTracks:prevTracks
                                     nextTracks:nextTracks];
}

@end

@implementation SPClusterState

- (instancetype)initWithActiveDeviceID:(NSString *)activeDeviceID
                            allDevices:(NSArray<SPDevice *> *)allDevices
                         playbackState:(SPPlaybackState *)playbackState {
    if (!(self = [super init])) return nil;
    _activeDeviceID = activeDeviceID.length ? [activeDeviceID copy] : nil;
    _allDevices = [allDevices copy];
    NSMutableArray<SPDevice *> *visible = [NSMutableArray arrayWithCapacity:allDevices.count];
    for (SPDevice *d in allDevices) {
        if (!d.isHidden) [visible addObject:d];
    }
    _devices = [visible copy];
    _playbackState = playbackState;
    return self;
}

+ (instancetype)clusterFromProtobufData:(NSData *)data {
    NSString *activeDeviceID = nil;
    NSData *playerStateBytes = nil;
    NSMutableArray<NSArray *> *rawDevices = [NSMutableArray new];

    for (SPProtobufField *f in SPProtobufReadFields(data)) {
        switch (f.number) {
            case 2:
                if (f.stringValue.length) activeDeviceID = f.stringValue;
                break;
            case 3: playerStateBytes = f.bytesValue; break;
            case 4: {
                NSArray<SPProtobufField *> *entry = [f nestedFields];
                SPProtobufField *k = SPProtobufLastField(entry, 1);
                SPProtobufField *v = SPProtobufLastField(entry, 2);
                [rawDevices addObject:@[ k ? k.stringValue : @"", v ? v.bytesValue : [NSData data] ]];
                break;
            }
            default: break;
        }
    }

    NSMutableArray<SPDevice *> *devices = [NSMutableArray arrayWithCapacity:rawDevices.count];
    for (NSArray *pair in rawDevices) {
        SPDevice *dev = [SPDevice deviceFromConnectInfoData:pair[1]
                                           fallbackDeviceID:pair[0]
                                             activeDeviceID:activeDeviceID];
        [devices addObject:dev];
    }
    [devices sortUsingComparator:^NSComparisonResult(SPDevice *a, SPDevice *b) {
        return [a.deviceID compare:b.deviceID];
    }];

    SPPlaybackState *ps = playerStateBytes.length
        ? [SPPlaybackState playbackStateFromProtobufData:playerStateBytes activeDeviceID:activeDeviceID]
        : nil;
    return [[self alloc] initWithActiveDeviceID:activeDeviceID allDevices:devices playbackState:ps];
}

+ (instancetype)clusterUpdateFromProtobufData:(NSData *)data {
    NSData *clusterBytes = SPProtobufFirstBytes(data, 1);
    return [self clusterFromProtobufData:clusterBytes ?: [NSData data]];
}

@end
