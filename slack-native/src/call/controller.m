// Owns the user's call: rooms.join, the Chime signalling and the media wired together, who is
// heard, and both leaves on every way out, including the next launch after a crash.
#import "call/controller.h"
#import "call/signaling.h"
#import "model/json.h"
#import "source/source.h"
#import "net/switches.h"

/// Slack's speaking indicator (PeerVoiceLevelLimiter): heard from 0.15 of Chime's normalized
/// volume until 500 ms below it.
static const double SNSpeakingVolume = 0.15;
static const NSTimeInterval SNSpeakingHold = 0.5;

/// Slack's ChimeRegionProvider keeps the nearest region for 72 hours.
static const NSTimeInterval SNRegionLifetime = 72 * 3600;
static NSString *const SNRegionDefaultsKey = @"ChimeRegionCache";
/// The profile's "in a huddle" lasts 300 s past each refresh (Slack's
/// incrementHuddleStateExpiration).
static const NSTimeInterval SNHuddleStateLifetime = 300;

/// A key of Chime's CreateMeeting/CreateAttendee output, whose case its SDK ignores.
static id SNChimeValue(id object, NSString *key) {
    if (![object isKindOfClass:NSDictionary.class]) return nil;
    for (NSString *candidate in object)
        if ([candidate isKindOfClass:NSString.class] && [candidate caseInsensitiveCompare:key] == NSOrderedSame) return object[candidate];
    return nil;
}

static NSString *SNChimeString(id object, NSString *key) {
    id value = SNChimeValue(object, key);
    return [value isKindOfClass:NSString.class] && [value length] ? value : nil;
}

/// The Slack user behind an attendee: Chime's ExternalUserId is "<team>-<call>-<user>" with an
/// optional fourth part, as Slack's getUserIdFromExternalId reads it. Content shares
/// ("<attendee>#content") are not people.
static NSString *SNUserOfAttendee(SNChimeAttendee *attendee) {
    if ([attendee.attendeeID containsString:@"#"]) return nil;
    NSArray<NSString *> *parts = [attendee.externalUserID ?: @"" componentsSeparatedByString:@"-"];
    return parts.count == 3 || parts.count == 4 ? parts[2] : nil;
}

/// What rooms.join gave: the room and what Chime needs.
@interface SNCallCredentials : NSObject
@property (nonatomic, copy) NSString *conversationID, *callID, *attendeeID;
@property (nonatomic, copy, nullable) NSString *signalingURL, *audioHost, *joinToken;
@end

@implementation SNCallCredentials

+ (instancetype)credentialsWithResponse:(NSDictionary *)response conversationID:(NSString *)conversationID {
    NSDictionary *call = SNJSONObject(response, @"call");
    NSDictionary *willy = SNJSONObject(call, @"free_willy");
    id meeting = SNChimeValue(willy, @"meeting"), attendee = SNChimeValue(willy, @"attendee");
    meeting = SNChimeValue(meeting, @"Meeting") ?: meeting;
    attendee = SNChimeValue(attendee, @"Attendee") ?: attendee;
    NSString *callID = SNJSONString(call, @"call_id"), *attendeeID = SNChimeString(attendee, @"AttendeeId");
    if (!callID.length || !attendeeID) return nil;
    SNCallCredentials *credentials = [self new];
    credentials.conversationID = conversationID;
    credentials.callID = callID;
    credentials.attendeeID = attendeeID;
    id placement = SNChimeValue(meeting, @"MediaPlacement");
    credentials.signalingURL = SNChimeString(placement, @"SignalingUrl");
    credentials.audioHost = SNChimeString(placement, @"AudioHostUrl");
    credentials.joinToken = SNChimeString(attendee, @"JoinToken");
    return credentials;
}

+ (instancetype)credentialsWithRecord:(NSDictionary *)record {
    NSString *conversationID = SNJSONString(record, @"channel_id"), *callID = SNJSONString(record, @"call_id"), *attendeeID = SNJSONString(record, @"attendee_id");
    if (!conversationID.length || !callID.length || !attendeeID.length) return nil;
    SNCallCredentials *credentials = [self new];
    credentials.conversationID = conversationID;
    credentials.callID = callID;
    credentials.attendeeID = attendeeID;
    credentials.signalingURL = SNJSONString(record, @"signaling_url");
    credentials.joinToken = SNJSONString(record, @"join_token");
    return credentials;
}

