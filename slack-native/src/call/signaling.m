// Owns the Chime signalling connection: the websocket, JOIN until the first INDEX, SUBSCRIBE until
// its answer, pings, the attendees' audio state and LEAVE.
#import "call/frames.h"
#import "call/signaling.h"
#import "net/switches.h"

NSErrorDomain const SNChimeErrorDomain = @"SNChimeErrorDomain";

@implementation SNChimeTURN
@end

@implementation SNChimeAttendee
@end

NSURL *SNChimeSignalingURL(NSURL *signalingURL) {
    NSURLComponents *components = [NSURLComponents componentsWithURL:signalingURL resolvingAgainstBaseURL:NO];
    NSMutableArray<NSURLQueryItem *> *items = [components.queryItems mutableCopy] ?: [NSMutableArray new];
    // The last two are the SDK's version and a browser name-major; the browser is the one the
    // client details name (frames.m).
    [items addObjectsFromArray:@[ [NSURLQueryItem queryItemWithName:@"X-Chime-Control-Protocol-Version" value:@"3"],
                                  [NSURLQueryItem queryItemWithName:@"X-Amzn-Chime-Send-Close-On-Error" value:@"1"],
                                  [NSURLQueryItem queryItemWithName:@"X-Amzn-Version" value:@"3.32.0"],
                                  [NSURLQueryItem queryItemWithName:@"X-Amzn-User-Agent" value:@"chrome-158"] ]];
    components.queryItems = items;
    return components.URL;
}

static uint64_t Now(void) { return (uint64_t)(NSDate.date.timeIntervalSince1970 * 1000); }

static SNChimeAttendee *Snapshot(SNChimeAttendee *attendee) {
    SNChimeAttendee *copy = [SNChimeAttendee new];
    copy.attendeeID = attendee.attendeeID;
    copy.externalUserID = attendee.externalUserID;
    copy.volume = attendee.volume;
    copy.signalStrength = attendee.signalStrength;
    copy.muted = attendee.muted;
    copy.gone = attendee.gone;
    return copy;
}

@implementation SNChimeSignaling {
    NSURL *_url;
    NSString *_joinToken;
    NSURLSession *_urlSession;
    NSURLSessionWebSocketTask *_task;
    /// Bumped for every socket, so callbacks of an old one are dropped.
    NSUInteger _generation;
    uint32_t _audioSessionID;
    SNChimeTURN *_turn;
    BOOL _joined, _leaving, _left, _acknowledged;
    NSTimer *_pingTimer, *_leaveTimer;
    uint32_t _pingID;
    NSInteger _unansweredPings;
    NSMutableArray<void (^)(BOOL)> *_leaveCompletions;
    /// Audio stream ID -> attendee ID, and the attendees heard of, by attendee ID.
    NSMutableDictionary<NSNumber *, NSString *> *_streamAttendees;
    NSMutableDictionary<NSString *, SNChimeAttendee *> *_attendees;
}

- (instancetype)initWithURL:(NSURL *)url joinToken:(NSString *)joinToken urlSession:(NSURLSession *)urlSession {
    if (!(self = [super init])) return nil;
    _url = url;
    _joinToken = [joinToken copy];
    _urlSession = urlSession;
    _pingInterval = 10;
    _audioSessionID = arc4random();
    _leaveCompletions = [NSMutableArray new];
    _streamAttendees = [NSMutableDictionary new];
    _attendees = [NSMutableDictionary new];
    return self;
}

- (void)dealloc {
    [_pingTimer invalidate];
    [_leaveTimer invalidate];
    [_task cancelWithCloseCode:NSURLSessionWebSocketCloseCodeGoingAway reason:nil];
}

#pragma mark The socket

- (void)open {
    NSUInteger generation = ++_generation;
    _task = [_urlSession webSocketTaskWithURL:SNChimeSignalingURL(_url) protocols:@[ @"_aws_wt_session", _joinToken ]];
    [_task resume];
    [self receive:_task generation:generation];
}

- (void)receive:(NSURLSessionWebSocketTask *)task generation:(NSUInteger)generation {
    __weak SNChimeSignaling *weakSelf = self;
    [task receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *message, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            SNChimeSignaling *signaling = weakSelf;
            if (!signaling || signaling->_generation != generation) return;
            if (error || !message) return [signaling socketEnded:task];
            if (message.type == NSURLSessionWebSocketMessageTypeData) [signaling received:message.data];
            if (signaling->_generation == generation) [signaling receive:task generation:generation];
        });
    }];
}

- (void)send:(NSData *)message type:(SNChimeFrameType)type {
    if (!_task) return;
    SNTrace([@"chime:" stringByAppendingString:SNChimeFrameName(type)], 0, @"sent", -1, message.length);
    [_task sendMessage:[[NSURLSessionWebSocketMessage alloc] initWithData:message] completionHandler:^(NSError *error) {}];
}

