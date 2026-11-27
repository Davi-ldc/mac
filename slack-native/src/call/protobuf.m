// Owns the protobuf wire format.
#import "call/protobuf.h"

@implementation SNProtoWriter {
    NSMutableData *_data;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _data = [NSMutableData new];
    return self;
}

- (NSData *)data { return [_data copy]; }

- (void)appendVarint:(uint64_t)value {
    uint8_t bytes[10];
    size_t length = 0;
    do {
        bytes[length] = (value & 0x7f) | (value > 0x7f ? 0x80 : 0);
        value >>= 7;
        length++;
    } while (value);
    [_data appendBytes:bytes length:length];
}

- (void)appendKey:(uint32_t)field type:(SNProtoWireType)type { [self appendVarint:((uint64_t)field << 3) | type]; }

- (void)writeVarint:(uint64_t)value field:(uint32_t)field {
    [self appendKey:field type:SNProtoVarint];
    [self appendVarint:value];
}

- (void)writeBool:(BOOL)value field:(uint32_t)field { [self writeVarint:value ? 1 : 0 field:field]; }

- (void)writeBytes:(NSData *)value field:(uint32_t)field {
    [self appendKey:field type:SNProtoLengthDelimited];
    [self appendVarint:value.length];
    [_data appendData:value];
}

- (void)writeString:(NSString *)value field:(uint32_t)field { [self writeBytes:[value dataUsingEncoding:NSUTF8StringEncoding] field:field]; }

- (void)writeMessageField:(uint32_t)field build:(void (^)(SNProtoWriter *))build {
    SNProtoWriter *message = [SNProtoWriter new];
    build(message);
    [self writeBytes:message->_data field:field];
}

@end

@implementation SNProtoReader {
    NSData *_data;
    NSUInteger _offset;
}

- (instancetype)initWithData:(NSData *)data {
    if (!(self = [super init])) return nil;
    _data = data;
    return self;
}

- (BOOL)readVarint:(uint64_t *)value {
    const uint8_t *bytes = _data.bytes;
    uint64_t result = 0;
    for (unsigned shift = 0; shift < 64 && _offset < _data.length; shift += 7) {
        uint8_t byte = bytes[_offset++];
        result |= (uint64_t)(byte & 0x7f) << shift;
        if (!(byte & 0x80)) {
            *value = result;
            return YES;
        }
    }
    return NO;
}

- (BOOL)fail {
    _malformed = YES;
    return NO;
}

- (BOOL)next {
    if (_malformed || _offset >= _data.length) return NO;
    uint64_t key;
    if (![self readVarint:&key] || key >> 3 == 0 || key >> 3 > UINT32_MAX) return [self fail];
    _field = (uint32_t)(key >> 3);
    _wireType = (SNProtoWireType)(key & 7);
    _bytes = nil;
    _value = 0;
    switch (_wireType) {
        case SNProtoVarint: return [self readVarint:&_value] ? YES : [self fail];
        case SNProtoFixed64:
        case SNProtoFixed32: {
            NSUInteger size = _wireType == SNProtoFixed64 ? 8 : 4;
            if (_data.length - _offset < size) return [self fail];
            const uint8_t *bytes = (const uint8_t *)_data.bytes + _offset;
            for (NSUInteger i = 0; i < size; i++) _value |= (uint64_t)bytes[i] << (8 * i);
            _offset += size;
            return YES;
        }
        case SNProtoLengthDelimited: {
            uint64_t length;
            if (![self readVarint:&length] || length > _data.length - _offset) return [self fail];
            _bytes = [_data subdataWithRange:NSMakeRange(_offset, (NSUInteger)length)];
            _offset += (NSUInteger)length;
            return YES;
        }
    }
    // Groups (wire types 3 and 4) are not in any frame.
    return [self fail];
}

- (NSString *)string { return _bytes ? [[NSString alloc] initWithData:_bytes encoding:NSUTF8StringEncoding] : nil; }

@end