/// What the recovery file holds.
- (NSDictionary *)record {
    NSMutableDictionary *record = [@{@"channel_id" : self.conversationID, @"call_id" : self.callID, @"attendee_id" : self.attendeeID} mutableCopy];
    if (self.signalingURL && self.joinToken) [record addEntriesFromDictionary:@{@"signaling_url" : self.signalingURL, @"join_token" : self.joinToken}];
    return record;
}

- (BOOL)reachesChime { return self.signalingURL && self.audioHost && self.joinToken && [NSURL URLWithString:self.signalingURL]; }

@end

@implementation SNCallController {
    id<SNAPI> _api;
    NSURLSession *_urlSession;
    NSString *_userID;
    NSURL *_recoveryFile;
    /// Bumped when a call ends: callbacks of an earlier one are dropped.
    NSUInteger _epoch;
    /// The call under way; nil when there is none.
    NSString *_conversationID;
    /// The huddle joined, as the source knew it, or the one a start made once rooms.join named it;
    /// whether the source has shown it going on (until then a start has nothing to follow).
    NSString *_joinedHuddleID;
    BOOL _huddleSeen;
    /// The nearest region while this launch knows it; the lookup in flight's waiters.
    NSString *_region;
    NSMutableArray<void (^)(NSString *)> *_regionWaiters;
    NSTimer *_statusTimer;
    SNCallCredentials *_credentials;
    SNCallState _state;
    BOOL _muted, _joinOut, _subscribed, _leaving, _signalingLeaving, _roomLeaving;
    NSString *_leaveReason;
    SNChimeSignaling *_signaling;
    SNCallMedia *_media;
    NSMutableDictionary<NSString *, SNChimeAttendee *> *_attendees;
    /// Attendee ID -> when they were last heard over SNSpeakingVolume.
    NSMutableDictionary<NSString *, NSDate *> *_heard;
    NSSet<NSString *> *_speaking, *_mutedUsers;
    NSTimer *_speakingTimer;
    NSMutableArray<dispatch_block_t> *_leaveCompletions;
    /// The join or start waiting for the current call to be over.
    dispatch_block_t _nextJoin;
    /// What the recovery file held at launch (a call joined since writes over the file), until
    /// recover sends its leaves; and the signalling connections sending them.
    SNCallCredentials *_stale;
    NSMutableSet<SNChimeSignaling *> *_recovering;
}

- (instancetype)initWithAPI:(id<SNAPI>)api urlSession:(NSURLSession *)urlSession userID:(NSString *)userID recoveryFile:(NSURL *)recoveryFile {
    if (!(self = [super init])) return nil;
    _api = api;
    _urlSession = urlSession;
    _userID = [userID copy];
    _recoveryFile = [recoveryFile copy];
    _joinTimeout = 60;
    _leaveTimeout = 2;
    _statusInterval = 240;
    _regionURL = [NSURL URLWithString:@"https://nearest-media-region.l.chime.aws"];
    _regionWaiters = [NSMutableArray new];
    _attendees = [NSMutableDictionary new];
    _heard = [NSMutableDictionary new];
    _speaking = _mutedUsers = [NSSet set];
    _leaveCompletions = [NSMutableArray new];
    _recovering = [NSMutableSet new];
    NSDictionary *record = self.readRecord;
    _stale = record ? [SNCallCredentials credentialsWithRecord:record] : nil;
    // Unreadable: nothing could leave it.
    if (record && !_stale) [NSFileManager.defaultManager removeItemAtURL:_recoveryFile error:nil];
    return self;
}

#pragma mark Joining

- (void)joinHuddle:(SNHuddle *)huddle inConversation:(NSString *)conversationID {
    [self beginCallIn:conversationID huddle:huddle muted:YES];
}

- (void)startHuddleInConversation:(NSString *)conversationID muted:(BOOL)muted {
    [self beginCallIn:conversationID huddle:nil muted:muted];
}

