// Tests a call's media: the offer Chime's audio host gets, audio both ways through libwebrtc over
// loopback with synthetic devices (never the microphone), mute, close, and TURN as Slack uses it.
// Real media takes seconds: those cases are `make test-slow`'s.
#import <arpa/inet.h>
#import <mach/mach.h>
#import <netinet/in.h>
#import <sys/socket.h>

#import "../net/stub.h"
#import "audiohost.h"
#import "call/media.h"
#import "test.h"
#import "tonedevice.h"

SN_TEST(CallMediaUsesSlacksPort) {
    SNExpect([SNSlackPortURL(@"turn:turn.example.invalid:3478?transport=udp") isEqualToString:@"turn:turn.example.invalid:22466?transport=udp"] &&
                 [SNSlackPortURL(@"turns:turn.example.invalid:443?transport=tcp") isEqualToString:@"turns:turn.example.invalid:443?transport=tcp"],
             "TURN goes to Slack's UDP port 22466, not Chime's 3478; other ports stay");
}

#if SN_WEBRTC

static double FootprintMB(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    return task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) == KERN_SUCCESS ? info.phys_footprint / 1048576.0 : -1;
}

/// The lines of the `kind` ("audio", "video") media section.
static NSString *Section(NSString *sdp, NSString *kind) {
    NSRange start = [sdp rangeOfString:[NSString stringWithFormat:@"\r\nm=%@ ", kind]];
    if (start.location == NSNotFound) return @"";
    NSString *rest = [sdp substringFromIndex:start.location + 2];
    NSRange next = [rest rangeOfString:@"\r\nm="];
    return next.location == NSNotFound ? rest : [rest substringToIndex:next.location];
}

static BOOL Near(double value, double target) { return fabs(value - target) < target * 0.05; }

SN_SLOW_TEST(CallMediaLoopback) {
    // The audio host's factory comes first: it pays libwebrtc's process-wide setup, so what the
    // call adds after it is its own.
    double start = FootprintMB();
    SNTestAudioHost *host = [[SNTestAudioHost alloc] initWithFrequency:1000];
    double before = FootprintMB();
    SNToneDevice *tone = [[SNToneDevice alloc] initWithFrequency:440];
    SNCallMedia *media = [[SNCallMedia alloc] initWithICEServers:@[] audioDevice:tone loopbackOnly:YES];
    SNExpect(media != nil && SNCallMedia.isAvailable, "media with a synthetic device");
    SNExpect(media.muted, "the media starts muted");
    NSMutableArray<NSNumber *> *states = [NSMutableArray new];
    media.onStateChange = ^(SNCallMediaState state) { [states addObject:@(state)]; };

    __block NSString *offer;
    __block NSError *offerError;
    [media createOffer:^(NSString *sdp, NSError *error) {
        offer = sdp;
        offerError = error;
    }];
    SNExpect(SNWaitUntil(10, ^BOOL { return offer || offerError; }) && offer, "an offer once gathering finished");
    SNExpect([offer hasPrefix:@"v=0\r\no=mozilla-chrome "], "the origin is the one Chime's client sends");
    NSString *audio = Section(offer, @"audio"), *video = Section(offer, @"video");
    SNExpect([audio containsString:@"a=sendrecv"] && [audio containsString:@"opus/48000/2"], "audio is sent and received with Opus");
    SNExpect([audio containsString:@"maxaveragebitrate=40000"] && [audio containsString:@"useinbandfec=1"], "Opus at fullband speech's 40 kbps, with FEC");
    SNExpect([video containsString:@"a=inactive"], "an inactive video section, as Chime's client offers");
    SNExpect([offer containsString:@"a=group:BUNDLE 0 1"] && [audio containsString:@"a=rtcp-mux"], "one bundled transport, RTCP muxed");
    SNExpect([audio containsString:@" 127.0.0.1 "] && [audio containsString:@"typ host"] && ![offer containsString:@"typ srflx"], "candidates gathered into the offer, loopback only");

    __block NSString *answer;
    [host answerOffer:offer completion:^(NSString *sdp, NSError *error) { answer = sdp; }];
    SNExpect(SNWaitUntil(10, ^BOOL { return answer != nil; }), "the audio host answers");
    __block BOOL applied = NO;
    [media setAnswer:answer completion:^(NSError *error) { applied = error == nil; }];
    SNExpect(SNWaitUntil(5, ^BOOL { return applied; }), "the answer applies");
    SNExpect(SNWaitUntil(10, ^BOOL { return media.state == SNCallMediaConnected; }) && [states containsObject:@(SNCallMediaConnected)], "the media connects and says so");
    SNExpect(SNWaitUntil(10, ^BOOL { return Near(tone.playedFrequency, 1000); }), "the call plays the host's 1000 Hz");
    SNSettle(0.5);
    SNExpect(host.device.playedLevel < 0.01, "muted: the host hears nothing");
    media.muted = NO;
    SNExpect(SNWaitUntil(10, ^BOOL { return Near(host.device.playedFrequency, 440); }), "unmuted: the host hears the call's 440 Hz");
    printf("     footprint: +%.1f MB the first factory, +%.1f MB a connected call with its own\n", before - start, FootprintMB() - before);
    media.muted = YES;
    SNExpect(SNWaitUntil(5, ^BOOL { return host.device.playedLevel < 0.01; }), "muted again: silence");

    [media close];
    [media close];
    SNExpect(media.state == SNCallMediaClosed, "closed, twice");
    SNExpect(SNWaitUntil(5, ^BOOL { return !tone.isRecording && !tone.isPlaying; }), "closing stops the audio device");
    NSUInteger played = tone.playedFrames;
    SNSettle(0.2);
    SNExpect(tone.playedFrames == played, "nothing plays after closing");
    __block NSError *closedError;
    [media setAnswer:answer completion:^(NSError *error) { closedError = error; }];
    SNExpect(closedError != nil, "a closed media refuses answers");
    [host close];
}

