// An integration or app that posts as itself (bots.info's "bot"). Webhook and legacy
// integration messages carry only bot_id: their name and picture come from here.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SNBot : NSObject <NSCopying>
@property (nonatomic, readonly) NSString *botID;
@property (nonatomic, readonly) NSString *name;
/// icons.image_<size> URLs by size in pixels (36, 48, 72).
@property (nonatomic, readonly) NSDictionary<NSNumber *, NSURL *> *iconURLs;
@property (nonatomic, readonly) NSDictionary *json;
+ (nullable instancetype)botWithJSON:(NSDictionary *)json;
@end

NS_ASSUME_NONNULL_END
