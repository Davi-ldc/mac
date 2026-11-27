// Owns defensive reads of API dictionaries.
#import "model/json.h"

static id Value(id object, NSString *key, Class type) {
    if (![object isKindOfClass:NSDictionary.class]) return nil;
    id value = ((NSDictionary *)object)[key];
    return [value isKindOfClass:type] ? value : nil;
}

NSString *SNJSONString(id object, NSString *key) { return Value(object, key, NSString.class); }

NSInteger SNJSONInteger(id object, NSString *key) {
    id value = Value(object, key, NSObject.class);
    return [value isKindOfClass:NSNumber.class] || [value isKindOfClass:NSString.class] ? [value integerValue] : 0;
}

double SNJSONDouble(id object, NSString *key) {
    id value = Value(object, key, NSObject.class);
    return [value isKindOfClass:NSNumber.class] || [value isKindOfClass:NSString.class] ? [value doubleValue] : 0;
}

BOOL SNJSONBool(id object, NSString *key) { return [Value(object, key, NSNumber.class) boolValue]; }
NSDictionary *SNJSONObject(id object, NSString *key) { return Value(object, key, NSDictionary.class); }
NSArray *SNJSONArray(id object, NSString *key) { return Value(object, key, NSArray.class); }

NSArray<NSString *> *SNJSONStrings(id object, NSString *key) {
    NSMutableArray *strings = [NSMutableArray new];
    for (id item in SNJSONArray(object, key))
        if ([item isKindOfClass:NSString.class]) [strings addObject:item];
    return strings;
}

NSArray *SNJSONMap(id object, NSString *key, id (^decode)(NSDictionary *item)) {
    NSMutableArray *items = [NSMutableArray new];
    for (id item in SNJSONArray(object, key)) {
        id decoded = [item isKindOfClass:NSDictionary.class] ? decode(item) : nil;
        if (decoded) [items addObject:decoded];
    }
    return items;
}

NSURL *SNJSONURL(id object, NSString *key) {
    NSString *string = SNJSONString(object, key);
    return [string hasPrefix:@"https://"] || [string hasPrefix:@"http://"] ? [NSURL URLWithString:string] : nil;
}

NSDictionary<NSNumber *, NSURL *> *SNJSONSizedURLs(id object, NSString *prefix) {
    NSMutableDictionary *urls = [NSMutableDictionary new];
    if (![object isKindOfClass:NSDictionary.class]) return urls;
    for (NSString *key in object) {
        if (![key isKindOfClass:NSString.class] || ![key hasPrefix:prefix]) continue;
        NSString *rest = [key substringFromIndex:prefix.length];
        NSInteger size = rest.integerValue;
        if (size <= 0 || ![rest isEqualToString:@(size).stringValue]) continue;
        NSURL *url = SNJSONURL(object, key);
        if (url) urls[@(size)] = url;
    }
    return urls;
}

NSDictionary *SNJSONMerge(NSDictionary *json, NSDictionary *changes) {
    NSMutableDictionary *merged = [json mutableCopy];
    [changes enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
        if (value == NSNull.null) [merged removeObjectForKey:key];
        else merged[key] = value;
    }];
    return merged;
}
