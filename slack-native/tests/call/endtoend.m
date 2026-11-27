// A whole call on this Mac alone: the controller with libwebrtc media on synthetic devices, the
// local Chime server answering SUBSCRIBE through an in-process audio host, and a fake API for
// rooms.*. Audio flows both ways, unmuting reaches Chime and the host, and both leaves are sent on
// leave, on quit and at the launch after a crash. Values are made up.
#import "../net/stub.h"
#import "audiohost.h"
#import "call/controller.h"
#import "chimeserver.h"
#import "test.h"
#import "tonedevice.h"

#if SN_WEBRTC

static BOOL SNNear(double value, double target) { return fabs(value - target) < target * 0.05; }

/// rooms.join's answer, sending Chime's side to `signalingURL`.
static NSDictionary *SNEndToEndJoinAnswer(NSURL *signalingURL) {
    NSDictionary *placement = @{@"AudioHostUrl" : @"0a1b2c.k.m1.ue1.app.chime.aws:3478", @"SignalingUrl" : signalingURL.absoluteString,
                                @"TurnControlUrl" : @"https://2713.cell.us-east-1.meetings.chime.aws/v2/turn_sessions"};
    NSDictionary *attendee = @{@"AttendeeId" : @"attendee-self", @"ExternalUserId" : @"T0TEAM-R0ROOM-U0ME", @"JoinToken" : @"made-up-join-token"};
    return @{@"ok" : @YES, @"call" : @{@"call_id" : @"R0ROOM", @"free_willy" : @{@"meeting" : @{@"MeetingId" : @"m-made-up", @"MediaPlacement" : placement}, @"attendee" : attendee}},
             @"huddle" : @{@"channels" : @[ @"C0HUDDLE" ]}};
}

/// A connected call; nil (and a note) without a local listener.
@interface SNEndToEnd : NSObject
@property (nonatomic) SNTestChimeServer *server;
@property (nonatomic) SNTestAudioHost *host;
@property (nonatomic) SNToneDevice *tone;
@property (nonatomic) SNTestAPI *api;
@property (nonatomic) SNCallController *controller;
@property (nonatomic) NSURL *recoveryFile;
@end

@implementation SNEndToEnd

+ (instancetype)call {
    SNEndToEnd *call = [self new];
    call.server = [SNTestChimeServer start];
    if (!call.server) {
        printf("skip: no local listener\n");
        return nil;
    }
    // No TURN: the media reaches the host on loopback.
    call.server.turn = nil;
    call.host = [[SNTestAudioHost alloc] initWithFrequency:1000];
    SNTestAudioHost *host = call.host;
    call.server.answerOffer = ^(NSString *offer, void (^reply)(NSString *)) {
        [host answerOffer:offer completion:^(NSString *answer, NSError *error) {
            if (answer) reply(answer);
        }];
    };
    call.recoveryFile = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"sn-call-%@.json", NSUUID.UUID.UUIDString]]];
    call.api = [SNTestAPI new];
    NSURL *signalingURL = call.server.url;
    call.api.answer = ^NSDictionary *(NSString *method, NSDictionary *params) {
        return [method isEqualToString:@"rooms.join"] ? SNEndToEndJoinAnswer(signalingURL) : @{@"ok" : @YES};
    };
    [call makeController];
    return call;
}

- (void)makeController {
    self.controller = [[SNCallController alloc] initWithAPI:self.api
                                                 urlSession:[NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration]
                                                     userID:@"U0ME"
                                               recoveryFile:self.recoveryFile];
    self.tone = [[SNToneDevice alloc] initWithFrequency:440];
    SNToneDevice *tone = self.tone;
    self.controller.makeMedia = ^SNCallMedia *(NSArray<SNICEServer *> *servers) {
        return [[SNCallMedia alloc] initWithICEServers:servers audioDevice:tone loopbackOnly:YES];
    };
}

- (BOOL)connect {
    [self.controller joinHuddle:[SNHuddle huddleWithJSON:@{@"id" : @"R0ROOM", @"channels" : @[ @"C0HUDDLE" ], @"participants" : @[ @"U0OTHER" ]}] inConversation:@"C0HUDDLE"];
    return SNWaitUntil(15, ^BOOL { return self.controller.call.state == SNCallConnected; });
}

- (NSUInteger)roomLeaves { return [self.api.methods filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF == 'rooms.leave'"]].count; }
- (NSUInteger)chimeLeaves { return [self.server receivedOfType:@"LEAVE"].count; }

- (void)dealloc {
    [_host close];
    [_server stop];
    [NSFileManager.defaultManager removeItemAtURL:_recoveryFile error:nil];
}

@end

SN_SLOW_TEST(CallEndToEndAudioBothWaysAndBothLeaves) {
    SNEndToEnd *call = [SNEndToEnd call];
    if (!call) return;
    SNExpect(call.connect, "connected through rooms.join, Chime's signalling and the audio host");
    SNExpect(call.host.connected, "the audio host's side connected");
    SNExpect(SNWaitUntil(10, ^BOOL { return SNNear(call.tone.playedFrequency, 1000); }), "the call plays what the huddle says (1000 Hz)");
    SNSettle(0.5);
    SNExpect(call.host.device.playedLevel < 0.01, "joined muted: the huddle hears nothing");
    [call.controller setMuted:NO];
    SNExpect(SNWaitUntil(2, ^BOOL { return [[call.server receivedOfType:@"AUDIO_CONTROL"].lastObject[@"audio_control"][@"muted"] isEqual:@NO]; }), "unmuting tells Chime");
    SNExpect(SNWaitUntil(10, ^BOOL { return SNNear(call.host.device.playedFrequency, 440); }), "unmuted: the huddle hears the user (440 Hz)");
    [call.controller leave];
    SNExpect(SNWaitUntil(3, ^BOOL { return !call.controller.call; }), "left");
    SNExpect(call.roomLeaves == 1 && call.chimeLeaves == 1, "rooms.leave and the signalling LEAVE");
    SNExpect(SNWaitUntil(3, ^BOOL { return !call.tone.isRecording && !call.tone.isPlaying; }), "the audio device stopped");

    // Quit.
    SNExpect(call.connect, "connected again");
    __block BOOL quit = NO;
    [call.controller leaveWithin:2 completion:^{ quit = YES; }];
    SNExpect(SNWaitUntil(3, ^BOOL { return quit; }) && call.roomLeaves == 2 && call.chimeLeaves == 2, "quitting sends both leaves");

    // A crash, then the next launch.
    SNExpect(call.connect, "connected a third time");
    call.controller = nil;
    [call makeController];
    [call.controller recover];
    SNExpect(SNWaitUntil(3, ^BOOL { return call.roomLeaves == 3 && call.chimeLeaves == 3; }), "the next launch sends both leaves");
}

#endif