/// Joins `huddle`, or starts one in the conversation when it is nil.
- (void)beginCallIn:(NSString *)conversationID huddle:(SNHuddle *)huddle muted:(BOOL)muted {
    if (_conversationID) {
        if (!_leaving && [_conversationID isEqualToString:conversationID]) return;
        __weak SNCallController *weakSelf = self;
        _nextJoin = ^{ [weakSelf beginCallIn:conversationID huddle:huddle muted:muted]; };
        [self leaveBecause:@"user_initiated" within:self.leaveTimeout completion:nil];
        return;
    }
    if (!self.makeMedia) return;
    NSUInteger epoch = _epoch;
    _conversationID = [conversationID copy];
    _joinedHuddleID = huddle.identifier;
    _huddleSeen = huddle != nil;
    _state = SNCallJoining;
    _muted = muted;
    _mutedUsers = muted ? [NSSet setWithObject:_userID] : [NSSet set];
    [self changed];
    __weak SNCallController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(self.joinTimeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SNCallController *controller = weakSelf;
        if (!controller || controller->_epoch != epoch || controller->_state != SNCallJoining || controller->_leaving) return;
        SNTrace(@"call.join", 0, @"timeout", -1, 0);
        [controller leaveBecause:nil within:controller.leaveTimeout completion:nil];
    });
    // Slack's client asks Chime for the nearest region only to start a huddle (fetchCredentials'
    // shouldFetchRegion): one going on already has its region, and naming another can be refused.
    if (huddle) return [self askToJoin:conversationID regions:@"" epoch:epoch];
    [self nearestRegion:^(NSString *region) {
        SNCallController *controller = weakSelf;
        if (controller && controller->_epoch == epoch && !controller->_leaving) [controller askToJoin:conversationID regions:region epoch:epoch];
    }];
}

- (void)askToJoin:(NSString *)conversationID regions:(NSString *)regions epoch:(NSUInteger)epoch {
    NSDictionary *params = @{@"channel_id" : conversationID, @"regions" : regions, @"multidevice" : @"false", @"_x_reason" : @"calls-api/joinRoom"};
    _joinOut = YES;
    NSDate *asked = NSDate.date;
    __weak SNCallController *weakSelf = self;
    [_api call:@"rooms.join" params:params priority:SNCallUserFacing completion:^(NSDictionary *response, NSError *error) {
        SNCallController *controller = weakSelf;
        SNCallCredentials *credentials = response ? [SNCallCredentials credentialsWithResponse:response conversationID:conversationID] : nil;
        SNTrace(@"call.rooms.join", 0, error ? SNAPIErrorName(error) ?: @"failed" : credentials ? @"ok" : @"create_meeting_failed", -asked.timeIntervalSinceNow * 1000, 0);
        if (!controller) return;
        if (controller->_epoch != epoch) {
            // The call gave up waiting for this answer: what it joined is left at once.
            if (credentials) [controller sendRoomLeave:credentials reason:nil completion:nil];
            return;
        }
        [controller joinAnswered:credentials];
    }];
}

#pragma mark The nearest region

/// Chime's nearest media region as Slack's ChimeRegionProvider keeps it: from this launch, else
/// the defaults while under 72 hours old, else asked (an unanswered lookup gives "", which
/// rooms.join takes as no preference).
- (void)nearestRegion:(void (^)(NSString *region))completion {
    if (!_region) {
        NSDictionary *cached = [self.regionDefaults dictionaryForKey:SNRegionDefaultsKey];
        NSString *region = SNJSONString(cached, @"region");
        if (region.length && NSDate.date.timeIntervalSince1970 - SNJSONDouble(cached, @"timestamp") < SNRegionLifetime) _region = region;
    }
    if (_region) return completion(_region);
    [_regionWaiters addObject:[completion copy]];
    if (_regionWaiters.count > 1) return;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:self.regionURL];
    request.timeoutInterval = 5;
    NSDate *asked = NSDate.date;
    __weak SNCallController *weakSelf = self;
    [[_urlSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSString *region = SNJSONString(json, @"region") ?: @"";
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        dispatch_async(dispatch_get_main_queue(), ^{
            SNTrace(@"call.region", status, region.length ? @"ok" : @"failed", -asked.timeIntervalSinceNow * 1000, data.length);
            [weakSelf regionArrived:region];
        });
    }] resume];
}

- (void)regionArrived:(NSString *)region {
    if (region.length) {
        _region = region;
        [self.regionDefaults setObject:@{@"region" : region, @"timestamp" : @(NSDate.date.timeIntervalSince1970)} forKey:SNRegionDefaultsKey];
    }
    NSArray<void (^)(NSString *)> *waiters = _regionWaiters;
    _regionWaiters = [NSMutableArray new];
    for (void (^waiter)(NSString *) in waiters) waiter(region);
}

