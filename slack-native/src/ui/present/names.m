// Owns naming conversations after their people.
#import "ui/present/names.h"

NSArray<NSString *> *SNGroupDMHandles(SNConversation *conversation, id<SNSource> source) {
    NSString *name = conversation.name;
    if ([name hasPrefix:@"mpdm-"]) name = [name substringFromIndex:5];
    // The "-1" after the last handle tells same-member group DMs apart.
    NSRange suffix = [name rangeOfString:@"-" options:NSBackwardsSearch];
    if (suffix.location != NSNotFound && suffix.location > 0 && [name characterAtIndex:suffix.location - 1] != '-')
        name = [name substringToIndex:suffix.location];
    NSMutableArray<NSString *> *handles = [NSMutableArray new];
    NSString *me = source.me.handle;
    for (NSString *handle in [name componentsSeparatedByString:@"--"])
        if (handle.length && ![handle isEqualToString:me]) [handles addObject:handle];
    return handles;
}

NSArray<SNUser *> *SNConversationPeople(SNConversation *conversation, id<SNSource> source) {
    if (conversation.kind == SNConversationDirect) {
        SNUser *user = conversation.userID ? [source userWithID:conversation.userID] : nil;
        return user ? @[ user ] : @[];
    }
    if (conversation.kind != SNConversationGroupDirect) return @[];
    NSMutableArray<SNUser *> *people = [NSMutableArray new];
    for (NSString *handle in SNGroupDMHandles(conversation, source)) {
        SNUser *user = [source userWithHandle:handle];
        if (user) [people addObject:user];
    }
    return people;
}

NSString *SNConversationTitle(SNConversation *conversation, id<SNSource> source) {
    if (conversation.kind == SNConversationDirect) {
        SNUser *user = conversation.userID ? [source userWithID:conversation.userID] : nil;
        return user.visibleName ?: conversation.userID ?: @"";
    }
    if (conversation.kind != SNConversationGroupDirect) return conversation.name;
    NSMutableArray<NSString *> *names = [NSMutableArray new];
    for (NSString *handle in SNGroupDMHandles(conversation, source)) [names addObject:[source userWithHandle:handle].visibleName ?: handle];
    return [names componentsJoinedByString:@", "];
}
