// Owns decoding search results.
#import "model/json.h"
#import "model/search.h"

@implementation SNSearchResult

+ (instancetype)resultWithJSON:(NSDictionary *)json query:(NSString *)query {
    NSDictionary *messages = SNJSONObject(json, @"messages");
    if (!messages) return nil;
    SNSearchResult *result = [self new];
    result->_query = [query copy];
    // A match names its conversation in "channel" as an object, not an ID.
    result->_messages = SNJSONMap(messages, @"matches", ^id(NSDictionary *item) {
        return [SNMessage messageWithJSON:item conversationID:SNJSONString(SNJSONObject(item, @"channel"), @"id")];
    });
    NSDictionary *paging = SNJSONObject(messages, @"paging") ?: SNJSONObject(messages, @"pagination");
    result->_total = SNJSONInteger(messages, @"total") ?: SNJSONInteger(paging, @"total_count");
    result->_page = SNJSONInteger(paging, @"page") ?: 1;
    result->_pageCount = SNJSONInteger(paging, @"pages") ?: SNJSONInteger(paging, @"page_count") ?: 1;
    return result;
}

@end
