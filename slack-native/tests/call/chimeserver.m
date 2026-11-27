// Owns the test Chime signalling server. It encodes and decodes frames on its own, from the proto's
// field numbers, so the client's encoder and decoder are checked against a second reading of it.
#import "../live/server.h"
#import "call/frames.h"
#import "call/protobuf.h"
#import "chimeserver.h"

/// Field number -> @[name, kind]: kind is @"v" (varint), @"b" (bool), @"s" (string) or a nested
/// schema; a name starting with "*" is repeated.
typedef NSDictionary<NSNumber *, NSArray *> Schema;

static Schema *FrameSchema(void) {
    static Schema *frame;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Schema *details = @{@1 : @[ @"app_name", @"s" ], @2 : @[ @"app_version", @"s" ], @3 : @[ @"device_model", @"s" ],
                            @4 : @[ @"device_make", @"s" ], @5 : @[ @"platform_name", @"s" ], @6 : @[ @"platform_version", @"s" ],
                            @7 : @[ @"client_source", @"s" ], @8 : @[ @"chime_sdk_version", @"s" ], @9 : @[ @"client_utc_offset", @"s" ],
                            @10 : @[ @"os_name", @"s" ], @11 : @[ @"os_version", @"s" ]};
        Schema *join = @{@1 : @[ @"protocol_version", @"v" ], @2 : @[ @"max_num_of_videos", @"v" ], @3 : @[ @"flags", @"v" ],
                         @4 : @[ @"client_details", details ], @6 : @[ @"audio_session_id", @"v" ], @7 : @[ @"wants_compressed_sdp", @"b" ],
                         @10 : @[ @"server_side_network_adaption", @"v" ], @11 : @[ @"*supported_server_side_network_adaptions", @"v" ],
                         @12 : @[ @"wants_all_temporal_layers_in_index", @"b" ], @13 : @[ @"disable_periodic_keyframe_request_on_content_sender", @"b" ]};
        Schema *stream = @{@1 : @[ @"stream_id", @"v" ], @2 : @[ @"framerate", @"v" ], @3 : @[ @"max_bitrate_kbps", @"v" ],
                           @4 : @[ @"track_label", @"s" ], @6 : @[ @"group_id", @"v" ], @7 : @[ @"avg_bitrate_bps", @"v" ],
                           @8 : @[ @"attendee_id", @"s" ], @9 : @[ @"media_type", @"v" ], @10 : @[ @"external_user_id", @"s" ],
                           @11 : @[ @"width", @"v" ], @12 : @[ @"height", @"v" ]};
        Schema *subscribe = @{@1 : @[ @"duplex", @"v" ], @2 : @[ @"*send_streams", stream ], @3 : @[ @"*receive_stream_ids", @"v" ],
                              @4 : @[ @"sdp_offer", @"s" ], @5 : @[ @"audio_host", @"s" ], @6 : @[ @"audio_checkin", @"b" ],
                              @7 : @[ @"audio_muted", @"b" ], @8 : @[ @"compressed_sdp_offer", @"s" ]};
        frame = @{@1 : @[ @"timestamp_ms", @"v" ], @2 : @[ @"type", @"v" ], @4 : @[ @"join", join ], @6 : @[ @"sub", subscribe ],
                  @11 : @[ @"leave", @{} ], @17 : @[ @"audio_control", @{@1 : @[ @"muted", @"b" ]} ],
                  @20 : @[ @"ping_pong", @{@1 : @[ @"type", @"v" ], @2 : @[ @"ping_id", @"v" ]} ]};
    });
    return frame;
}

static NSDictionary *Decode(NSData *data, Schema *schema) {
    NSMutableDictionary *decoded = [NSMutableDictionary new];
    SNProtoReader *reader = [[SNProtoReader alloc] initWithData:data];
    while ([reader next]) {
        NSArray *entry = schema[@(reader.field)];
        NSString *name = entry[0] ?: [NSString stringWithFormat:@"field%u", reader.field];
        id kind = entry[1];
        id value = [kind isKindOfClass:NSDictionary.class] ? (reader.bytes ? Decode(reader.bytes, kind) : nil)
                   : [kind isEqual:@"s"]                    ? reader.string
                   : [kind isEqual:@"b"]                    ? @(reader.value != 0)
                                                            : (id)(reader.bytes ?: @(reader.value));
        if (!value) continue;
        if ([name hasPrefix:@"*"]) {
            name = [name substringFromIndex:1];
            decoded[name] = [decoded[name] ?: @[] arrayByAddingObject:value];
        } else {
            decoded[name] = value;
        }
    }
    if (reader.malformed) decoded[@"malformed"] = @YES;
    return decoded;
}

/// A server frame of `type` with the frame field `field` built by `build` (nil: none), as a message.
static NSData *Message(SNChimeFrameType type, uint32_t field, void (^build)(SNProtoWriter *frame)) {
    SNProtoWriter *writer = [SNProtoWriter new];
    [writer writeVarint:(uint64_t)(NSDate.date.timeIntervalSince1970 * 1000) field:1];
    [writer writeVarint:type field:2];
    if (build) [writer writeMessageField:field build:build];
    NSMutableData *message = [NSMutableData dataWithBytes:&SNChimeFrameTypeRTC length:1];
    [message appendData:writer.data];
    return message;
}

/// Writes the keys of `values` that `fields` names (key -> field number) as varints, strings or
/// bools, as their values are.
static void WriteFields(SNProtoWriter *writer, NSDictionary *values, NSDictionary<NSString *, NSNumber *> *fields) {
    for (NSString *key in [fields keysSortedByValueUsingSelector:@selector(compare:)]) {
        id value = values[key];
        uint32_t field = fields[key].unsignedIntValue;
        if ([value isKindOfClass:NSString.class]) [writer writeString:value field:field];
        else if ([value isKindOfClass:NSNumber.class]) [writer writeVarint:[value unsignedLongLongValue] field:field];
    }
}

