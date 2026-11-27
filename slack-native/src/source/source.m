// Owns the keys and preference readings every feature shares.
#import "source/source.h"

NSString *SNThreadKey(NSString *conversationID, NSString *threadTS) { return [NSString stringWithFormat:@"%@/%@", conversationID, threadTS]; }
NSString *SNMessageKey(SNMessage *message) { return [NSString stringWithFormat:@"%@/%@", message.conversationID ?: @"", message.identifier]; }

NSString *SNPreferenceString(NSDictionary *preferences, NSString *name) {
    id value = preferences[name];
    if ([value isKindOfClass:NSString.class]) return value;
    if ([value isKindOfClass:NSNumber.class]) return [value stringValue];
    return nil;
}

BOOL SNPreferenceBool(NSDictionary *preferences, NSString *name, BOOL fallback) {
    id value = preferences[name];
    if ([value isKindOfClass:NSNumber.class]) return [value boolValue];
    if ([value isKindOfClass:NSString.class]) return [value isEqualToString:@"true"] || [value isEqualToString:@"1"];
    return fallback;
}

id SNNotificationPreference(NSDictionary *preferences, NSString *name) {
    id all = preferences[@"all_notifications_prefs"];
    if ([all isKindOfClass:NSString.class]) all = [NSJSONSerialization JSONObjectWithData:[all dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    id global = [all isKindOfClass:NSDictionary.class] ? all[@"global"] : nil;
    id value = [global isKindOfClass:NSDictionary.class] ? global[name] : nil;
    return value == NSNull.null ? nil : value;
}
