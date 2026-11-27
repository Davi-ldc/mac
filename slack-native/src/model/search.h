// A page of search.messages results.
#import <Foundation/Foundation.h>

#import "model/message.h"

NS_ASSUME_NONNULL_BEGIN

@interface SNSearchResult : NSObject
@property (nonatomic, readonly) NSString *query;
/// Best match first; each with its conversationID.
@property (nonatomic, readonly) NSArray<SNMessage *> *messages;
@property (nonatomic, readonly) NSInteger total, page, pageCount;
/// From search.messages' response.
+ (nullable instancetype)resultWithJSON:(NSDictionary *)json query:(NSString *)query;
@end

NS_ASSUME_NONNULL_END
