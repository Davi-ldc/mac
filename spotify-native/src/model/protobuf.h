// Minimal proto3 wire-format reader and writer for Spotify client-token and connect-state messages.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SPProtobufWriter : NSObject
@property (nonatomic, readonly) NSData *data;
+ (NSData *)messageWithBlock:(void (^)(SPProtobufWriter *writer))block;
- (void)writeVarint:(uint64_t)value field:(uint32_t)field;
- (void)writeBool:(BOOL)value field:(uint32_t)field;
/// Proto3 optional flag: writes only when YES.
- (void)writeFlag:(BOOL)value field:(uint32_t)field;
- (void)writeString:(NSString *)value field:(uint32_t)field;
/// Proto3 optional string: writes only when non-empty.
- (void)writeNonEmptyString:(nullable NSString *)value field:(uint32_t)field;
- (void)writeBytes:(NSData *)value field:(uint32_t)field;
- (void)writeMessageField:(uint32_t)field block:(void (^)(SPProtobufWriter *nested))block;
@end

@interface SPProtobufField : NSObject
@property (nonatomic, readonly) uint32_t number;
@property (nonatomic, readonly) uint8_t wireType;
@property (nonatomic, readonly) uint64_t varintValue;
@property (nonatomic, readonly) NSData *bytesValue;
@property (nonatomic, readonly) BOOL boolValue;
@property (nonatomic, readonly) int64_t int64Value;
@property (nonatomic, readonly) NSString *stringValue;
- (NSArray<SPProtobufField *> *)nestedFields;
- (void)readMapEntryKey:(NSString *_Nonnull *_Nonnull)outKey value:(NSString *_Nonnull *_Nonnull)outValue;
@end

/// Parses all fields of a protobuf message in wire order. Unknown fields are preserved; truncated trailing bytes stop cleanly.
NSArray<SPProtobufField *> *SPProtobufReadFields(NSData *data);
SPProtobufField *_Nullable SPProtobufLastField(NSArray<SPProtobufField *> *fields, uint32_t number);
BOOL SPProtobufFirstVarint(NSData *data, uint32_t number, uint64_t *outValue);
NSData *_Nullable SPProtobufFirstBytes(NSData *data, uint32_t number);
NSString *_Nullable SPProtobufFirstString(NSData *data, uint32_t number);

NS_ASSUME_NONNULL_END
