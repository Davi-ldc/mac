// The call controller from join to both leaves, against the local Chime server and a fake API, with
// media faked so it runs without libwebrtc: rooms.join's request and answer, joining muted,
// muting, who is heard, every way out (the user, quit, a failure at each step, the signalling
// closing, the huddle ending, joining elsewhere, read-only) and the leave recovered at the next
// launch. Values are made up in Slack's and Chime's shapes.
#import "../net/stub.h"
#import "call/controller.h"
#import "chimeserver.h"
#import "net/switches.h"
#import "test.h"

/// Media that answers at once: the offer, the answer, and Connected when told.
@interface SNFakeCallMedia : SNCallMedia
@property (nonatomic, copy) NSArray<SNICEServer *> *servers;
@property (nonatomic) BOOL closed, failsOffer;
@property (nonatomic, copy, nullable) NSString *answer;
- (void)becomes:(SNCallMediaState)state;
@end

@implementation SNFakeCallMedia {
    SNCallMediaState _fakeState;
    BOOL _fakeMuted;
}

- (instancetype)initWithFakeServers:(NSArray<SNICEServer *> *)servers {
    if (!(self = [super init])) return nil;
    _servers = [servers copy];
    _fakeMuted = YES;
    return self;
}

- (void)createOffer:(void (^)(NSString *, NSError *))completion {
    BOOL fails = self.failsOffer;
    dispatch_async(dispatch_get_main_queue(), ^{
        completion(fails ? nil : @"v=0\r\nmade-up offer\r\n", fails ? [NSError errorWithDomain:@"test" code:1 userInfo:nil] : nil);
    });
}

- (void)setAnswer:(NSString *)sdp completion:(void (^)(NSError *))completion {
    self.answer = sdp;
    dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
}

- (BOOL)muted { return _fakeMuted; }
- (void)setMuted:(BOOL)muted { _fakeMuted = muted; }
- (SNCallMediaState)state { return _fakeState; }

- (void)becomes:(SNCallMediaState)state {
    _fakeState = state;
    if (self.onStateChange) self.onStateChange(state);
}

- (void)close {
    self.closed = YES;
    _fakeState = SNCallMediaClosed;
}

@end

/// A controller, its fake API and the Chime server it is sent to.
@interface SNCallRig : NSObject
@property (nonatomic) SNTestChimeServer *server;
@property (nonatomic) SNTestAPI *api;
@property (nonatomic) SNCallController *controller;
@property (nonatomic) NSURL *recoveryFile;
@property (nonatomic) SNFakeCallMedia *media;
@property (nonatomic) NSInteger changes;
/// rooms.join's answer (nil: Slack does not answer).
@property (nonatomic, copy, nullable) NSDictionary *joinAnswer;
@end

@implementation SNCallRig

static NSURLSession *SNCallTestSession(void) { return [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration]; }

/// rooms.join's answer as Slack gives it: the room and Chime's CreateMeeting/CreateAttendee output.
static NSDictionary *SNJoinAnswer(NSURL *signalingURL) {
    NSDictionary *placement = @{@"AudioHostUrl" : @"0a1b2c.k.m1.ue1.app.chime.aws:3478", @"AudioFallbackUrl" : @"wss://wss.k.m1.ue1.app.chime.aws:443/calls/m-made-up",
                                @"SignalingUrl" : signalingURL.absoluteString, @"TurnControlUrl" : @"https://2713.cell.us-east-1.meetings.chime.aws/v2/turn_sessions",
                                @"EventIngestionUrl" : @"https://data.svc.ue1.ingest.chime.aws/v1/client-events"};
    NSDictionary *meeting = @{@"MeetingId" : @"m-made-up", @"ExternalMeetingId" : @"T0TEAM-R0ROOM", @"MediaRegion" : @"us-east-1", @"MediaPlacement" : placement};
    NSDictionary *attendee = @{@"AttendeeId" : @"attendee-self", @"ExternalUserId" : @"T0TEAM-R0ROOM-U0ME", @"JoinToken" : @"made-up-join-token"};
    return @{@"ok" : @YES, @"call" : @{@"call_id" : @"R0ROOM", @"free_willy" : @{@"meeting" : meeting, @"attendee" : attendee}},
             @"huddle" : @{@"channels" : @[ @"C0HUDDLE" ]}, @"canvas" : @{@"root_thread_ts" : @"1764000000.000100"}};
}

static SNHuddle *SNTestHuddle(void) {
    return [SNHuddle huddleWithJSON:@{@"id" : @"R0ROOM", @"channels" : @[ @"C0HUDDLE" ], @"participants" : @[ @"U0OTHER" ], @"participant_history" : @[ @"U0OTHER" ], @"date_start" : @1764000000}];
}

