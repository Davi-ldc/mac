// The protobuf wire format and Chime's signalling frames: round trips, unknown and malformed
// fields, the client's frames byte for byte (expected bytes worked out from SignalingProtocol.proto
// apart from the encoder), and server frames built field by field. Values are made up.
#import "call/frames.h"
#import "call/protobuf.h"
#import "test.h"

static NSData *Hex(NSString *hex) {
    NSMutableData *data = [NSMutableData new];
    for (NSUInteger i = 0; i + 1 < hex.length; i += 2) {
        uint8_t byte = (uint8_t)strtoul([hex substringWithRange:NSMakeRange(i, 2)].UTF8String, NULL, 16);
        [data appendBytes:&byte length:1];
    }
    return data;
}

/// A server frame: the type byte, then timestamp, type and the frame field built by `build`.
static NSData *ServerFrame(uint32_t type, uint32_t field, void (^build)(SNProtoWriter *frame)) {
    SNProtoWriter *writer = [SNProtoWriter new];
    [writer writeVarint:1700000000123 field:1];
    [writer writeVarint:type field:2];
    if (build) [writer writeMessageField:field build:build];
    NSMutableData *message = [NSMutableData dataWithBytes:"\x05" length:1];
    [message appendData:writer.data];
    return message;
}

SN_TEST(ChimeProtobufVarintsRoundTrip) {
    const uint64_t values[] = {0, 1, 127, 128, 300, UINT32_MAX, UINT64_MAX};
    SNProtoWriter *writer = [SNProtoWriter new];
    for (uint32_t i = 0; i < 7; i++) [writer writeVarint:values[i] field:i + 1];
    [writer writeString:@"água" field:8];
    [writer writeBool:YES field:9];
    SNProtoReader *reader = [[SNProtoReader alloc] initWithData:writer.data];
    for (uint32_t i = 0; i < 7; i++) {
        SNExpect([reader next] && reader.field == i + 1 && reader.wireType == SNProtoVarint, "varint field in order");
        SNExpect(reader.value == values[i], "varint value kept");
    }
    SNExpect([reader next] && [reader.string isEqualToString:@"água"], "UTF-8 string kept");
    SNExpect([reader next] && reader.value == 1, "bool as varint 1");
    SNExpect(![reader next] && !reader.malformed, "ends cleanly");

    SNProtoWriter *three = [SNProtoWriter new];
    [three writeVarint:300 field:1];
    SNExpect([three.data isEqualToData:Hex(@"08ac02")], "300 is ac 02");
}

SN_TEST(ChimeProtobufSkipsUnknownWireTypes) {
    // field 1 fixed64, field 2 fixed32, field 3 bytes, field 4 varint, as another encoder writes them.
    NSData *data = Hex(@"09efcdab89674523011578563412" @"1a03616263" @"2096");
    SNProtoReader *reader = [[SNProtoReader alloc] initWithData:[data subdataWithRange:NSMakeRange(0, data.length - 1)]];
    SNExpect([reader next] && reader.wireType == SNProtoFixed64 && reader.value == 0x0123456789abcdefULL, "fixed64 little-endian");
    SNExpect([reader next] && reader.wireType == SNProtoFixed32 && reader.value == 0x12345678, "fixed32 little-endian");
    SNExpect([reader next] && [reader.bytes isEqualToData:Hex(@"616263")], "length-delimited contents");
    SNExpect(![reader next] && reader.malformed, "a varint cut short is malformed");

    SNProtoReader *nested = [[SNProtoReader alloc] initWithData:Hex(@"0a0408011002" @"1001")];
    SNExpect([nested next] && nested.field == 1 && nested.bytes.length == 4, "nested message as bytes");
    SNProtoReader *inner = [[SNProtoReader alloc] initWithData:nested.bytes];
    SNExpect([inner next] && inner.value == 1 && [inner next] && inner.value == 2 && ![inner next], "nested fields read");
    SNExpect([nested next] && nested.field == 2 && ![nested next] && !nested.malformed, "fields after the nested one");
}

SN_TEST(ChimeProtobufRefusesMalformed) {
    for (NSString *hex in @[ @"0a05616263", @"0b00", @"00", @"ffffffffffffffffffff01" ]) {
        SNProtoReader *reader = [[SNProtoReader alloc] initWithData:Hex(hex)];
        while ([reader next]) {}
        SNExpect(reader.malformed, "overlong length, group, field 0 and an 11-byte key are malformed");
    }
}

