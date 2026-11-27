// Owns decoding bots.
#import "model/bot.h"
#import "model/json.h"

@implementation SNBot

+ (instancetype)botWithJSON:(NSDictionary *)json {
    NSString *botID = SNJSONString(json, @"id");
    if (!botID.length) return nil;
    SNBot *bot = [self new];
    bot->_json = [json copy];
    bot->_botID = botID;
    bot->_name = SNJSONString(json, @"name") ?: @"";
    bot->_iconURLs = SNJSONSizedURLs(SNJSONObject(json, @"icons"), @"image_");
    return bot;
}

- (id)copyWithZone:(NSZone *)zone { return self; }

@end