@implementation SNTestChimeServer {
    SNTestSocketServer *_server;
    NSMutableArray<NSDictionary *> *_received;
}

+ (instancetype)start {
    SNTestSocketServer *server = [SNTestSocketServer start];
    if (!server) return nil;
    SNTestChimeServer *chime = [self new];
    chime->_server = server;
    chime->_received = [NSMutableArray new];
    chime.answersJoin = chime.answersPings = chime.acksLeave = YES;
    server.subprotocol = @"_aws_wt_session";
    __weak SNTestChimeServer *weakChime = chime;
    server.onData = ^(NSData *message) { [weakChime received:message]; };
    return chime;
}

- (NSURL *)url { return [NSURL URLWithString:[_server.url stringByAppendingString:@"control/made-up-meeting"]]; }
- (NSUInteger)connectionCount { return _server.connectionCount; }
- (NSArray *)handshakes { return _server.handshakes; }
- (NSArray *)received { return [_received copy]; }

- (NSArray *)receivedOfType:(NSString *)type {
    return [_received filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"type == %@", type]];
}

- (void)received:(NSData *)message {
    if (message.length < 1) return;
    NSMutableDictionary *frame = [Decode([message subdataWithRange:NSMakeRange(1, message.length - 1)], FrameSchema()) mutableCopy];
    SNChimeFrameType type = (SNChimeFrameType)[frame[@"type"] unsignedIntValue];
    frame[@"type"] = SNChimeFrameName(type);
    frame[@"prefix"] = @(((const uint8_t *)message.bytes)[0]);
    [_received addObject:frame];
    if (type == SNChimeFrameJoin && self.answersJoin) [self answerJoin];
    else if (type == SNChimeFrameSubscribe) [self answerSubscribe:frame[@"sub"][@"sdp_offer"] ?: @""];
    else if (type == SNChimeFramePingPong && self.answersPings && [frame[@"ping_pong"][@"type"] isEqual:@1]) {
        uint32_t pingID = [frame[@"ping_pong"][@"ping_id"] unsignedIntValue];
        [_server sendData:Message(SNChimeFramePingPong, 20, ^(SNProtoWriter *pong) {
            [pong writeVarint:2 field:1];
            [pong writeVarint:pingID field:2];
        })];
    } else if (type == SNChimeFrameLeave && self.acksLeave) [_server sendData:Message(SNChimeFrameLeaveAck, 12, ^(SNProtoWriter *ack) {})];
}

- (void)answerJoin {
    NSDictionary *turn = self.turn;
    [_server sendData:Message(SNChimeFrameJoinAck, 5, ^(SNProtoWriter *ack) {
        if (turn)
            [ack writeMessageField:1 build:^(SNProtoWriter *credentials) {
                WriteFields(credentials, turn, @{@"username" : @1, @"password" : @2, @"ttl" : @3});
                for (NSString *uri in turn[@"uris"]) [credentials writeString:uri field:4];
            }];
        [ack writeVarint:25 field:2];
    })];
    [_server sendData:Message(SNChimeFrameIndex, 8, ^(SNProtoWriter *index) { [index writeVarint:1 field:4]; })];
}

- (void)answerSubscribe:(NSString *)offer {
    __weak SNTestSocketServer *server = _server;
    void (^reply)(NSString *) = ^(NSString *answer) {
        [server sendData:Message(SNChimeFrameSubscribeAck, 7, ^(SNProtoWriter *ack) {
            [ack writeVarint:1 field:1];
            [ack writeString:answer field:3];
        })];
    };
    if (self.answerOffer) self.answerOffer(offer, reply);
    else reply(@"v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\n");
}

- (void)sendStreams:(NSArray<NSDictionary *> *)streams {
    [_server sendData:Message(SNChimeFrameAudioStreamIDInfo, 19, ^(SNProtoWriter *info) {
        for (NSDictionary *stream in streams)
            [info writeMessageField:1 build:^(SNProtoWriter *entry) {
                WriteFields(entry, stream, @{@"audio_stream_id" : @1, @"attendee_id" : @2, @"muted" : @3, @"external_user_id" : @4, @"dropped" : @5});
            }];
    })];
}

- (void)sendLevels:(NSArray<NSDictionary *> *)levels {
    [_server sendData:Message(SNChimeFrameAudioMetadata, 18, ^(SNProtoWriter *metadata) {
        for (NSDictionary *level in levels)
            [metadata writeMessageField:1 build:^(SNProtoWriter *state) {
                WriteFields(state, level, @{@"audio_stream_id" : @1, @"volume" : @2, @"muted" : @3, @"signal_strength" : @4});
            }];
    })];
}

- (void)sendAudioStatus:(uint32_t)status {
    [_server sendData:Message(SNChimeFrameAudioStatus, 21, ^(SNProtoWriter *frame) { [frame writeVarint:status field:1]; })];
}

- (void)sendErrorStatus:(uint32_t)status {
    [_server sendData:Message(SNChimeFrameNotification, 3, ^(SNProtoWriter *error) {
        [error writeVarint:status field:1];
        [error writeString:@"made-up failure" field:2];
    })];
}

- (void)sendPing:(uint32_t)pingID {
    [_server sendData:Message(SNChimeFramePingPong, 20, ^(SNProtoWriter *ping) {
        [ping writeVarint:1 field:1];
        [ping writeVarint:pingID field:2];
    })];
}

- (void)closeWithCode:(uint16_t)code { [_server closeWithCode:code]; }
- (void)dropConnection { [_server dropConnection]; }
- (void)stop { [_server stop]; }

@end