- (void)prefetchRegion {
    [self nearestRegion:^(NSString *region) {}];
}

- (void)joinAnswered:(SNCallCredentials *)credentials {
    _joinOut = NO;
    if (credentials) {
        _credentials = credentials;
        _joinedHuddleID = _joinedHuddleID ?: credentials.callID;
        [self keepRecord:credentials];
    }
    if (_leaving) {
        if (credentials) [self leaveRoom];
        else [self roomLeft];
        return;
    }
    if (!credentials.reachesChime) {
        [self leaveBecause:nil within:self.leaveTimeout completion:nil];
        return;
    }
    [self changed];
    NSUInteger epoch = _epoch;
    __weak SNCallController *weakSelf = self;
    _signaling = [[SNChimeSignaling alloc] initWithURL:[NSURL URLWithString:SNSlackPortURL(credentials.signalingURL)] joinToken:credentials.joinToken urlSession:_urlSession];
    _signaling.attendeeID = credentials.attendeeID;
    _signaling.onJoined = ^(SNChimeTURN *turn) {
        SNCallController *controller = weakSelf;
        if (controller && controller->_epoch == epoch && !controller->_leaving) [controller signalingJoined:turn];
    };
    _signaling.onAnswer = ^(NSString *sdp) {
        SNCallController *controller = weakSelf;
        if (controller && controller->_epoch == epoch && !controller->_leaving) [controller answered:sdp];
    };
    _signaling.onAttendees = ^(NSArray<SNChimeAttendee *> *attendees) {
        SNCallController *controller = weakSelf;
        if (controller && controller->_epoch == epoch && !controller->_leaving) [controller updateAttendees:attendees];
    };
    _signaling.onClose = ^(NSError *error) {
        SNCallController *controller = weakSelf;
        if (!controller || controller->_epoch != epoch || controller->_leaving) return;
        SNTrace(@"call.signaling", error.code, @"closed", -1, 0);
        [controller leaveBecause:nil within:controller.leaveTimeout completion:nil];
    };
    [_signaling start];
}

- (void)signalingJoined:(SNChimeTURN *)turn {
    NSMutableArray<SNICEServer *> *servers = [NSMutableArray new];
    if (turn.uris.count) {
        SNICEServer *server = [SNICEServer new];
        server.urls = turn.uris;
        server.username = turn.username;
        server.credential = turn.password;
        [servers addObject:server];
    }
    _media = self.makeMedia ? self.makeMedia(servers) : nil;
    SNTrace(@"call.media", 0, _media ? @"created" : @"unavailable", -1, 0);
    if (!_media) return [self leaveBecause:nil within:self.leaveTimeout completion:nil];
    _media.muted = _muted;
    NSUInteger epoch = _epoch;
    __weak SNCallController *weakSelf = self;
    _media.onStateChange = ^(SNCallMediaState state) {
        SNCallController *controller = weakSelf;
        if (controller && controller->_epoch == epoch && !controller->_leaving) [controller mediaChanged:state];
    };
    [_media createOffer:^(NSString *sdp, NSError *error) {
        SNCallController *controller = weakSelf;
        if (!controller || controller->_epoch != epoch || controller->_leaving) return;
        if (!sdp) {
            SNTrace(@"call.media.offer", error.code, @"failed", -1, 0);
            return [controller leaveBecause:nil within:controller.leaveTimeout completion:nil];
        }
        controller->_subscribed = YES;
        [controller->_signaling subscribeWithOffer:sdp audioHost:SNSlackPortURL(controller->_credentials.audioHost) muted:controller->_muted];
    }];
}

- (void)answered:(NSString *)sdp {
    NSUInteger epoch = _epoch;
    __weak SNCallController *weakSelf = self;
    [_media setAnswer:sdp completion:^(NSError *error) {
        SNCallController *controller = weakSelf;
        if (!controller || controller->_epoch != epoch || controller->_leaving || !error) return;
        SNTrace(@"call.media.answer", error.code, @"failed", -1, 0);
        [controller leaveBecause:nil within:controller.leaveTimeout completion:nil];
    }];
}

