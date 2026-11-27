// Owns encoding and decoding Chime's signalling frames. Field numbers are SignalingProtocol.proto's.
#import "call/frames.h"
#import "call/protobuf.h"

/// SdkSignalFrame's fields.
enum {
    kTimestamp = 1, kType = 2, kError = 3, kJoin = 4, kJoinAck = 5, kSubscribe = 6, kSubscribeAck = 7,
    kLeave = 11, kAudioControl = 17, kAudioMetadata = 18, kAudioStreamIDInfo = 19, kPingPong = 20,
    kAudioStatus = 21, kNotification = 35,
};

/// SdkJoinFlags.HAS_STREAM_UPDATE, the one flag the SDK sets.
static const uint32_t kHasStreamUpdate = 2;
/// SdkStreamServiceType.RX: the SDK's duplex unless it sends video (it is about video only).
static const uint32_t kReceive = 1;
/// SdkServerSideNetworkAdaption.DEFAULT.
static const uint32_t kDefaultAdaption = 1;

NSString *SNChimeFrameName(SNChimeFrameType type) {
    static NSDictionary<NSNumber *, NSString *> *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = @{@(SNChimeFrameJoin) : @"JOIN", @(SNChimeFrameJoinAck) : @"JOIN_ACK", @(SNChimeFrameSubscribe) : @"SUBSCRIBE",
                  @(SNChimeFrameSubscribeAck) : @"SUBSCRIBE_ACK", @(SNChimeFrameIndex) : @"INDEX", @(SNChimeFrameLeave) : @"LEAVE",
                  @(SNChimeFrameLeaveAck) : @"LEAVE_ACK", @(SNChimeFrameBitrates) : @"BITRATES", @(SNChimeFrameAudioControl) : @"AUDIO_CONTROL",
                  @(SNChimeFrameAudioMetadata) : @"AUDIO_METADATA", @(SNChimeFrameAudioStreamIDInfo) : @"AUDIO_STREAM_ID_INFO",
                  @(SNChimeFramePingPong) : @"PING_PONG", @(SNChimeFrameAudioStatus) : @"AUDIO_STATUS", @(SNChimeFrameNotification) : @"NOTIFICATION"};
    });
    return names[@(type)] ?: @(type).stringValue;
}

@implementation SNChimeClientDetails

+ (instancetype)current {
    SNChimeClientDetails *details = [self new];
    // The media engine is Chrome's (libwebrtc M158, scripts/webrtc.sh), which is what Chime tunes
    // its answers for; Slack's desktop client reports Chrome too.
    details.platformName = @"chrome";
    details.platformVersion = @"158.0.0.0";
    details.clientSource = @"amazon-chime-sdk-js";
    details.sdkVersion = @"3.32.0";
    details.utcOffset = SNChimeUTCOffset(NSTimeZone.localTimeZone, NSDate.date);
    details.osName = @"Mac OS";
    NSOperatingSystemVersion os = NSProcessInfo.processInfo.operatingSystemVersion;
    details.osVersion = [NSString stringWithFormat:@"%ld.%ld.%ld", (long)os.majorVersion, (long)os.minorVersion, (long)os.patchVersion];
    return details;
}

@end

NSString *SNChimeUTCOffset(NSTimeZone *zone, NSDate *date) {
    NSInteger seconds = [zone secondsFromGMTForDate:date], minutes = labs(seconds) / 60;
    return [NSString stringWithFormat:@"%@%02ld:%02ld", seconds >= 0 ? @"+" : @"-", (long)(minutes / 60), (long)(minutes % 60)];
}

/// One SdkSignalFrame of `type` whose frame field `field` `build` writes, as a websocket message.
static NSData *Message(uint64_t timestamp, SNChimeFrameType type, uint32_t field, void (^build)(SNProtoWriter *frame)) {
    SNProtoWriter *writer = [SNProtoWriter new];
    [writer writeVarint:timestamp field:kTimestamp];
    [writer writeVarint:type field:kType];
    [writer writeMessageField:field build:build];
    NSMutableData *message = [NSMutableData dataWithBytes:&SNChimeFrameTypeRTC length:1];
    [message appendData:writer.data];
    return message;
}