/// nil (and a note) when no local listener can start here.
+ (instancetype)rig {
    SNCallRig *rig = [self new];
    rig.server = [SNTestChimeServer start];
    if (!rig.server) {
        printf("skip: no local listener\n");
        return nil;
    }
    rig.server.turn = @{@"username" : @"made-up-user", @"password" : @"made-up-pass", @"ttl" : @300, @"uris" : @[ @"turn:turn.example.invalid:3478?transport=udp" ]};
    rig.joinAnswer = SNJoinAnswer(rig.server.url);
    rig.recoveryFile = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"sn-call-%@.json", NSUUID.UUID.UUIDString]]];
    rig.api = [SNTestAPI new];
    __weak SNCallRig *weakRig = rig;
    rig.api.answer = ^NSDictionary *(NSString *method, NSDictionary *params) {
        return [method isEqualToString:@"rooms.join"] ? weakRig.joinAnswer : @{@"ok" : @YES};
    };
    [rig makeController];
    return rig;
}

/// A controller as a new launch makes it, on the same API and recovery file.
- (void)makeController {
    self.controller = [[SNCallController alloc] initWithAPI:self.api urlSession:SNCallTestSession() userID:@"U0ME" recoveryFile:self.recoveryFile];
    __weak SNCallRig *weakSelf = self;
    self.controller.makeMedia = ^SNCallMedia *(NSArray<SNICEServer *> *servers) {
        weakSelf.media = [[SNFakeCallMedia alloc] initWithFakeServers:servers];
        return weakSelf.media;
    };
    self.controller.onChange = ^{ weakSelf.changes++; };
}

- (void)join { [self.controller joinHuddle:SNTestHuddle() inConversation:@"C0HUDDLE"]; }

/// Joins and waits for the answer to reach the media, then connects it.
- (BOOL)joinAndConnect {
    self.media = nil;
    [self join];
    if (!SNWaitUntil(3, ^BOOL { return self.media.answer != nil; })) return NO;
    [self.media becomes:SNCallMediaConnected];
    return self.controller.call.state == SNCallConnected;
}

- (NSArray<NSDictionary *> *)callsTo:(NSString *)method {
    NSMutableArray *calls = [NSMutableArray new];
    for (NSArray *call in self.api.calls)
        if ([call.firstObject isEqualToString:method]) [calls addObject:call[1]];
    return calls;
}

- (BOOL)leftBoth {
    return SNWaitUntil(3, ^BOOL { return self.controller.call == nil; }) && [self callsTo:@"rooms.leave"].count == 1 && [self.server receivedOfType:@"LEAVE"].count == 1;
}

- (NSDictionary *)record {
    NSData *data = [NSData dataWithContentsOfURL:self.recoveryFile];
    return data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
}

- (void)dealloc {
    [_server stop];
    [NSFileManager.defaultManager removeItemAtURL:_recoveryFile error:nil];
}

@end

