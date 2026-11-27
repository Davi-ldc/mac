// Immutable Spotify Connect device model and protobuf decoder.
#import "model/device.h"
#import "model/protobuf.h"

#import <math.h>

@implementation SPDevice

- (instancetype)initWithDeviceID:(NSString *)deviceID
                            name:(NSString *)name
                      deviceType:(SPDeviceType)deviceType
                        isActive:(BOOL)isActive
                        isHidden:(BOOL)isHidden
                         canPlay:(BOOL)canPlay
                   disableVolume:(BOOL)disableVolume
                          volume:(uint32_t)volume {
    if (!(self = [super init])) return nil;
    _deviceID = [deviceID copy];
    _name = [name copy];
    _deviceType = deviceType;
    _isActive = isActive;
    _isHidden = isHidden;
    _canPlay = canPlay;
    _disableVolume = disableVolume;
    _volume = volume > 65535u ? 65535u : volume;
    return self;
}

- (NSInteger)volumePercent {
    return (NSInteger)llround(((double)_volume / 65535.0) * 100.0);
}

- (id)copyWithZone:(NSZone *)zone { return self; }

- (BOOL)isEqual:(id)object {
    if (self == object) return YES;
    if (![object isKindOfClass:SPDevice.class]) return NO;
    SPDevice *o = (SPDevice *)object;
    return [_deviceID isEqualToString:o->_deviceID] && [_name isEqualToString:o->_name] &&
           _deviceType == o->_deviceType && _isActive == o->_isActive && _isHidden == o->_isHidden &&
           _disableVolume == o->_disableVolume && _volume == o->_volume;
}

- (NSUInteger)hash { return _deviceID.hash; }

+ (instancetype)deviceFromConnectInfoData:(NSData *)data
                         fallbackDeviceID:(NSString *)fallbackDeviceID
                           activeDeviceID:(NSString *)activeDeviceID {
    BOOL canPlay = YES;
    uint32_t volume = 65535u;
    NSString *name = @"";
    SPDeviceType type = SPDeviceTypeUnknown;
    NSString *deviceID = fallbackDeviceID ?: @"";
    BOOL hidden = NO;
    BOOL disableVolume = NO;

    for (SPProtobufField *field in SPProtobufReadFields(data)) {
        switch (field.number) {
            case 1: canPlay = field.boolValue; break;
            case 2: volume = (uint32_t)field.varintValue; break;
            case 3: name = field.stringValue; break;
            case 4: {
                for (SPProtobufField *cap in [field nestedFields]) {
                    if (cap.number == 12) hidden = cap.boolValue;
                    else if (cap.number == 13) disableVolume = cap.boolValue;
                }
                break;
            }
            case 7: type = (SPDeviceType)field.varintValue; break;
            case 10:
                if (field.stringValue.length) deviceID = field.stringValue;
                break;
            default: break;
        }
    }

    BOOL active = activeDeviceID.length > 0 && [deviceID isEqualToString:activeDeviceID];
    return [[self alloc] initWithDeviceID:deviceID
                                     name:name
                               deviceType:type
                                 isActive:active
                                 isHidden:hidden
                                  canPlay:canPlay
                            disableVolume:disableVolume
                                   volume:volume];
}

@end