- (void)mediaChanged:(SNCallMediaState)state {
    SNTrace(@"call.media", 0, @[ @"connecting", @"connected", @"disconnected", @"failed", @"closed" ][state], -1, 0);
    if (state == SNCallMediaFailed) return [self leaveBecause:nil within:self.leaveTimeout completion:nil];
    SNCallState next = state == SNCallMediaConnected ? SNCallConnected : state == SNCallMediaDisconnected && _state == SNCallConnected ? SNCallReconnecting : _state;
    if (next == _state) return;
    // Slack's client keeps the profile's "in a huddle" alive from the moment the huddle starts
    // here (STARTED) until it ends.
    if (next == SNCallConnected && !_statusTimer) [self refreshHuddleState];
    _state = next;
    [self changed];
}

- (void)huddleChanged:(SNHuddle *)huddle {
    if (!_conversationID || _leaving) return;
    BOOL ours = huddle.isActive && _joinedHuddleID && [huddle.identifier isEqualToString:_joinedHuddleID];
    if (ours) _huddleSeen = YES;
    // A huddle started here shows in the source a moment after rooms.join (sh_room_join): until
    // then its absence, or the room of the huddle it replaces, says nothing.
    if (ours || !_huddleSeen) return;
    SNTrace(@"call.huddle", 0, @"ended", -1, 0);
    [self leaveBecause:nil within:self.leaveTimeout completion:nil];
}

#pragma mark The profile's huddle state

/// users.profile.set as Slack's incrementHuddleStateExpiration: the expiration 300 s ahead, with
/// the call's ID unless the user lets Slack set a huddle status (huddles_set_status); then again
/// every statusInterval, give or take a tenth, until the call ends.
- (void)refreshHuddleState {
    [_statusTimer invalidate];
    NSDictionary *preferences = self.preferences ? self.preferences() : nil;
    NSMutableDictionary *profile = [@{@"huddle_state_expiration_ts" : @(floor(NSDate.date.timeIntervalSince1970) + SNHuddleStateLifetime)} mutableCopy];
    if (!SNPreferenceBool(preferences ?: @{}, @"huddles_set_status", NO) && _credentials.callID) profile[@"huddle_state_call_id"] = _credentials.callID;
    NSData *json = [NSJSONSerialization dataWithJSONObject:profile options:NSJSONWritingSortedKeys error:nil];
    NSDate *asked = NSDate.date;
    [_api call:@"users.profile.set"
          params:@{@"profile" : [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding], @"_x_reason" : @"increment-huddle-state-expiration-ts"}
        priority:SNCallBackground
      completion:^(NSDictionary *response, NSError *error) {
          SNTrace(@"call.huddle_state", 0, response ? @"ok" : SNAPIErrorName(error) ?: @"unanswered", -asked.timeIntervalSinceNow * 1000, 0);
      }];
    NSTimeInterval delay = self.statusInterval * (0.9 + 0.2 * arc4random_uniform(1001) / 1000.0);
    __weak SNCallController *weakSelf = self;
    _statusTimer = [NSTimer timerWithTimeInterval:delay repeats:NO block:^(NSTimer *timer) { [weakSelf refreshHuddleState]; }];
    [NSRunLoop.mainRunLoop addTimer:_statusTimer forMode:NSRunLoopCommonModes];
}

#pragma mark Muting and who is heard

- (void)setMuted:(BOOL)muted {
    if (!_conversationID || _leaving || muted == _muted) return;
    _muted = muted;
    _media.muted = muted;
    // Before SUBSCRIBE the subscription carries the state.
    if (_subscribed) [_signaling setMuted:muted];
    if (![self updatePeople]) [self changed];
}

- (void)updateAttendees:(NSArray<SNChimeAttendee *> *)attendees {
    NSDate *now = NSDate.date;
    for (SNChimeAttendee *attendee in attendees) {
        if (attendee.gone) {
            [_attendees removeObjectForKey:attendee.attendeeID];
            [_heard removeObjectForKey:attendee.attendeeID];
            continue;
        }
        _attendees[attendee.attendeeID] = attendee;
        if (attendee.volume >= SNSpeakingVolume) _heard[attendee.attendeeID] = now;
    }
    [self updatePeople];
}

