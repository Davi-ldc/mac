// The protobuf (proto2) wire format, as far as Chime's signalling frames use it: varints,
// strings, bytes and nested messages written field by field, and a reader that walks a message's
// fields and skips the ones it does not know (fixed32 and fixed64 included).
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(uint32_t, SNProtoWireType) {
    SNProtoVarint = 0,
    SNProtoFixed64 = 1,
    SNProtoLengthDelimited = 2,
    SNProtoFixed32 = 5,
};

@interface SNProtoWriter : NSObject
@property (nonatomic, readonly) NSData *data;
- (void)writeVarint:(uint64_t)value field:(uint32_t)field;
- (void)writeBool:(BOOL)value field:(uint32_t)field;
- (void)writeString:(NSString *)value field:(uint32_t)field;
- (void)writeBytes:(NSData *)value field:(uint32_t)field;
/// A nested message: `build` writes its fields.
- (void)writeMessageField:(uint32_t)field build:(void (^)(SNProtoWriter *message))build;
@end

@interface SNProtoReader : NSObject
- (instancetype)initWithData:(NSData *)data;
/// Moves to the next field; NO at the end or at bytes that are not a valid field (`malformed`).
- (BOOL)next;
@property (nonatomic, readonly) uint32_t field;
@property (nonatomic, readonly) SNProtoWireType wireType;
/// The value of a varint, fixed32 or fixed64 field.
@property (nonatomic, readonly) uint64_t value;
/// The contents of a length-delimited field (a string, bytes or a nested message).
@property (nonatomic, readonly, nullable) NSData *bytes;
@property (nonatomic, readonly, nullable) NSString *string;
@property (nonatomic, readonly) BOOL malformed;
@end

NS_ASSUME_NONNULL_END