/// Closes the socket from this side; nothing more is reported from it.
- (void)closeSocket {
    _generation++;
    [_pingTimer invalidate];
    _pingTimer = nil;
    [_task cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];
    _task = nil;
}

- (void)socketEnded:(NSURLSessionWebSocketTask *)task {
    NSInteger code = task.closeCode;
    SNTrace(@"chime:close", code, _leaving ? @"leaving" : @"closed", -1, 0);
    if (_leaving) return [self finishLeave:NO];
    [self failWithCode:code > 0 ? code : SNChimeErrorDropped description:nil];
}

- (void)failWithCode:(NSInteger)code description:(NSString *)description {
    [self closeSocket];
    NSError *error = [NSError errorWithDomain:SNChimeErrorDomain code:code userInfo:description.length ? @{NSLocalizedDescriptionKey : description} : nil];
    if (self.onClose) self.onClose(error);
}

#pragma mark Joining

- (void)start {
    if (_task || _leaving || _left) return;
    [self open];
    [self send:SNChimeJoinMessage(Now(), _audioSessionID, SNChimeClientDetails.current) type:SNChimeFrameJoin];
    // The SDK pings as soon as the socket opens, then every interval.
    __weak SNChimeSignaling *weakSelf = self;
    _pingTimer = [NSTimer timerWithTimeInterval:self.pingInterval repeats:YES block:^(NSTimer *timer) { [weakSelf ping]; }];
    [NSRunLoop.mainRunLoop addTimer:_pingTimer forMode:NSRunLoopCommonModes];
    [self ping];
}

- (void)ping {
    if (_unansweredPings >= SNChimeMissedPongLimit) return [self failWithCode:SNChimeErrorNoPongs description:nil];
    _unansweredPings++;
    _pingID++;
    [self send:SNChimePingPongMessage(Now(), _pingID, NO) type:SNChimeFramePingPong];
}

- (void)subscribeWithOffer:(NSString *)sdp audioHost:(NSString *)audioHost muted:(BOOL)muted {
    if (_leaving || _left) return;
    [self send:SNChimeSubscribeMessage(Now(), sdp, audioHost, self.attendeeID ?: @"", muted) type:SNChimeFrameSubscribe];
}

- (void)setMuted:(BOOL)muted {
    if (_leaving || _left) return;
    [self send:SNChimeAudioControlMessage(Now(), muted) type:SNChimeFrameAudioControl];
}

#pragma mark Frames

- (void)received:(NSData *)message {
    SNChimeFrame *frame = [SNChimeFrame frameWithMessage:message];
    // Volume levels come several times a second; the trace keeps the rest.
    if (SNTracing() && frame.type != SNChimeFrameAudioMetadata) {
        NSInteger status = frame.errorStatus ?: frame.audioStatus;
        SNTrace([@"chime:" stringByAppendingString:frame ? SNChimeFrameName(frame.type) : @"undecodable"], status, frame.notification ?: @"ok", -1, message.length);
    }
    // Like the SDK, a frame that does not decode is skipped.
    if (!frame) return;
    if (_leaving) {
        if (frame.type == SNChimeFrameLeaveAck) [self finishLeave:YES];
        return;
    }
    if (frame.errorStatus && frame.errorStatus / 100 != 2) return [self failWithCode:frame.errorStatus description:frame.errorDescription];
    switch (frame.type) {
        case SNChimeFrameJoinAck:
            _turn = frame.turn;
            break;
        case SNChimeFrameIndex:
            if (_joined) break;
            _joined = YES;
            if (self.onJoined) self.onJoined(_turn);
            break;
        case SNChimeFrameSubscribeAck:
            if (!frame.sdpAnswer.length) return [self failWithCode:SNChimeErrorProtocol description:frame.compressedAnswer ? @"compressed answer" : @"no answer"];
            if (self.onAnswer) self.onAnswer(frame.sdpAnswer);
            break;
        case SNChimeFramePingPong:
            if (!frame.isPong) [self send:SNChimePingPongMessage(Now(), frame.pingID, YES) type:SNChimeFramePingPong];
            else if (frame.pingID == _pingID) _unansweredPings = 0;
            break;
        case SNChimeFrameAudioStatus:
            // 0 too: the SDK counts an AUDIO_STATUS without a 2xx status as audio lost.
            if (frame.audioStatus / 100 != 2) return [self failWithCode:frame.audioStatus description:nil];
            break;
        case SNChimeFrameAudioStreamIDInfo: [self applyStreams:frame.streams]; break;
        case SNChimeFrameAudioMetadata: [self applyLevels:frame.levels]; break;
        default: break;
    }
}

#pragma mark Attendees