SN_TEST(CallJoinsMutedThroughRoomsJoinAndChime) {
    SNCallRig *rig = [SNCallRig rig];
    if (!rig) return;
    [rig join];
    SNExpect(rig.controller.call.state == SNCallJoining && rig.controller.call.muted && [rig.controller.call.conversationID isEqualToString:@"C0HUDDLE"], "joining, muted, at once");
    SNExpect([rig.controller.call.mutedUserIDs containsObject:@"U0ME"], "the user shows muted");
    SNExpect(SNWaitUntil(3, ^BOOL { return rig.media.answer != nil; }), "the answer reached the media");
    NSDictionary *join = [rig callsTo:@"rooms.join"].firstObject;
    SNExpect(([join isEqual:@{@"channel_id" : @"C0HUDDLE", @"regions" : @"", @"multidevice" : @"false", @"_x_reason" : @"calls-api/joinRoom"}]), "rooms.join as Slack's client joins a huddle going on");
    SNExpect([rig.controller.call.huddleID isEqualToString:@"R0ROOM"], "the room from rooms.join");
    SNExpect([rig.server receivedOfType:@"JOIN"].count == 1, "JOIN on the meeting's signalling URL");
    SNICEServer *turn = rig.media.servers.firstObject;
    SNExpect(rig.media.servers.count == 1 && [turn.urls isEqual:@[ @"turn:turn.example.invalid:3478?transport=udp" ]] && [turn.username isEqualToString:@"made-up-user"] && [turn.credential isEqualToString:@"made-up-pass"], "media gets JOIN_ACK's TURN");
    SNExpect(rig.media.muted, "the microphone starts muted");
    NSDictionary *subscribe = [rig.server receivedOfType:@"SUBSCRIBE"].firstObject[@"sub"];
    SNExpect([subscribe[@"audio_host"] isEqualToString:@"0a1b2c.k.m1.ue1.app.chime.aws:22466"], "audio host on Slack's port");
    SNExpect([subscribe[@"audio_muted"] isEqual:@YES] && [subscribe[@"sdp_offer"] hasSuffix:@"made-up offer\r\n"], "subscribed muted with the offer");
    SNExpect(rig.controller.call.state == SNCallJoining, "joining until the media connects");
    NSDictionary *record = rig.record;
    SNExpect([record[@"channel_id"] isEqualToString:@"C0HUDDLE"] && [record[@"call_id"] isEqualToString:@"R0ROOM"] && [record[@"attendee_id"] isEqualToString:@"attendee-self"] &&
                 [record[@"join_token"] isEqualToString:@"made-up-join-token"] && [record[@"signaling_url"] isEqualToString:rig.server.url.absoluteString],
             "the recovery file holds what leaving needs");
    NSNumber *permissions = [NSFileManager.defaultManager attributesOfItemAtPath:rig.recoveryFile.path error:nil][NSFilePosixPermissions];
    SNExpect(permissions.integerValue == 0600, "only the user reads the join token");

    [rig.media becomes:SNCallMediaConnected];
    SNExpect(rig.controller.call.state == SNCallConnected, "connected with the media");
    [rig.media becomes:SNCallMediaDisconnected];
    SNExpect(rig.controller.call.state == SNCallReconnecting, "reconnecting while ICE lost the path");
    [rig.media becomes:SNCallMediaConnected];
    SNExpect(rig.controller.call.state == SNCallConnected, "back");

    [rig.controller leave];
    SNExpect(rig.controller.call.state == SNCallLeaving && rig.media.closed, "leaving, the microphone closed at once");
    SNExpect(rig.leftBoth, "both leaves sent, then the call is over");
    SNExpect(([[rig callsTo:@"rooms.leave"].firstObject isEqual:@{@"channel_id" : @"C0HUDDLE", @"call_id" : @"R0ROOM", @"attendee_id" : @"attendee-self", @"reason" : @"user_initiated", @"_x_reason" : @"calls-api/leaveRoom"}]), "rooms.leave as Slack's client leaves");
    SNExpect(!rig.record, "the recovery file forgotten once Slack answered");
}

SN_TEST(CallMutesAndShowsWhoIsHeard) {
    SNCallRig *rig = [SNCallRig rig];
    if (!rig) return;
    SNExpect(rig.joinAndConnect, "connected");
    [rig.controller setMuted:NO];
    SNExpect(!rig.controller.call.muted && !rig.media.muted && ![rig.controller.call.mutedUserIDs containsObject:@"U0ME"], "unmuted here at once");
    SNExpect(SNWaitUntil(2, ^BOOL { return [[rig.server receivedOfType:@"AUDIO_CONTROL"].lastObject[@"audio_control"][@"muted"] isEqual:@NO]; }), "AUDIO_CONTROL unmuted");

    [rig.server sendStreams:@[ @{@"audio_stream_id" : @1, @"attendee_id" : @"attendee-self", @"external_user_id" : @"T0TEAM-R0ROOM-U0ME"},
                               @{@"audio_stream_id" : @2, @"attendee_id" : @"attendee-other", @"external_user_id" : @"T0TEAM-R0ROOM-U0OTHER"},
                               @{@"audio_stream_id" : @3, @"attendee_id" : @"attendee-quiet", @"external_user_id" : @"T0TEAM-R0ROOM-U0QUIET-d2", @"muted" : @YES} ]];
    [rig.server sendLevels:@[ @{@"audio_stream_id" : @1, @"volume" : @20}, @{@"audio_stream_id" : @2, @"volume" : @16}, @{@"audio_stream_id" : @3, @"volume" : @42} ]];
    SNExpect(SNWaitUntil(2, ^BOOL { return [rig.controller.call.speakingUserIDs isEqualToSet:[NSSet setWithArray:@[ @"U0ME", @"U0OTHER" ]]]; }), "loud attendees heard, by their Slack user");
    SNExpect([rig.controller.call.mutedUserIDs isEqualToSet:[NSSet setWithObject:@"U0QUIET"]], "a muted attendee shows muted");
    [rig.server sendLevels:@[ @{@"audio_stream_id" : @2, @"volume" : @42} ]];
    SNSettle(0.2);
    SNExpect([rig.controller.call.speakingUserIDs containsObject:@"U0OTHER"], "still heard right after going quiet");
    SNExpect(SNWaitUntil(2, ^BOOL { return ![rig.controller.call.speakingUserIDs containsObject:@"U0OTHER"]; }), "not heard half a second later");

    [rig.controller setMuted:YES];
    SNExpect(rig.controller.call.muted && rig.media.muted && ![rig.controller.call.speakingUserIDs containsObject:@"U0ME"] && [rig.controller.call.mutedUserIDs containsObject:@"U0ME"], "muting stops the user's own ring");
    SNExpect(SNWaitUntil(2, ^BOOL { return [[rig.server receivedOfType:@"AUDIO_CONTROL"].lastObject[@"audio_control"][@"muted"] isEqual:@YES]; }), "AUDIO_CONTROL muted");

    [rig.server sendStreams:@[ @{@"audio_stream_id" : @2, @"attendee_id" : @"attendee-other", @"external_user_id" : @"T0TEAM-R0ROOM-U0OTHER", @"dropped" : @YES} ]];
    [rig.server sendLevels:@[ @{@"audio_stream_id" : @3, @"volume" : @14} ]];
    SNSettle(0.3);
    SNExpect(![rig.controller.call.speakingUserIDs containsObject:@"U0QUIET"], "a muted attendee is never heard");
    [rig.controller leave];
    SNExpect(rig.leftBoth, "left");
}