/// Recomputes who is heard and who is muted; YES when that changed (and was announced).
- (BOOL)updatePeople {
    NSDate *now = NSDate.date;
    NSDate *nextQuiet = nil;
    NSMutableSet<NSString *> *speaking = [NSMutableSet new], *present = [NSMutableSet new], *unmuted = [NSMutableSet new];
    [present addObject:_userID];
    if (!_muted) [unmuted addObject:_userID];
    for (SNChimeAttendee *attendee in _attendees.allValues) {
        NSString *userID = SNUserOfAttendee(attendee);
        if (!userID) continue;
        BOOL me = [attendee.attendeeID isEqualToString:_credentials.attendeeID];
        BOOL muted = me ? _muted : attendee.muted;
        [present addObject:userID];
        if (!muted && !me) [unmuted addObject:userID];
        NSDate *quiet = [_heard[attendee.attendeeID] dateByAddingTimeInterval:SNSpeakingHold];
        if (muted || !quiet || [quiet compare:now] != NSOrderedDescending) continue;
        [speaking addObject:userID];
        if (!nextQuiet || [quiet compare:nextQuiet] == NSOrderedAscending) nextQuiet = quiet;
    }
    [present minusSet:unmuted];
    [_speakingTimer invalidate];
    _speakingTimer = nil;
    if (nextQuiet) {
        __weak SNCallController *weakSelf = self;
        _speakingTimer = [NSTimer timerWithTimeInterval:MAX(0.01, nextQuiet.timeIntervalSinceNow) repeats:NO block:^(NSTimer *timer) { [weakSelf updatePeople]; }];
        [NSRunLoop.mainRunLoop addTimer:_speakingTimer forMode:NSRunLoopCommonModes];
    }
    if ([speaking isEqualToSet:_speaking] && [present isEqualToSet:_mutedUsers]) return NO;
    _speaking = speaking;
    _mutedUsers = present;
    [self changed];
    return YES;
}

#pragma mark Leaving

- (void)leave { [self leaveBecause:@"user_initiated" within:self.leaveTimeout completion:nil]; }

- (void)leaveWithin:(NSTimeInterval)timeout completion:(void (^)(void))completion {
    _nextJoin = nil;
    [self leaveBecause:@"unload" within:timeout completion:completion];
}

/// Both leaves at once, as Slack's client fires rooms.leave and destroys its media session
/// together; `reason` is rooms.leave's (nil after a failure, as Slack's client sends it then).
/// The call ends when both are answered or `timeout` passed.
- (void)leaveBecause:(NSString *)reason within:(NSTimeInterval)timeout completion:(dispatch_block_t)completion {
    if (!_conversationID) {
        if (completion) completion();
        return;
    }
    if (completion) [_leaveCompletions addObject:[completion copy]];
    if (_leaving) return;
    _leaving = YES;
    _leaveReason = [reason copy];
    _state = SNCallLeaving;
    [_statusTimer invalidate];
    _statusTimer = nil;
    // The microphone stops at once, whatever Chime and Slack take to answer.
    [_media close];
    _media = nil;
    [_speakingTimer invalidate];
    _speakingTimer = nil;
    _speaking = [NSSet set];
    [self changed];
    NSUInteger epoch = _epoch;
    __weak SNCallController *weakSelf = self;
    if (_signaling) {
        _signalingLeaving = YES;
        NSDate *asked = NSDate.date;
        [_signaling leaveWithin:timeout completion:^(BOOL acknowledged) {
            SNTrace(@"call.signaling.leave", 0, acknowledged ? @"ok" : @"unanswered", -asked.timeIntervalSinceNow * 1000, 0);
            SNCallController *controller = weakSelf;
            if (!controller || controller->_epoch != epoch) return;
            controller->_signalingLeaving = NO;
            [controller finishIfLeft];
        }];
    }
    // While rooms.join is out its answer says what to leave.
    _roomLeaving = _joinOut || _credentials != nil;
    if (_credentials) [self leaveRoom];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SNCallController *controller = weakSelf;
        if (controller && controller->_epoch == epoch) [controller finish];
    });
    [self finishIfLeft];
}

- (void)leaveRoom {
    NSUInteger epoch = _epoch;
    __weak SNCallController *weakSelf = self;
    [self sendRoomLeave:_credentials reason:_leaveReason completion:^{
        SNCallController *controller = weakSelf;
        if (controller && controller->_epoch == epoch) [controller roomLeft];
    }];
}

- (void)roomLeft {
    _roomLeaving = NO;
    [self finishIfLeft];
}

