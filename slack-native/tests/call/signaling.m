// The Chime signalling client against the local Chime server: the handshake, JOIN until INDEX with
// TURN, SUBSCRIBE and its answer, mute, pings both ways, attendees, leave with and without an ack,
// a leave on a fresh connection, and every way the connection ends badly. Values are made up.
#import "call/signaling.h"
#import "chimeserver.h"
#import "test.h"

static BOOL WaitUntil(NSTimeInterval timeout, BOOL (^condition)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!condition() && deadline.timeIntervalSinceNow > 0) SNSettle(0.01);
    return condition();
}

/// A client of a fresh server; nil (and a note) when no local listener can start here.
static SNChimeSignaling *Client(SNTestChimeServer **server) {
    *server = [SNTestChimeServer start];
    if (!*server) {
        printf("skip: no local listener\n");
        return nil;
    }
    NSURLSession *urlSession = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
    SNChimeSignaling *client = [[SNChimeSignaling alloc] initWithURL:(*server).url joinToken:@"made-up-join-token" urlSession:urlSession];
    client.attendeeID = @"attendee-self";
    return client;
}

/// Starts `client` and waits for onJoined; the TURN credentials it got.
static SNChimeTURN *Join(SNChimeSignaling *client, BOOL *joined) {
    __block SNChimeTURN *turn;
    __block BOOL done = NO;
    client.onJoined = ^(SNChimeTURN *credentials) {
        turn = credentials;
        done = YES;
    };
    [client start];
    *joined = WaitUntil(2, ^BOOL { return done; });
    return turn;
}