SN_TEST(CallLeavesOnEveryWayOut) {
    // The huddle ends, is replaced by another, the signalling closes, the media fails, or the join
    // times out: both leaves each time.
    NSArray<NSString *> *ways = @[ @"ended", @"replaced", @"closed", @"media", @"timeout" ];
    for (NSString *way in ways) {
        SNCallRig *rig = [SNCallRig rig];
        if (!rig) return;
        if ([way isEqualToString:@"timeout"]) {
            rig.controller.joinTimeout = 1;
            [rig join];
            SNExpect(SNWaitUntil(3, ^BOOL { return rig.media.answer != nil; }), "timeout: answered");
        } else
            SNExpect(rig.joinAndConnect, "connected");
        if ([way isEqualToString:@"ended"]) [rig.controller huddleChanged:[SNTestHuddle() huddleByMergingJSON:@{@"has_ended" : @YES, @"participants" : @[]}]];
        if ([way isEqualToString:@"replaced"]) [rig.controller huddleChanged:[SNTestHuddle() huddleByMergingJSON:@{@"id" : @"R0OTHERROOM"}]];
        if ([way isEqualToString:@"closed"]) [rig.server closeWithCode:4410];
        if ([way isEqualToString:@"media"]) [rig.media becomes:SNCallMediaFailed];
        SNExpect(SNWaitUntil(3, ^BOOL { return rig.controller.call.state == SNCallLeaving || !rig.controller.call; }), [way stringByAppendingString:@": leaving"].UTF8String);
        SNExpect(SNWaitUntil(3, ^BOOL { return !rig.controller.call && [rig callsTo:@"rooms.leave"].count == 1; }), [way stringByAppendingString:@": rooms.leave sent"].UTF8String);
        // After a close a new connection carries the LEAVE.
        SNExpect([rig.server receivedOfType:@"LEAVE"].count == 1, [way stringByAppendingString:@": signalling LEAVE sent"].UTF8String);
        SNExpect(![rig callsTo:@"rooms.leave"].firstObject[@"reason"], [way stringByAppendingString:@": no reason after a failure"].UTF8String);
        SNExpect(rig.media.closed, [way stringByAppendingString:@": media closed"].UTF8String);
    }
    SNCallRig *rig = [SNCallRig rig];
    if (!rig) return;
    SNExpect(rig.joinAndConnect, "connected");
    [rig.controller huddleChanged:[SNTestHuddle() huddleByMergingJSON:@{@"participants" : @[ @"U0OTHER", @"U0ME" ]}]];
    SNExpect(rig.controller.call.state == SNCallConnected, "people joining is no reason to leave");
    [rig.controller leave];
}

