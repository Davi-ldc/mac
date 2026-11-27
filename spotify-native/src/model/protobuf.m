// Minimal proto3 wire-format reader and writer.
#import "model/protobuf.h"

@implementation SPProtobufWriter {
    NSMutableData *_buf;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _buf = [NSMutableData dataWithCapacity:64];
    return self;
}

- (NSData *)data { return [_buf copy]; }

+ (NSData *)messageWithBlock:(void (^)(SPProtobufWriter *writer))block {
    SPProtobufWriter *w = [self new];
    if (block) block(w);
    return w.data;
}

- (void)appendVarint:(uint64_t)value {
    uint8_t tmp[10];
    size_t n = 0;
    do {
        uint8_t b = (uint8_t)(value & 0x7Fu);
        value >>= 7;
        if (value != 0) b |= 0x80u;
        tmp[n++] = b;
    } while (value != 0);
    [_buf appendBytes:tmp length:n];
}

- (void)appendTagField:(uint32_t)field wire:(uint8_t)wire {
    [self appendVarint:((uint64_t)field << 3) | (uint64_t)wire];
}

- (void)writeVarint:(uint64_t)value field:(uint32_t)field {
    [self appendTagField:field wire:0];
    [self appendVarint:value];
}

- (void)writeBool:(BOOL)value field:(uint32_t)field {
    [self writeVarint:value ? 1u : 0u field:field];
}

- (void)writeFlag:(BOOL)value field:(uint32_t)field {
    if (value) [self writeBool:YES field:field];
}

- (void)writeBytes:(NSData *)value field:(uint32_t)field {
    [self appendTagField:field wire:2];
    [self appendVarint:(uint64_t)value.length];
    if (value.length) [_buf appendData:value];
}

- (void)writeString:(NSString *)value field:(uint32_t)field {
    NSData *utf8 = [value dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    [self writeBytes:utf8 field:field];
}

- (void)writeNonEmptyString:(NSString *)value field:(uint32_t)field {
    if (value.length) [self writeString:value field:field];
}

- (void)writeMessageField:(uint32_t)field block:(void (^)(SPProtobufWriter *nested))block {
    [self writeBytes:[SPProtobufWriter messageWithBlock:block] field:field];
}

@end

@implementation SPProtobufField

- (instancetype)initWithNumber:(uint32_t)number wireType:(uint8_t)wireType varint:(uint64_t)val bytes:(NSData *)bytes {
    if (!(self = [super init])) return nil;
    _number = number;
    _wireType = wireType;
    _varintValue = val;
    _bytesValue = bytes ?: [NSData data];
    return self;
}

- (BOOL)boolValue { return _varintValue != 0; }
- (int64_t)int64Value { return (int64_t)_varintValue; }

- (NSString *)stringValue {
    if (!_bytesValue.length) return @"";
    NSString *s = [[NSString alloc] initWithData:_bytesValue encoding:NSUTF8StringEncoding];
    return s ?: @"";
}

- (NSArray<SPProtobufField *> *)nestedFields {
    return SPProtobufReadFields(_bytesValue);
}

- (void)readMapEntryKey:(NSString **)outKey value:(NSString **)outValue {
    NSArray<SPProtobufField *> *fields = [self nestedFields];
    SPProtobufField *k = SPProtobufLastField(fields, 1);
    SPProtobufField *v = SPProtobufLastField(fields, 2);
    *outKey = k ? k.stringValue : @"";
    *outValue = v ? v.stringValue : @"";
}

@end

static BOOL ReadVarint(const uint8_t *buf, size_t len, size_t *idx, uint64_t *out) {
    uint64_t result = 0;
    uint32_t shift = 0;
    while (*idx < len) {
        uint8_t b = buf[(*idx)++];
        result |= (uint64_t)(b & 0x7Fu) << shift;
        if ((b & 0x80u) == 0) {
            *out = result;
            return YES;
        }
        shift += 7;
        if (shift > 63) return NO;
    }
    return NO;
}

static BOOL ReadFixed(const uint8_t *buf, size_t len, size_t *idx, size_t width, uint64_t *out) {
    if (len - *idx < width) return NO;
    uint64_t result = 0;
    for (size_t i = 0; i < width; i++) {
        result |= (uint64_t)buf[*idx + i] << (8 * i);
    }
    *idx += width;
    *out = result;
    return YES;
}

NSArray<SPProtobufField *> *SPProtobufReadFields(NSData *data) {
    if (!data.length) return @[];
    const uint8_t *buf = (const uint8_t *)data.bytes;
    size_t len = data.length;
    size_t idx = 0;
    NSMutableArray<SPProtobufField *> *fields = [NSMutableArray new];
    NSData *empty = [NSData data];

    uint64_t tag = 0;
    while (idx < len && ReadVarint(buf, len, &idx, &tag)) {
        uint32_t number = (uint32_t)(tag >> 3);
        uint8_t wire = (uint8_t)(tag & 0x07u);
        if (number == 0) break;

        if (wire == 0) {
            uint64_t v = 0;
            if (!ReadVarint(buf, len, &idx, &v)) break;
            [fields addObject:[[SPProtobufField alloc] initWithNumber:number wireType:0 varint:v bytes:empty]];
        } else if (wire == 1) {
            uint64_t v = 0;
            if (!ReadFixed(buf, len, &idx, 8, &v)) break;
            [fields addObject:[[SPProtobufField alloc] initWithNumber:number wireType:1 varint:v bytes:empty]];
        } else if (wire == 2) {
            uint64_t blen = 0;
            if (!ReadVarint(buf, len, &idx, &blen) || blen > len - idx) break;
            NSData *slice = [NSData dataWithBytes:buf + idx length:(NSUInteger)blen];
            idx += (size_t)blen;
            [fields addObject:[[SPProtobufField alloc] initWithNumber:number wireType:2 varint:0 bytes:slice]];
        } else if (wire == 5) {
            uint64_t v = 0;
            if (!ReadFixed(buf, len, &idx, 4, &v)) break;
            [fields addObject:[[SPProtobufField alloc] initWithNumber:number wireType:5 varint:v bytes:empty]];
        } else {
            break;
        }
    }
    return fields;
}

SPProtobufField *SPProtobufLastField(NSArray<SPProtobufField *> *fields, uint32_t number) {
    for (NSInteger i = (NSInteger)fields.count - 1; i >= 0; i--) {
        if (fields[(NSUInteger)i].number == number) return fields[(NSUInteger)i];
    }
    return nil;
}

BOOL SPProtobufFirstVarint(NSData *data, uint32_t number, uint64_t *outValue) {
    for (SPProtobufField *f in SPProtobufReadFields(data)) {
        if (f.number == number && f.wireType == 0) {
            if (outValue) *outValue = f.varintValue;
            return YES;
        }
    }
    return NO;
}

NSData *SPProtobufFirstBytes(NSData *data, uint32_t number) {
    for (SPProtobufField *f in SPProtobufReadFields(data)) {
        if (f.number == number && f.wireType == 2) return f.bytesValue;
    }
    return nil;
}

NSString *SPProtobufFirstString(NSData *data, uint32_t number) {
    NSData *payload = SPProtobufFirstBytes(data, number);
    if (!payload) return nil;
    return [[NSString alloc] initWithData:payload encoding:NSUTF8StringEncoding];
}