SN_TEST(ChimeClientFramesByteForByte) {
    SNChimeClientDetails *details = [SNChimeClientDetails new];
    details.platformName = @"chrome";
    details.platformVersion = @"158";
    details.clientSource = @"sdk";
    details.sdkVersion = @"3.32.0";
    details.utcOffset = @"-03:00";
    details.osName = @"Mac OS";
    details.osVersion = @"15.1";
    SNExpect([SNChimeJoinMessage(1, 0x1234, details) isEqualToData:Hex(@"0508011001223d0802180222302a066368726f6d6532033135383a0373646b42"
                                                                        @"06332e33322e304a062d30333a303052064d6163204f535a0431352e3130b42438005001")],
             "JOIN: protocol 2, HAS_STREAM_UPDATE, client details, audio session, no compression, DEFAULT adaption");
    SNExpect([SNChimeSubscribeMessage(1, @"v=0", @"h", @"a1", YES) isEqualToData:Hex(@"0508011003323c0801122c0801100f18d8042217416d617a6f6e4368696d65"
                                                                                       @"45787072657373417564696f30013880b5184202613148012203763d302a016830003801")],
             "SUBSCRIBE: RX, the SDK's audio stream, offer, host, no checkin, muted");
    SNExpect([SNChimeLeaveMessage(1) isEqualToData:Hex(@"05080110095a00")], "LEAVE with an empty leave frame");
    SNExpect([SNChimeAudioControlMessage(1, YES) isEqualToData:Hex(@"05080110108a01020801")], "AUDIO_CONTROL muted");
    SNExpect([SNChimePingPongMessage(1, 7, NO) isEqualToData:Hex(@"0508011013a2010408011007")], "PING 7");

    SNChimeClientDetails *current = SNChimeClientDetails.current;
    SNExpect([current.clientSource isEqualToString:@"amazon-chime-sdk-js"] && [current.sdkVersion isEqualToString:@"3.32.0"], "reports the SDK Slack ships");
}

SN_TEST(ChimeDecodesJoinAckWithTURN) {
    NSData *message = ServerFrame(2, 5, ^(SNProtoWriter *ack) {
        [ack writeMessageField:1 build:^(SNProtoWriter *turn) {
            [turn writeString:@"made-up-user" field:1];
            [turn writeString:@"made-up-pass" field:2];
            [turn writeVarint:86400 field:3];
            [turn writeString:@"turn:turn.example.invalid:3478?transport=udp" field:4];
            [turn writeString:@"turns:turn.example.invalid:443?transport=tcp" field:4];
            [turn writeVarint:9 field:15];
        }];
        [ack writeVarint:25 field:2];
        [ack writeBool:NO field:3];
        [ack writeVarint:1 field:4];
    });
    SNChimeFrame *frame = [SNChimeFrame frameWithMessage:message];
    SNExpect(frame.type == SNChimeFrameJoinAck && frame.timestamp == 1700000000123, "JOIN_ACK and its timestamp");
    SNExpect([frame.turn.username isEqualToString:@"made-up-user"] && [frame.turn.password isEqualToString:@"made-up-pass"] && frame.turn.ttl == 86400, "TURN credentials");
    NSArray *uris = @[ @"turn:turn.example.invalid:3478?transport=udp", @"turns:turn.example.invalid:443?transport=tcp" ];
    SNExpect([frame.turn.uris isEqualToArray:uris], "both URIs, in order");
    SNExpect([SNChimeFrame frameWithMessage:ServerFrame(2, 5, ^(SNProtoWriter *ack) { [ack writeVarint:25 field:2]; })].turn == nil, "no TURN when JOIN_ACK has none");
}

SN_TEST(ChimeDecodesSubscribeAckAndStatus) {
    SNChimeFrame *ack = [SNChimeFrame frameWithMessage:ServerFrame(4, 7, ^(SNProtoWriter *frame) {
        [frame writeVarint:1 field:1];
        [frame writeMessageField:2 build:^(SNProtoWriter *allocation) { [allocation writeVarint:1 field:2]; }];
        [frame writeString:@"v=0\r\n" field:3];
    })];
    SNExpect(ack.type == SNChimeFrameSubscribeAck && [ack.sdpAnswer isEqualToString:@"v=0\r\n"] && !ack.compressedAnswer, "answer read");
    SNChimeFrame *compressed = [SNChimeFrame frameWithMessage:ServerFrame(4, 7, ^(SNProtoWriter *frame) { [frame writeBytes:Hex(@"0102") field:5]; })];
    SNExpect(compressed.compressedAnswer && !compressed.sdpAnswer, "a compressed-only answer is told apart");

    SNChimeFrame *status = [SNChimeFrame frameWithMessage:ServerFrame(20, 21, ^(SNProtoWriter *frame) { [frame writeVarint:410 field:1]; })];
    SNExpect(status.type == SNChimeFrameAudioStatus && status.audioStatus == 410, "AUDIO_STATUS 410");
    SNChimeFrame *error = [SNChimeFrame frameWithMessage:ServerFrame(34, 3, ^(SNProtoWriter *frame) {
        [frame writeVarint:403 field:1];
        [frame writeString:@"made-up" field:2];
    })];
    SNExpect(error.errorStatus == 403 && [error.errorDescription isEqualToString:@"made-up"], "an error frame's status on any frame");
    SNChimeFrame *pong = [SNChimeFrame frameWithMessage:ServerFrame(19, 20, ^(SNProtoWriter *frame) {
        [frame writeVarint:2 field:1];
        [frame writeVarint:42 field:2];
    })];
    SNExpect(pong.isPong && pong.pingID == 42, "PONG 42");
    SNExpect([SNChimeFrame frameWithMessage:ServerFrame(10, 12, ^(SNProtoWriter *frame) {})].type == SNChimeFrameLeaveAck, "LEAVE_ACK");
}