SN_TEST(CallFailuresBeforeChimeLeaveWhatWasJoined) {
    SNCallRig *rig = [SNCallRig rig];
    if (!rig) return;
    // Slack refuses: nothing joined, nothing to leave.
    rig.joinAnswer = @{@"ok" : @NO, @"error" : @"rooms_call_ended"};
    [rig join];
    SNExpect(SNWaitUntil(2, ^BOOL { return !rig.controller.call; }) && ![rig callsTo:@"rooms.leave"].count && !rig.record, "refused: over, no leave");
    // No answer at all.
    rig.joinAnswer = nil;
    [rig join];
    SNExpect(SNWaitUntil(2, ^BOOL { return !rig.controller.call; }) && ![rig callsTo:@"rooms.leave"].count, "no answer: over");
    // Joined in Slack but no meeting to reach: rooms.leave only.
    NSMutableDictionary *answer = [SNJoinAnswer(rig.server.url) mutableCopy];
    answer[@"call"] = @{@"call_id" : @"R0ROOM", @"free_willy" : @{@"attendee" : @{@"AttendeeId" : @"attendee-self", @"JoinToken" : @"made-up-join-token"}}};
    rig.joinAnswer = answer;
    [rig join];
    SNExpect(SNWaitUntil(2, ^BOOL { return !rig.controller.call && [rig callsTo:@"rooms.leave"].count == 1; }), "no meeting: rooms.leave");
    SNExpect(!rig.server.connectionCount, "never reached Chime");
    // Chime refuses the offer's media: both leaves.
    rig.joinAnswer = SNJoinAnswer(rig.server.url);
    __weak SNCallRig *weakRig = rig;
    rig.controller.makeMedia = ^SNCallMedia *(NSArray<SNICEServer *> *servers) {
        weakRig.media = [[SNFakeCallMedia alloc] initWithFakeServers:servers];
        weakRig.media.failsOffer = YES;
        return weakRig.media;
    };
    [rig join];
    SNExpect(SNWaitUntil(3, ^BOOL { return !rig.controller.call && [rig callsTo:@"rooms.leave"].count == 2; }) && [rig.server receivedOfType:@"LEAVE"].count == 1, "no offer: both leaves");
    // No media in this build.
    rig.controller.makeMedia = ^SNCallMedia *(NSArray<SNICEServer *> *servers) { return nil; };
    [rig join];
    SNExpect(SNWaitUntil(3, ^BOOL { return !rig.controller.call && [rig callsTo:@"rooms.leave"].count == 3; }) && [rig.server receivedOfType:@"LEAVE"].count == 2, "no media: both leaves");
}

SN_TEST(CallLeftWhileJoiningLeavesWhatRoomsJoinGives) {
    SNCallRig *rig = [SNCallRig rig];
    if (!rig) return;
    rig.api.holds = YES;
    [rig join];
    SNExpect(SNWaitUntil(1, ^BOOL { return rig.api.held.count == 1; }), "rooms.join out");
    [rig.controller leave];
    SNExpect(rig.controller.call.state == SNCallLeaving, "leaving waits for rooms.join");
    rig.api.holds = NO;
    rig.api.held.firstObject();
    SNExpect(SNWaitUntil(2, ^BOOL { return !rig.controller.call; }), "over");
    SNExpect([rig callsTo:@"rooms.leave"].count == 1 && !rig.server.connectionCount && !rig.record, "rooms.leave for what it gave, Chime never reached");
}

SN_TEST(CallJoiningElsewhereLeavesFirst) {
    SNCallRig *rig = [SNCallRig rig];
    if (!rig) return;
    SNExpect(rig.joinAndConnect, "connected");
    SNFakeCallMedia *first = rig.media;
    [rig.controller joinHuddle:SNTestHuddle() inConversation:@"C0HUDDLE"];
    SNExpect(rig.controller.call.state == SNCallConnected && [rig callsTo:@"rooms.join"].count == 1, "the same huddle again changes nothing");
    SNHuddle *other = [SNHuddle huddleWithJSON:@{@"id" : @"R0OTHERROOM", @"channels" : @[ @"D0DM" ], @"participants" : @[ @"U0OTHER" ]}];
    [rig.controller joinHuddle:other inConversation:@"D0DM"];
    SNExpect(first.closed && rig.controller.call.state == SNCallLeaving, "leaving the first");
    SNExpect(SNWaitUntil(3, ^BOOL { return [rig callsTo:@"rooms.join"].count == 2; }), "then joining the other");
    SNExpect([rig callsTo:@"rooms.leave"].count == 1 && [rig.server receivedOfType:@"LEAVE"].count == 1, "the first left both ways first");
    SNExpect([rig.controller.call.conversationID isEqualToString:@"D0DM"] && [[rig callsTo:@"rooms.join"].lastObject[@"channel_id"] isEqualToString:@"D0DM"], "in the other");
    [rig.controller leave];
}