NSData *SNChimeJoinMessage(uint64_t timestamp, uint32_t audioSessionID, SNChimeClientDetails *details) {
    return Message(timestamp, SNChimeFrameJoin, kJoin, ^(SNProtoWriter *join) {
        [join writeVarint:2 field:1];
        [join writeVarint:kHasStreamUpdate field:3];
        [join writeMessageField:4 build:^(SNProtoWriter *client) {
            NSArray *values = @[ details.platformName ?: NSNull.null, details.platformVersion ?: NSNull.null, details.clientSource ?: NSNull.null,
                                 details.sdkVersion ?: NSNull.null, details.utcOffset ?: NSNull.null, details.osName ?: NSNull.null,
                                 details.osVersion ?: NSNull.null ];
            // platform_name is field 5; the ones before it (app and device) the SDK leaves out here.
            for (NSUInteger i = 0; i < values.count; i++)
                if (values[i] != NSNull.null) [client writeString:values[i] field:(uint32_t)(5 + i)];
        }];
        [join writeVarint:audioSessionID field:6];
        [join writeBool:NO field:7];
        [join writeVarint:kDefaultAdaption field:10];
    });
}

NSData *SNChimeSubscribeMessage(uint64_t timestamp, NSString *sdpOffer, NSString *audioHost, NSString *attendeeID, BOOL muted) {
    return Message(timestamp, SNChimeFrameSubscribe, kSubscribe, ^(SNProtoWriter *subscribe) {
        [subscribe writeVarint:kReceive field:1];
        // The SDK's one audio stream descriptor, with its fixed values.
        [subscribe writeMessageField:2 build:^(SNProtoWriter *stream) {
            [stream writeVarint:1 field:1];
            [stream writeVarint:15 field:2];
            [stream writeVarint:600 field:3];
            [stream writeString:@"AmazonChimeExpressAudio" field:4];
            [stream writeVarint:1 field:6];
            [stream writeVarint:400000 field:7];
            [stream writeString:attendeeID field:8];
            [stream writeVarint:1 field:9];
        }];
        [subscribe writeString:sdpOffer field:4];
        [subscribe writeString:audioHost field:5];
        [subscribe writeBool:NO field:6];
        [subscribe writeBool:muted field:7];
    });
}

NSData *SNChimeAudioControlMessage(uint64_t timestamp, BOOL muted) {
    return Message(timestamp, SNChimeFrameAudioControl, kAudioControl, ^(SNProtoWriter *control) { [control writeBool:muted field:1]; });
}

NSData *SNChimePingPongMessage(uint64_t timestamp, uint32_t pingID, BOOL pong) {
    return Message(timestamp, SNChimeFramePingPong, kPingPong, ^(SNProtoWriter *ping) {
        [ping writeVarint:pong ? 2 : 1 field:1];
        [ping writeVarint:pingID field:2];
    });
}

NSData *SNChimeLeaveMessage(uint64_t timestamp) {
    return Message(timestamp, SNChimeFrameLeave, kLeave, ^(SNProtoWriter *leave) {});
}

double SNChimeNormalizedVolume(uint32_t volume) { return MIN(MAX((42.0 - volume) / (42.0 - 14.0), 0), 1); }

@implementation SNChimeStreamInfo

+ (instancetype)infoWithData:(NSData *)data {
    SNChimeStreamInfo *info = [self new];
    SNProtoReader *reader = [[SNProtoReader alloc] initWithData:data];
    while ([reader next]) {
        switch (reader.field) {
            case 1: info->_audioStreamID = (uint32_t)reader.value; break;
            case 2: info->_attendeeID = reader.string.length ? reader.string : nil; break;
            case 3: info->_hasMuted = YES, info->_muted = reader.value != 0; break;
            case 4: info->_externalUserID = reader.string.length ? reader.string : nil; break;
            case 5: info->_dropped = reader.value != 0; break;
        }
    }
    return reader.malformed ? nil : info;
}

@end

@implementation SNChimeAudioLevel

+ (instancetype)levelWithData:(NSData *)data {
    SNChimeAudioLevel *level = [self new];
    SNProtoReader *reader = [[SNProtoReader alloc] initWithData:data];
    while ([reader next]) {
        switch (reader.field) {
            case 1: level->_audioStreamID = (uint32_t)reader.value; break;
            case 2: level->_hasVolume = YES, level->_volume = (uint32_t)reader.value; break;
            case 4: level->_hasSignalStrength = YES, level->_signalStrength = (uint32_t)reader.value; break;
        }
    }
    return reader.malformed ? nil : level;
}

@end

