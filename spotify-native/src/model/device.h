// Immutable Spotify Connect device model and protobuf decoder.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(uint32_t, SPDeviceType) {
    SPDeviceTypeUnknown = 0,
    SPDeviceTypeComputer = 1,
    SPDeviceTypeTablet = 2,
    SPDeviceTypeSmartphone = 3,
    SPDeviceTypeSpeaker = 4,
    SPDeviceTypeTV = 5,
    SPDeviceTypeAVR = 6,
    SPDeviceTypeSTB = 7,
    SPDeviceTypeAudioDongle = 8,
    SPDeviceTypeGameConsole = 9,
    SPDeviceTypeCastVideo = 10,
    SPDeviceTypeCastAudio = 11,
    SPDeviceTypeAutomobile = 12,
    SPDeviceTypeSmartwatch = 13,
    SPDeviceTypeChromebook = 14,
};

@interface SPDevice : NSObject <NSCopying>
@property (nonatomic, readonly, copy) NSString *deviceID;
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly) SPDeviceType deviceType;
@property (nonatomic, readonly) BOOL isActive;
@property (nonatomic, readonly) BOOL isHidden;
@property (nonatomic, readonly) BOOL canPlay;
@property (nonatomic, readonly) BOOL disableVolume;
/// Wire volume 0..65535.
@property (nonatomic, readonly) uint32_t volume;
/// Normalized 0..100 volume percentage.
@property (nonatomic, readonly) NSInteger volumePercent;

- (instancetype)initWithDeviceID:(NSString *)deviceID
                            name:(NSString *)name
                      deviceType:(SPDeviceType)deviceType
                        isActive:(BOOL)isActive
                        isHidden:(BOOL)isHidden
                         canPlay:(BOOL)canPlay
                   disableVolume:(BOOL)disableVolume
                          volume:(uint32_t)volume NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Decodes a Spotify Connect `DeviceInfo` protobuf payload.
+ (instancetype)deviceFromConnectInfoData:(NSData *)data
                         fallbackDeviceID:(NSString *)fallbackDeviceID
                           activeDeviceID:(nullable NSString *)activeDeviceID;
@end

NS_ASSUME_NONNULL_END