SN_TEST(ChimeDecodesAudioMetadataAndStreams) {
    SNChimeFrame *info = [SNChimeFrame frameWithMessage:ServerFrame(18, 19, ^(SNProtoWriter *frame) {
        [frame writeMessageField:1 build:^(SNProtoWriter *stream) {
            [stream writeVarint:3 field:1];
            [stream writeString:@"attendee-a" field:2];
            [stream writeBool:YES field:3];
            [stream writeString:@"T0-R0-U0" field:4];
        }];
        [frame writeMessageField:1 build:^(SNProtoWriter *stream) {
            [stream writeVarint:4 field:1];
            [stream writeBool:YES field:5];
        }];
    })];
    SNExpect(info.streams.count == 2, "two stream entries");
    SNChimeStreamInfo *first = info.streams.firstObject, *second = info.streams.lastObject;
    SNExpect(first.audioStreamID == 3 && [first.attendeeID isEqualToString:@"attendee-a"] && [first.externalUserID isEqualToString:@"T0-R0-U0"] && first.hasMuted && first.muted, "named stream");
    SNExpect(second.audioStreamID == 4 && !second.attendeeID && !second.hasMuted && second.dropped, "removed stream, dropped");

    SNChimeFrame *metadata = [SNChimeFrame frameWithMessage:ServerFrame(17, 18, ^(SNProtoWriter *frame) {
        [frame writeMessageField:1 build:^(SNProtoWriter *state) {
            [state writeVarint:3 field:1];
            [state writeVarint:20 field:2];
            [state writeVarint:2 field:4];
        }];
        [frame writeMessageField:1 build:^(SNProtoWriter *state) { [state writeVarint:4 field:1]; }];
    })];
    SNChimeAudioLevel *loud = metadata.levels.firstObject, *bare = metadata.levels.lastObject;
    SNExpect(metadata.levels.count == 2 && loud.hasVolume && loud.volume == 20 && loud.hasSignalStrength && loud.signalStrength == 2, "level with volume and signal");
    SNExpect(!bare.hasVolume && !bare.hasSignalStrength, "level without either");

    SNExpect(SNChimeNormalizedVolume(14) == 1 && SNChimeNormalizedVolume(42) == 0 && SNChimeNormalizedVolume(28) == 0.5, "14 dB full, 42 silent");
    SNExpect(SNChimeNormalizedVolume(0) == 1 && SNChimeNormalizedVolume(90) == 0, "clamped");
}

SN_TEST(ChimeRefusesUndecodableFrames) {
    SNExpect(![SNChimeFrame frameWithMessage:[NSData data]], "empty message");
    SNExpect(![SNChimeFrame frameWithMessage:Hex(@"05ffff")], "garbage");
    SNExpect(![SNChimeFrame frameWithMessage:Hex(@"050801")], "no type");
    SNExpect([SNChimeFrame frameWithMessage:Hex(@"0210050801")].type == SNChimeFrameIndex, "type byte 2 read like 5");
}

SN_TEST(ChimeSignalingURLAndOffset) {
    NSURL *url = SNChimeSignalingURL([NSURL URLWithString:@"wss://signal.example.invalid/control/made-up"]);
    SNExpect([url.absoluteString isEqualToString:@"wss://signal.example.invalid/control/made-up?X-Chime-Control-Protocol-Version=3"
                                                  @"&X-Amzn-Chime-Send-Close-On-Error=1&X-Amzn-Version=3.32.0&X-Amzn-User-Agent=chrome-158"],
             "the SDK's query");
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:1700000000];
    SNExpect([SNChimeUTCOffset([NSTimeZone timeZoneForSecondsFromGMT:-3 * 3600], date) isEqualToString:@"-03:00"], "behind UTC");
    SNExpect([SNChimeUTCOffset([NSTimeZone timeZoneForSecondsFromGMT:5 * 3600 + 1800], date) isEqualToString:@"+05:30"], "ahead with minutes");
    SNExpect([SNChimeUTCOffset([NSTimeZone timeZoneForSecondsFromGMT:0], date) isEqualToString:@"+00:00"], "UTC");
}
