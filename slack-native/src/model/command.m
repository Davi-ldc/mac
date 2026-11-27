// Owns decoding slash commands.
#import "model/command.h"
#import "model/json.h"

/// The web client's commands allowed in threads (P+cE): everywhere, and outside huddles.
static BOOL SNRunsInThreads(NSString *name) {
    static NSSet<NSString *> *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = [NSSet setWithArray:@[
            @"/away", @"/collapse", @"/color", @"/colour", @"/dm", @"/expand", @"/feedback", @"/keys", @"/me", @"/msg", @"/open", @"/s", @"/search", @"/shortcuts",
            @"/shrug", @"/star", @"/gif", @"/active", @"/giphy", @"/mute", @"/remind", @"/tableflip", @"/archive", @"/remove", @"/rename", @"/topic", @"/who"
        ]];
    });
    return [names containsObject:name.lowercaseString];
}

@implementation SNCommand

+ (NSArray<SNCommand *> *)commandsWithJSON:(NSArray *)json {
    NSMutableArray<SNCommand *> *commands = [NSMutableArray new];
    NSMutableDictionary<NSString *, NSMutableArray *> *aliases = [NSMutableDictionary new];
    for (NSDictionary *entry in [json isKindOfClass:NSArray.class] ? json : @[]) {
        NSString *name = SNJSONString(entry, @"name");
        if (![name hasPrefix:@"/"]) continue;
        NSString *aliasOf = SNJSONString(entry, @"alias_of");
        if (aliasOf.length) {
            [aliases[aliasOf] ?: (aliases[aliasOf] = [NSMutableArray new]) addObject:name];
            continue;
        }
        SNCommand *command = [self new];
        command->_name = name;
        command->_summary = SNJSONString(entry, @"desc") ?: SNJSONString(entry, @"description") ?: @"";
        command->_usage = SNJSONString(entry, @"usage") ?: @"";
        command->_type = SNJSONString(entry, @"type") ?: @"core";
        command->_appID = SNJSONString(entry, @"app");
        command->_serviceName = SNJSONString(entry, @"service_name");
        command->_autocompletes = [entry[@"autocomplete"] isKindOfClass:NSNumber.class] ? [entry[@"autocomplete"] boolValue] : YES;
        command->_runsInThreads = SNJSONBool(entry, @"is_runnable_from_thread") || SNRunsInThreads(name);
        command->_aliases = @[];
        [commands addObject:command];
    }
    for (SNCommand *command in commands) command->_aliases = [aliases[command.name] copy] ?: @[];
    return commands;
}

- (BOOL)isNamed:(NSString *)name {
    if ([self.name caseInsensitiveCompare:name] == NSOrderedSame) return YES;
    for (NSString *alias in self.aliases)
        if ([alias caseInsensitiveCompare:name] == NSOrderedSame) return YES;
    return NO;
}

@end