/// AUDIO_STREAM_ID_INFO as the SDK's volume indicator adapter reads it: an entry with an attendee
/// names a stream (a newer stream of the same attendee replaces the older), one with only
/// "muted" changes the stream's attendee, and one with neither removes the stream; the attendee
/// is gone once no stream of theirs is left.
- (void)applyStreams:(NSArray<SNChimeStreamInfo *> *)streams {
    NSMutableArray<SNChimeAttendee *> *changed = [NSMutableArray new];
    for (SNChimeStreamInfo *info in streams) {
        NSNumber *stream = @(info.audioStreamID);
        if (info.attendeeID) {
            _streamAttendees[stream] = info.attendeeID;
            SNChimeAttendee *attendee = _attendees[info.attendeeID];
            if (!attendee) {
                attendee = [SNChimeAttendee new];
                attendee.attendeeID = info.attendeeID;
                attendee.signalStrength = 1;
                _attendees[info.attendeeID] = attendee;
            }
            attendee.externalUserID = info.externalUserID ?: info.attendeeID;
            attendee.gone = NO;
            if (info.hasMuted) attendee.muted = info.muted;
            [changed addObject:Snapshot(attendee)];
        } else if (info.hasMuted) {
            SNChimeAttendee *attendee = _attendees[_streamAttendees[stream] ?: @""];
            if (!attendee) continue;
            attendee.muted = info.muted;
            [changed addObject:Snapshot(attendee)];
        } else {
            NSString *attendeeID = _streamAttendees[stream];
            if (!attendeeID) continue;
            [_streamAttendees removeObjectForKey:stream];
            if ([_streamAttendees.allValues containsObject:attendeeID]) continue;
            SNChimeAttendee *attendee = _attendees[attendeeID];
            [_attendees removeObjectForKey:attendeeID];
            attendee.gone = YES;
            if (attendee) [changed addObject:Snapshot(attendee)];
        }
    }
    if (changed.count && self.onAttendees) self.onAttendees(changed);
}

/// AUDIO_METADATA: a frame with any volume (or signal strength) gives every known attendee it
/// leaves out a volume of 0 (a full signal), as the SDK does.
- (void)applyLevels:(NSArray<SNChimeAudioLevel *> *)levels {
    NSMutableDictionary<NSString *, NSNumber *> *volumes, *signals;
    for (SNChimeAudioLevel *level in levels) {
        NSString *attendeeID = level.audioStreamID ? _streamAttendees[@(level.audioStreamID)] : nil;
        if (level.hasVolume) {
            volumes = volumes ?: [NSMutableDictionary new];
            if (attendeeID) volumes[attendeeID] = @(SNChimeNormalizedVolume(level.volume));
        }
        if (level.hasSignalStrength) {
            signals = signals ?: [NSMutableDictionary new];
            if (attendeeID) signals[attendeeID] = @(MIN(MAX(level.signalStrength / 2.0, 0), 1));
        }
    }
    NSMutableArray<SNChimeAttendee *> *changed = [NSMutableArray new];
    for (NSString *attendeeID in [NSSet setWithArray:_streamAttendees.allValues]) {
        SNChimeAttendee *attendee = _attendees[attendeeID];
        double volume = volumes ? [volumes[attendeeID] ?: @0 doubleValue] : attendee.volume;
        double signal = signals ? [signals[attendeeID] ?: @1 doubleValue] : attendee.signalStrength;
        if (volume == attendee.volume && signal == attendee.signalStrength) continue;
        attendee.volume = volume;
        attendee.signalStrength = signal;
        [changed addObject:Snapshot(attendee)];
    }
    if (changed.count && self.onAttendees) self.onAttendees(changed);
}

#pragma mark Leaving

- (void)leaveWithin:(NSTimeInterval)timeout completion:(void (^)(BOOL))completion {
    if (_left) {
        if (completion) completion(_acknowledged);
        return;
    }
    if (completion) [_leaveCompletions addObject:[completion copy]];
    if (_leaving) return;
    _leaving = YES;
    [_pingTimer invalidate];
    _pingTimer = nil;
    // A socket that never opened or already failed: a new one carries the leave.
    if (!_task) [self open];
    [self send:SNChimeLeaveMessage(Now()) type:SNChimeFrameLeave];
    __weak SNChimeSignaling *weakSelf = self;
    _leaveTimer = [NSTimer timerWithTimeInterval:timeout repeats:NO block:^(NSTimer *timer) { [weakSelf finishLeave:NO]; }];
    [NSRunLoop.mainRunLoop addTimer:_leaveTimer forMode:NSRunLoopCommonModes];
}

- (void)finishLeave:(BOOL)acknowledged {
    if (_left) return;
    _left = YES;
    _leaving = NO;
    _acknowledged = acknowledged;
    [_leaveTimer invalidate];
    _leaveTimer = nil;
    [self closeSocket];
    NSArray *completions = _leaveCompletions;
    _leaveCompletions = [NSMutableArray new];
    for (void (^completion)(BOOL) in completions) completion(acknowledged);
}

@end