SN_TEST(CallQuitLeavesWithinTheWait) {
    SNCallRig *rig = [SNCallRig rig];
    if (!rig) return;
    SNExpect(rig.joinAndConnect, "connected");
    __block BOOL done = NO;
    NSDate *start = NSDate.date;
    [rig.controller leaveWithin:2 completion:^{ done = YES; }];
    SNExpect(SNWaitUntil(3, ^BOOL { return done; }) && -start.timeIntervalSinceNow < 2.5, "quit waited for the leaves, not longer");
    SNExpect([rig callsTo:@"rooms.leave"].count == 1 && [rig.server receivedOfType:@"LEAVE"].count == 1, "both leaves");
    SNExpect([[rig callsTo:@"rooms.leave"].firstObject[@"reason"] isEqualToString:@"unload"], "as Slack's client leaves when its window goes");
    __block BOOL none = NO;
    [rig.controller leaveWithin:2 completion:^{ none = YES; }];
    SNExpect(none, "no call: at once");

    // Chime does not acknowledge and Slack does not answer: the wait still ends, and the file keeps
    // the call for the next launch.
    rig.server.acksLeave = NO;
    SNExpect(rig.joinAndConnect, "connected again");
    NSURL *signalingURL = rig.server.url;
    rig.api.answer = ^NSDictionary *(NSString *method, NSDictionary *params) { return [method isEqualToString:@"rooms.join"] ? SNJoinAnswer(signalingURL) : nil; };
    done = NO;
    start = NSDate.date;
    [rig.controller leaveWithin:0.5 completion:^{ done = YES; }];
    SNExpect(SNWaitUntil(2, ^BOOL { return done; }) && -start.timeIntervalSinceNow < 1, "the wait is bounded");
    SNExpect(rig.record != nil, "unanswered: kept for the next launch");
}

SN_TEST(CallLeftOpenIsLeftAtNextLaunch) {
    SNCallRig *rig = [SNCallRig rig];
    if (!rig) return;
    SNExpect(rig.joinAndConnect, "connected");
    // The app ends without leaving (a crash): only the file is left.
    rig.controller.onChange = nil;
    rig.controller = nil;
    SNExpect(rig.record != nil, "the file outlives the app");
    NSUInteger leaves = [rig.server receivedOfType:@"LEAVE"].count;

    [rig makeController];
    [rig.controller recover];
    SNExpect(SNWaitUntil(3, ^BOOL { return [rig callsTo:@"rooms.leave"].count == 1 && [rig.server receivedOfType:@"LEAVE"].count == leaves + 1; }), "both leaves at the next launch");
    SNExpect(([[rig callsTo:@"rooms.leave"].firstObject isEqual:@{@"channel_id" : @"C0HUDDLE", @"call_id" : @"R0ROOM", @"attendee_id" : @"attendee-self", @"reason" : @"unload", @"_x_reason" : @"calls-api/leaveRoom"}]), "rooms.leave for the old attendee");
    SNExpect(!rig.record, "forgotten");
    [rig.controller recover];
    SNSettle(0.2);
    SNExpect([rig callsTo:@"rooms.leave"].count == 1, "once");

    // A failed recovery is not tried again at every launch.
    SNExpect(rig.joinAndConnect, "connected");
    rig.controller.onChange = nil;
    rig.controller = nil;
    rig.api.answer = ^NSDictionary *(NSString *method, NSDictionary *params) { return nil; };
    [rig makeController];
    [rig.controller recover];
    SNExpect(SNWaitUntil(3, ^BOOL { return [rig callsTo:@"rooms.leave"].count == 2; }) && !rig.record, "tried once, then forgotten");

    // A launch that joins before boot lets recovery run still leaves the crashed call.
    __weak SNCallRig *weakRig = rig;
    rig.api.answer = ^NSDictionary *(NSString *method, NSDictionary *params) { return [method isEqualToString:@"rooms.join"] ? weakRig.joinAnswer : @{@"ok" : @YES}; };
    SNExpect(rig.joinAndConnect, "connected");
    rig.controller.onChange = nil;
    rig.controller = nil;
    [rig makeController];
    NSMutableDictionary *answer = [SNJoinAnswer(rig.server.url) mutableCopy];
    answer[@"call"] = @{@"call_id" : @"R0ROOM", @"free_willy" : @{@"meeting" : SNJoinAnswer(rig.server.url)[@"call"][@"free_willy"][@"meeting"],
                                                                 @"attendee" : @{@"AttendeeId" : @"attendee-new", @"ExternalUserId" : @"T0TEAM-R0ROOM-U0ME-d2", @"JoinToken" : @"made-up-join-token-2"}}};
    rig.joinAnswer = answer;
    SNExpect(rig.joinAndConnect, "joined again before recovery");
    [rig.controller recover];
    SNExpect(SNWaitUntil(3, ^BOOL { return [rig callsTo:@"rooms.leave"].count == 3; }), "the crashed call left");
    SNExpect([[rig callsTo:@"rooms.leave"].lastObject[@"attendee_id"] isEqualToString:@"attendee-self"] && rig.controller.call.state == SNCallConnected, "the old attendee, the new call untouched");
    SNExpect([rig.record[@"attendee_id"] isEqualToString:@"attendee-new"], "the file holds the new call");
    [rig.controller leave];
    SNExpect(SNWaitUntil(3, ^BOOL { return !rig.controller.call; }) && !rig.record, "left");
}