/// Answers a TURN Allocate with 400, as a server that will not relay.
static void RefuseAllocate(int socket, const uint8_t *request, struct sockaddr_in from) {
    uint8_t response[28] = {0x01, 0x13, 0x00, 0x08};
    memcpy(response + 4, request + 4, 16);
    const uint8_t error[8] = {0x00, 0x09, 0x00, 0x04, 0x00, 0x00, 0x04, 0x00};
    memcpy(response + 20, error, sizeof error);
    sendto(socket, response, sizeof response, 0, (struct sockaddr *)&from, sizeof from);
}

SN_SLOW_TEST(CallMediaTURN) {
    int listener = socket(AF_INET, SOCK_DGRAM, 0);
    struct sockaddr_in address = {.sin_len = sizeof address, .sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
    socklen_t length = sizeof address;
    BOOL bound = bind(listener, (struct sockaddr *)&address, sizeof address) == 0 && getsockname(listener, (struct sockaddr *)&address, &length) == 0;
    SNExpect(bound, "a stand-in TURN server on a port of its own");
    if (!bound) return (void)close(listener);
    __block BOOL allocated = NO;
    dispatch_source_t reader = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)listener, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(reader, ^{
        uint8_t packet[1500];
        struct sockaddr_in from;
        socklen_t length = sizeof from;
        ssize_t size = recvfrom(listener, packet, sizeof packet, 0, (struct sockaddr *)&from, &length);
        // A STUN Allocate request: type 0x0003 and the magic cookie.
        if (size < 20 || packet[0] != 0x00 || packet[1] != 0x03 || packet[4] != 0x21 || packet[5] != 0x12 || packet[6] != 0xa4 || packet[7] != 0x42) return;
        allocated = YES;
        RefuseAllocate(listener, packet, from);
    });
    dispatch_resume(reader);

    SNICEServer *server = [SNICEServer new];
    server.urls = @[ [NSString stringWithFormat:@"turn:127.0.0.1:%d?transport=udp", ntohs(address.sin_port)] ];
    server.username = @"made-up-user";
    server.credential = @"made-up-password";
    SNCallMedia *media = [[SNCallMedia alloc] initWithICEServers:@[ server ] audioDevice:[[SNToneDevice alloc] initWithFrequency:0] loopbackOnly:YES];
    __block NSString *offer;
    __block NSError *offerError;
    [media createOffer:^(NSString *sdp, NSError *error) {
        offer = sdp;
        offerError = error;
    }];
    SNExpect(SNWaitUntil(5, ^BOOL { return allocated; }), "TURN goes to the server's UDP port");
    SNExpect(SNWaitUntil(7, ^BOOL { return offer || offerError; }) && !offer, "through TURN only: no relay, no candidates, no offer");
    [media close];
    dispatch_source_cancel(reader);
    close(listener);
}

#else

SN_TEST(CallMediaUnavailable) {
    SNExpect(!SNCallMedia.isAvailable && ![[SNCallMedia alloc] initWithICEServers:@[] audioDevice:nil], "without libwebrtc there is no call media");
}

#endif