- (void)sendRoomLeave:(SNCallCredentials *)credentials reason:(NSString *)reason completion:(dispatch_block_t)completion {
    NSMutableDictionary *params = [@{@"channel_id" : credentials.conversationID, @"call_id" : credentials.callID, @"attendee_id" : credentials.attendeeID,
                                     @"_x_reason" : @"calls-api/leaveRoom"} mutableCopy];
    if (reason) params[@"reason"] = reason;
    NSDate *asked = NSDate.date;
    __weak SNCallController *weakSelf = self;
    [_api call:@"rooms.leave" params:params priority:SNCallUserFacing completion:^(NSDictionary *response, NSError *error) {
        NSString *name = SNAPIErrorName(error);
        SNTrace(@"call.rooms.leave", 0, response ? @"ok" : name ?: @"unanswered", -asked.timeIntervalSinceNow * 1000, 0);
        // Any answer is final (Slack's client counts room_not_found and the like as left); without
        // one the recovery file keeps the call for the next launch.
        if (response || name) [weakSelf forgetRecord:credentials];
        if (completion) completion();
    }];
}

- (void)finishIfLeft {
    if (_leaving && !_signalingLeaving && !_roomLeaving) [self finish];
}

- (void)finish {
    _epoch++;
    _signaling = nil;
    _conversationID = nil;
    _joinedHuddleID = nil;
    _huddleSeen = NO;
    _credentials = nil;
    _leaveReason = nil;
    _joinOut = _subscribed = _leaving = _signalingLeaving = _roomLeaving = NO;
    [_attendees removeAllObjects];
    [_heard removeAllObjects];
    _speaking = _mutedUsers = [NSSet set];
    [self changed];
    NSArray<dispatch_block_t> *completions = _leaveCompletions;
    _leaveCompletions = [NSMutableArray new];
    for (dispatch_block_t completion in completions) completion();
    dispatch_block_t next = _nextJoin;
    _nextJoin = nil;
    if (next) next();
}

#pragma mark The recovery file

- (void)keepRecord:(SNCallCredentials *)credentials {
    if (!_recoveryFile) return;
    NSData *data = [NSJSONSerialization dataWithJSONObject:credentials.record options:0 error:nil];
    [NSFileManager.defaultManager createDirectoryAtURL:_recoveryFile.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    // The join token lets whoever holds it into the meeting: the user's alone.
    if ([data writeToURL:_recoveryFile options:NSDataWritingAtomic error:nil])
        [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions : @0600} ofItemAtPath:_recoveryFile.path error:nil];
}

- (NSDictionary *)readRecord {
    NSData *data = _recoveryFile ? [NSData dataWithContentsOfURL:_recoveryFile] : nil;
    id record = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [record isKindOfClass:NSDictionary.class] ? record : nil;
}

/// Removes the file if it still holds this call (a later call may have written its own).
- (void)forgetRecord:(SNCallCredentials *)credentials {
    if ([SNJSONString(self.readRecord, @"attendee_id") isEqualToString:credentials.attendeeID])
        [NSFileManager.defaultManager removeItemAtURL:_recoveryFile error:nil];
}

- (void)recover {
    if (SNReadOnly()) return;
    SNCallCredentials *credentials = _stale;
    if (!credentials) return;
    _stale = nil;
    // Tried once: a leave that fails now is not tried again at every launch.
    [self forgetRecord:credentials];
    SNTrace(@"call.recover", 0, @"leaving", -1, 0);
    NSURL *url = credentials.signalingURL ? [NSURL URLWithString:SNSlackPortURL(credentials.signalingURL)] : nil;
    if (url && credentials.joinToken) {
        SNChimeSignaling *signaling = [[SNChimeSignaling alloc] initWithURL:url joinToken:credentials.joinToken urlSession:_urlSession];
        signaling.attendeeID = credentials.attendeeID;
        [_recovering addObject:signaling];
        __weak SNCallController *weakSelf = self;
        [signaling leaveWithin:self.leaveTimeout completion:^(BOOL acknowledged) {
            SNTrace(@"call.recover.signaling.leave", 0, acknowledged ? @"ok" : @"unanswered", -1, 0);
            SNCallController *controller = weakSelf;
            if (controller) [controller->_recovering removeObject:signaling];
        }];
    }
    [self sendRoomLeave:credentials reason:@"unload" completion:nil];
}

#pragma mark The snapshot

- (void)changed {
    _call = _conversationID ? [[SNCall alloc] initWithConversationID:_conversationID
                                                            huddleID:_credentials.callID
                                                               state:_state
                                                               muted:_muted
                                                            speaking:_speaking
                                                          mutedUsers:_mutedUsers]
                            : nil;
    if (self.onChange) self.onChange();
}

@end