SN_TEST(CallReadOnlyNeverJoins) {
    SNCallRig *rig = [SNCallRig rig];
    if (!rig) return;
    // SNClient refuses rooms.join locally in read-only mode, as SNTestAPI hands it over.
    rig.api.answer = ^NSDictionary *(NSString *method, NSDictionary *params) { return nil; };
    SNExpect(SNIsMutatingMethod(@"rooms.join") && SNIsMutatingMethod(@"rooms.leave"), "rooms.join and rooms.leave are writes, refused by SN_READONLY");
    [rig join];
    SNExpect(SNWaitUntil(2, ^BOOL { return !rig.controller.call; }) && !rig.server.connectionCount && ![rig callsTo:@"rooms.leave"].count, "the call just ends");
}

/// A Chime region lookup answering `region` without the network.
static NSURL *SNRegionAnswer(NSString *region) {
    return [NSURL URLWithString:[@"data:application/json," stringByAppendingString:[[NSString stringWithFormat:@"{\"region\":\"%@\"}", region] stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet]]];
}

SN_TEST(CallStartsAHuddleInTheNearestRegion) {
    SNCallRig *rig = [SNCallRig rig];
    if (!rig) return;
    NSString *suite = [@"sn-test-region-" stringByAppendingString:NSUUID.UUID.UUIDString];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    rig.controller.regionDefaults = defaults;
    rig.controller.regionURL = SNRegionAnswer(@"sa-east-1");
    [rig.controller startHuddleInConversation:@"D0DM" muted:NO];
    SNExpect(rig.controller.call.state == SNCallJoining && !rig.controller.call.muted && ![rig.controller.call.mutedUserIDs containsObject:@"U0ME"], "starting, the microphone on");
    SNExpect(SNWaitUntil(3, ^BOOL { return rig.media.answer != nil; }), "through Chime as a join");
    SNExpect(([[rig callsTo:@"rooms.join"].firstObject isEqual:@{@"channel_id" : @"D0DM", @"regions" : @"sa-east-1", @"multidevice" : @"false", @"_x_reason" : @"calls-api/joinRoom"}]), "rooms.join with the nearest region, as Slack's client starts one");
    SNExpect(!rig.media.muted && [[rig.server receivedOfType:@"SUBSCRIBE"].firstObject[@"sub"][@"audio_muted"] isEqual:@NO], "subscribed unmuted");
    SNExpect([rig.controller.call.huddleID isEqualToString:@"R0ROOM"], "the room rooms.join made");
    SNExpect([[defaults dictionaryForKey:@"ChimeRegionCache"][@"region"] isEqualToString:@"sa-east-1"], "the region kept");

    [rig.media becomes:SNCallMediaConnected];
    [rig.controller huddleChanged:nil];
    SNExpect(rig.controller.call.state == SNCallConnected, "the room not shown yet is no reason to leave");
    [rig.controller huddleChanged:[SNTestHuddle() huddleByMergingJSON:@{@"channels" : @[ @"D0DM" ], @"participants" : @[ @"U0ME" ]}]];
    [rig.controller huddleChanged:nil];
    SNExpect(SNWaitUntil(3, ^BOOL { return !rig.controller.call; }) && [rig callsTo:@"rooms.leave"].count == 1, "once shown, its end is left");

    // A later start, or the next launch, takes the kept region without asking.
    rig.controller.regionURL = [NSURL URLWithString:@"http://127.0.0.1:9/"];
    [rig.controller startHuddleInConversation:@"C0HUDDLE" muted:YES];
    SNExpect(SNWaitUntil(3, ^BOOL { return [rig callsTo:@"rooms.join"].count == 2; }) && [[rig callsTo:@"rooms.join"].lastObject[@"regions"] isEqualToString:@"sa-east-1"], "the region from this launch");
    SNExpect(rig.controller.call.muted, "muted when asked");
    [rig.controller leave];
    SNExpect(SNWaitUntil(3, ^BOOL { return !rig.controller.call; }), "left");
    [rig makeController];
    rig.controller.regionDefaults = defaults;
    rig.controller.regionURL = [NSURL URLWithString:@"http://127.0.0.1:9/"];
    [rig.controller startHuddleInConversation:@"C0HUDDLE" muted:YES];
    SNExpect(SNWaitUntil(3, ^BOOL { return [rig callsTo:@"rooms.join"].count == 3; }) && [[rig callsTo:@"rooms.join"].lastObject[@"regions"] isEqualToString:@"sa-east-1"], "the region kept from an earlier launch");
    [rig.controller leave];
    SNExpect(SNWaitUntil(3, ^BOOL { return !rig.controller.call; }), "left again");

    // Older than 72 hours it is asked again; no answer starts with no preference.
    [defaults setObject:@{@"region" : @"sa-east-1", @"timestamp" : @(NSDate.date.timeIntervalSince1970 - 73 * 3600)} forKey:@"ChimeRegionCache"];
    [rig makeController];
    rig.controller.regionDefaults = defaults;
    rig.controller.regionURL = [NSURL URLWithString:@"http://127.0.0.1:9/"];
    [rig.controller startHuddleInConversation:@"C0HUDDLE" muted:YES];
    SNExpect(SNWaitUntil(6, ^BOOL { return [rig callsTo:@"rooms.join"].count == 4; }) && [[rig callsTo:@"rooms.join"].lastObject[@"regions"] isEqualToString:@""], "a stale region asked again, an unanswered lookup gives none");
    [rig.controller leave];
    SNExpect(SNWaitUntil(3, ^BOOL { return !rig.controller.call; }), "left at last");
    [defaults removePersistentDomainForName:suite];
}