SN_TEST(ChimeSignalingJoinsSubscribesMutesAndLeaves) {
    SNTestChimeServer *server;
    SNChimeSignaling *client = Client(&server);
    if (!client) return;
    server.turn = @{@"username" : @"made-up-user", @"password" : @"made-up-pass", @"ttl" : @300, @"uris" : @[ @"turn:turn.example.invalid:3478?transport=udp" ]};
    __block NSError *closed;
    client.onClose = ^(NSError *error) { closed = error; };
    BOOL joined;
    SNChimeTURN *turn = Join(client, &joined);
    SNExpect(joined, "joined once JOIN_ACK and INDEX came");
    SNExpect([turn.username isEqualToString:@"made-up-user"] && turn.ttl == 300 && [turn.uris.firstObject hasPrefix:@"turn:"], "JOIN_ACK's TURN handed over");
    SNExpect([server.handshakes.firstObject[@"sec-websocket-protocol"] isEqualToString:@"_aws_wt_session, made-up-join-token"], "subprotocols carry the join token");

    NSDictionary *join = [server receivedOfType:@"JOIN"].firstObject;
    SNExpect([join[@"prefix"] isEqual:@5] && [join[@"timestamp_ms"] unsignedLongLongValue] > 1700000000000, "type byte and a millisecond timestamp");
    SNExpect([join[@"join"][@"protocol_version"] isEqual:@2] && [join[@"join"][@"flags"] isEqual:@2] && [join[@"join"][@"wants_compressed_sdp"] isEqual:@NO], "JOIN fields");
    SNExpect([join[@"join"][@"client_details"][@"client_source"] isEqualToString:@"amazon-chime-sdk-js"] && join[@"join"][@"audio_session_id"], "client details and audio session");
    NSArray *joinKeys = [join[@"join"] allKeys];
    SNExpect(![joinKeys filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF BEGINSWITH 'field'"]].count, "only known JOIN fields");

    __block NSString *answer;
    client.onAnswer = ^(NSString *sdp) { answer = sdp; };
    [client subscribeWithOffer:@"v=0\r\nmade-up offer\r\n" audioHost:@"audio.example.invalid:3478" muted:YES];
    SNExpect(WaitUntil(2, ^BOOL { return answer != nil; }) && [answer hasPrefix:@"v=0"], "SUBSCRIBE_ACK's answer");
    NSDictionary *subscribe = [server receivedOfType:@"SUBSCRIBE"].firstObject[@"sub"];
    SNExpect([subscribe[@"duplex"] isEqual:@1] && [subscribe[@"audio_muted"] isEqual:@YES] && [subscribe[@"audio_checkin"] isEqual:@NO], "RX, muted, no checkin");
    SNExpect([subscribe[@"sdp_offer"] hasSuffix:@"made-up offer\r\n"] && [subscribe[@"audio_host"] isEqualToString:@"audio.example.invalid:3478"], "offer and audio host");
    NSDictionary *stream = [subscribe[@"send_streams"] firstObject];
    SNExpect([stream[@"attendee_id"] isEqualToString:@"attendee-self"] && [stream[@"media_type"] isEqual:@1] && [stream[@"track_label"] isEqualToString:@"AmazonChimeExpressAudio"], "the audio stream is the attendee's");

    [client setMuted:NO];
    SNExpect(WaitUntil(2, ^BOOL { return [server receivedOfType:@"AUDIO_CONTROL"].count == 1; }), "AUDIO_CONTROL sent");
    SNExpect([[server receivedOfType:@"AUDIO_CONTROL"].firstObject[@"audio_control"][@"muted"] isEqual:@NO], "unmuted");

    NSDictionary *ping = [server receivedOfType:@"PING_PONG"].firstObject[@"ping_pong"];
    SNExpect([ping[@"type"] isEqual:@1] && [ping[@"ping_id"] isEqual:@1], "pinged at once");
    [server sendPing:9];
    SNExpect(WaitUntil(2, ^BOOL {
                 return [[server receivedOfType:@"PING_PONG"] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"ping_pong.type == 2 AND ping_pong.ping_id == 9"]].count == 1;
             }),
             "the server's ping answered");

    __block NSNumber *acknowledged;
    [client leaveWithin:2 completion:^(BOOL ack) { acknowledged = @(ack); }];
    SNExpect(WaitUntil(2, ^BOOL { return acknowledged != nil; }) && acknowledged.boolValue, "LEAVE acknowledged");
    SNExpect([server receivedOfType:@"LEAVE"].count == 1, "one LEAVE");
    __block BOOL again = NO;
    [client leaveWithin:2 completion:^(BOOL ack) { again = ack; }];
    SNExpect(again && [server receivedOfType:@"LEAVE"].count == 1, "a second leave answers at once");
    SNSettle(0.1);
    SNExpect(!closed, "leaving is not a failure");
    [server stop];
}

SN_TEST(ChimeSignalingReportsAttendees) {
    SNTestChimeServer *server;
    SNChimeSignaling *client = Client(&server);
    if (!client) return;
    NSMutableArray<NSArray<SNChimeAttendee *> *> *reports = [NSMutableArray new];
    client.onAttendees = ^(NSArray<SNChimeAttendee *> *attendees) { [reports addObject:attendees]; };
    BOOL joined;
    Join(client, &joined);
    SNExpect(joined, "joined");
    NSDictionary * (^byID)(NSArray<SNChimeAttendee *> *) = ^(NSArray<SNChimeAttendee *> *attendees) {
        NSMutableDictionary *found = [NSMutableDictionary new];
        for (SNChimeAttendee *attendee in attendees) found[attendee.attendeeID] = attendee;
        return found;
    };

    [server sendStreams:@[ @{@"audio_stream_id" : @1, @"attendee_id" : @"attendee-a", @"external_user_id" : @"T0-R0-U0A"},
                           @{@"audio_stream_id" : @2, @"attendee_id" : @"attendee-b", @"muted" : @YES} ]];
    SNExpect(WaitUntil(2, ^BOOL { return reports.count == 1; }), "named streams reported");
    NSDictionary *named = byID(reports.lastObject);
    SNChimeAttendee *a = named[@"attendee-a"], *b = named[@"attendee-b"];
    SNExpect([a.externalUserID isEqualToString:@"T0-R0-U0A"] && !a.muted && !a.gone && a.signalStrength == 1, "attendee a present");
    SNExpect([b.externalUserID isEqualToString:@"attendee-b"] && b.muted, "without an external ID it is the attendee ID; muted");

    [server sendLevels:@[ @{@"audio_stream_id" : @1, @"volume" : @14, @"signal_strength" : @2} ]];
    SNExpect(WaitUntil(2, ^BOOL { return reports.count == 2; }), "levels reported");
    SNExpect(reports.lastObject.count == 1 && reports.lastObject.firstObject.volume == 1, "a heard at full volume; b, implicitly silent, unchanged");
    [server sendLevels:@[ @{@"audio_stream_id" : @2, @"volume" : @28} ]];
    SNExpect(WaitUntil(2, ^BOOL { return reports.count == 3; }), "levels reported again");
    NSDictionary *levels = byID(reports.lastObject);
    SNChimeAttendee *silent = levels[@"attendee-a"], *half = levels[@"attendee-b"];
    SNExpect(silent.volume == 0 && half.volume == 0.5, "a left out goes silent; b at half");

    [server sendStreams:@[ @{@"audio_stream_id" : @2, @"muted" : @NO} ]];
    SNExpect(WaitUntil(2, ^BOOL { return reports.count == 4; }) && !reports.lastObject.firstObject.muted, "b unmuted by stream");
    [server sendStreams:@[ @{@"audio_stream_id" : @5, @"attendee_id" : @"attendee-b"}, @{@"audio_stream_id" : @2} ]];
    SNExpect(WaitUntil(2, ^BOOL { return reports.count == 5; }), "b moved to a new stream");
    SNExpect(reports.lastObject.count == 1 && !reports.lastObject.firstObject.gone, "b stays: a newer stream is theirs");
    [server sendStreams:@[ @{@"audio_stream_id" : @1, @"dropped" : @YES} ]];
    SNExpect(WaitUntil(2, ^BOOL { return reports.count == 6; }) && reports.lastObject.firstObject.gone, "a gone with their stream");
    [client leaveWithin:1 completion:nil];
    [server stop];
}

SN_TEST(ChimeSignalingLeaveWithoutAckTimesOut) {
    SNTestChimeServer *server;
    SNChimeSignaling *client = Client(&server);
    if (!client) return;
    server.acksLeave = NO;
    BOOL joined;
    Join(client, &joined);
    __block NSNumber *acknowledged;
    NSDate *start = NSDate.date;
    [client leaveWithin:0.3 completion:^(BOOL ack) { acknowledged = @(ack); }];
    SNExpect(WaitUntil(2, ^BOOL { return acknowledged != nil; }) && !acknowledged.boolValue, "gives up unacknowledged");
    SNExpect(-start.timeIntervalSinceNow >= 0.25, "after the timeout");
    SNExpect([server receivedOfType:@"LEAVE"].count == 1, "LEAVE was sent");
    [server stop];
}

SN_TEST(ChimeSignalingLeavesOnAFreshConnection) {
    SNTestChimeServer *server;
    SNChimeSignaling *client = Client(&server);
    if (!client) return;
    __block NSNumber *acknowledged;
    [client leaveWithin:2 completion:^(BOOL ack) { acknowledged = @(ack); }];
    SNExpect(WaitUntil(2, ^BOOL { return acknowledged != nil; }) && acknowledged.boolValue, "a leave recovered at launch is acknowledged");
    SNExpect([server receivedOfType:@"LEAVE"].count == 1 && ![server receivedOfType:@"JOIN"].count, "LEAVE alone, no JOIN");
    [client start];
    SNSettle(0.1);
    SNExpect(server.connectionCount == 1, "a client that left does not join again");
    [server stop];
}

SN_TEST(ChimeSignalingReportsHowItEnded) {
    NSArray *endings = @[ @[ @"4410", @4410 ], @[ @"drop", @(SNChimeErrorDropped) ], @[ @"status", @410 ], @[ @"error", @403 ] ];
    for (NSArray *ending in endings) {
        SNTestChimeServer *server;
        SNChimeSignaling *client = Client(&server);
        if (!client) return;
        __block NSError *closed;
        client.onClose = ^(NSError *error) { closed = error; };
        BOOL joined;
        Join(client, &joined);
        [server sendAudioStatus:200];
        SNSettle(0.1);
        SNExpect(!closed, "a 2xx AUDIO_STATUS is fine");
        NSString *how = ending[0];
        if ([how isEqualToString:@"4410"]) [server closeWithCode:4410];
        else if ([how isEqualToString:@"drop"]) [server dropConnection];
        else if ([how isEqualToString:@"status"]) [server sendAudioStatus:410];
        else [server sendErrorStatus:403];
        SNExpect(WaitUntil(2, ^BOOL { return closed != nil; }), "onClose");
        SNExpect([closed.domain isEqualToString:SNChimeErrorDomain] && closed.code == [ending[1] integerValue], "with Chime's code");
        if ([how isEqualToString:@"4410"]) {
            __block NSNumber *acknowledged;
            [client leaveWithin:2 completion:^(BOOL ack) { acknowledged = @(ack); }];
            SNExpect(WaitUntil(2, ^BOOL { return acknowledged != nil; }) && acknowledged.boolValue, "leaving after a failure opens a connection for LEAVE");
            SNExpect(server.connectionCount == 2, "on a second connection");
        }
        [server stop];
    }
}

SN_TEST(ChimeSignalingGivesUpWithoutPongs) {
    SNTestChimeServer *server;
    SNChimeSignaling *client = Client(&server);
    if (!client) return;
    server.answersPings = NO;
    client.pingInterval = 0.05;
    __block NSError *closed;
    client.onClose = ^(NSError *error) { closed = error; };
    BOOL joined;
    Join(client, &joined);
    SNExpect(WaitUntil(2, ^BOOL { return closed != nil; }) && closed.code == SNChimeErrorNoPongs, "lost after unanswered pings");
    SNExpect([server receivedOfType:@"PING_PONG"].count == SNChimeMissedPongLimit, "pinged the limit's times");
    [server stop];
}