/// Calls `field` for each field of a nested message; NO when it does not decode.
static BOOL ReadFields(NSData *data, void (^field)(SNProtoReader *reader)) {
    SNProtoReader *reader = [[SNProtoReader alloc] initWithData:data];
    while ([reader next]) field(reader);
    return !reader.malformed;
}

/// The repeated nested messages `number` of `data`, each decoded by `decode`; nil when one fails.
static NSArray *Repeated(NSData *data, uint32_t number, id (^decode)(NSData *item)) {
    NSMutableArray *items = [NSMutableArray new];
    __block BOOL failed = NO;
    BOOL ok = ReadFields(data, ^(SNProtoReader *reader) {
        if (reader.field != number || !reader.bytes) return;
        id item = decode(reader.bytes);
        if (item) [items addObject:item];
        else failed = YES;
    });
    return ok && !failed ? items : nil;
}

@implementation SNChimeFrame

+ (instancetype)frameWithMessage:(NSData *)message {
    // The type byte is not checked: the SDK reads whatever follows it, only warning when it is
    // neither 5 nor 2.
    if (message.length < 1) return nil;
    SNChimeFrame *frame = [self new];
    frame->_streams = @[];
    frame->_levels = @[];
    SNProtoReader *reader = [[SNProtoReader alloc] initWithData:[message subdataWithRange:NSMakeRange(1, message.length - 1)]];
    BOOL typed = NO, ok = YES;
    while (ok && [reader next]) {
        NSData *bytes = reader.bytes;
        uint32_t field = reader.field;
        if (field == kTimestamp) frame->_timestamp = reader.value;
        else if (field == kType) {
            frame->_type = (SNChimeFrameType)reader.value;
            typed = YES;
        } else if (field == kError) {
            ok = bytes && ReadFields(bytes, ^(SNProtoReader *error) {
                if (error.field == 1) frame->_errorStatus = (uint32_t)error.value;
                if (error.field == 2) frame->_errorDescription = error.string;
            });
        } else if (field == kJoinAck) {
            ok = bytes && ReadFields(bytes, ^(SNProtoReader *ack) {
                if (ack.field == 1 && ack.bytes) frame->_turn = [self turnWithData:ack.bytes];
            });
        } else if (field == kSubscribeAck) {
            ok = bytes && ReadFields(bytes, ^(SNProtoReader *ack) {
                if (ack.field == 3) frame->_sdpAnswer = ack.string;
                if (ack.field == 5 && ack.bytes.length) frame->_compressedAnswer = YES;
            });
        } else if (field == kPingPong) {
            ok = bytes && ReadFields(bytes, ^(SNProtoReader *ping) {
                if (ping.field == 1) frame->_isPong = ping.value == 2;
                if (ping.field == 2) frame->_pingID = (uint32_t)ping.value;
            });
        } else if (field == kAudioStatus) {
            ok = bytes && ReadFields(bytes, ^(SNProtoReader *status) {
                if (status.field == 1) frame->_audioStatus = (uint32_t)status.value;
            });
        } else if (field == kAudioStreamIDInfo) {
            NSArray *streams = bytes ? Repeated(bytes, 1, ^id(NSData *item) { return [SNChimeStreamInfo infoWithData:item]; }) : nil;
            ok = streams != nil;
            frame->_streams = streams ?: @[];
        } else if (field == kAudioMetadata) {
            NSArray *levels = bytes ? Repeated(bytes, 1, ^id(NSData *item) { return [SNChimeAudioLevel levelWithData:item]; }) : nil;
            ok = levels != nil;
            frame->_levels = levels ?: @[];
        } else if (field == kNotification) {
            ok = bytes && ReadFields(bytes, ^(SNProtoReader *notification) {
                if (notification.field == 2) frame->_notification = notification.string;
            });
        }
    }
    return ok && !reader.malformed && typed ? frame : nil;
}

+ (SNChimeTURN *)turnWithData:(NSData *)data {
    SNChimeTURN *turn = [SNChimeTURN new];
    NSMutableArray<NSString *> *uris = [NSMutableArray new];
    turn.username = turn.password = @"";
    BOOL ok = ReadFields(data, ^(SNProtoReader *reader) {
        if (reader.field == 1) turn.username = reader.string ?: @"";
        if (reader.field == 2) turn.password = reader.string ?: @"";
        if (reader.field == 3) turn.ttl = reader.value;
        if (reader.field == 4 && reader.string) [uris addObject:reader.string];
    });
    turn.uris = uris;
    return ok ? turn : nil;
}

@end