SN_TEST(CallKeepsTheProfilesHuddleStateAlive) {
    SNCallRig *rig = [SNCallRig rig];
    if (!rig) return;
    rig.controller.statusInterval = 0.2;
    [rig join];
    SNExpect(SNWaitUntil(3, ^BOOL { return rig.media.answer != nil; }), "answered");
    SNExpect([rig callsTo:@"users.profile.set"].count == 0, "nothing before the huddle is going on here");
    [rig.media becomes:SNCallMediaConnected];
    NSDictionary *first = [rig callsTo:@"users.profile.set"].firstObject;
    NSDictionary *profile = [NSJSONSerialization JSONObjectWithData:[first[@"profile"] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    double ahead = [profile[@"huddle_state_expiration_ts"] doubleValue] - NSDate.date.timeIntervalSince1970;
    SNExpect(ahead > 290 && ahead <= 300 && [profile[@"huddle_state_call_id"] isEqualToString:@"R0ROOM"] && profile.count == 2, "at once once connected: 300 s ahead, with the call");
    SNExpect([first[@"_x_reason"] isEqualToString:@"increment-huddle-state-expiration-ts"], "Slack's reason");
    SNExpect(SNWaitUntil(2, ^BOOL { return [rig callsTo:@"users.profile.set"].count >= 3; }), "again every interval");
    [rig.controller leave];
    SNExpect(SNWaitUntil(3, ^BOOL { return !rig.controller.call; }), "left");
    NSUInteger sent = [rig callsTo:@"users.profile.set"].count;
    SNWaitUntil(0.6, ^BOOL { return NO; });
    SNExpect([rig callsTo:@"users.profile.set"].count == sent, "not after leaving");

    rig.controller.preferences = ^NSDictionary * { return @{@"huddles_set_status" : @YES}; };
    SNExpect(rig.joinAndConnect, "connected again");
    NSDictionary *next = [rig callsTo:@"users.profile.set"].lastObject;
    profile = [NSJSONSerialization JSONObjectWithData:[next[@"profile"] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    SNExpect(profile.count == 1 && profile[@"huddle_state_expiration_ts"], "without the call while Slack sets the huddle status");
    [rig.controller leave];
    SNExpect(SNWaitUntil(3, ^BOOL { return !rig.controller.call; }), "left again");
}

SN_TEST(CallLeftWhileFindingTheRegionAsksNothing) {
    SNCallRig *rig = [SNCallRig rig];
    if (!rig) return;
    rig.controller.regionURL = [NSURL URLWithString:@"http://127.0.0.1:9/"];
    [rig.controller startHuddleInConversation:@"C0HUDDLE" muted:YES];
    [rig.controller leave];
    SNExpect(!rig.controller.call, "over at once: nothing was joined");
    SNWaitUntil(1, ^BOOL { return NO; });
    SNExpect([rig callsTo:@"rooms.join"].count == 0 && [rig callsTo:@"rooms.leave"].count == 0, "no rooms.join after the region answers, nothing to leave");
}
