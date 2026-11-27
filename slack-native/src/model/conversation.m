// Owns decoding conversations and sidebar sections.
#import "model/conversation.h"
#import "model/json.h"

@implementation SNConversation

static BOOL EqualStr(NSString *a, NSString *b) { return a == b || [a isEqualToString:b]; }

+ (instancetype)conversationWithJSON:(NSDictionary *)json {
    NSString *conversationID = SNJSONString(json, @"id");
    if (!conversationID.length) return nil;
    SNConversation *conversation = [self new];
    conversation->_conversationID = conversationID;
    conversation->_kind = SNJSONBool(json, @"is_im")                                         ? SNConversationDirect
                          : SNJSONBool(json, @"is_mpim")                                     ? SNConversationGroupDirect
                          : SNJSONBool(json, @"is_private") || SNJSONBool(json, @"is_group") ? SNConversationPrivateChannel
                                                                                             : SNConversationChannel;
    conversation->_name = SNJSONString(json, @"name") ?: @"";
    conversation->_userID = SNJSONString(json, @"user");
    conversation->_topic = SNJSONString(SNJSONObject(json, @"topic"), @"value");
    conversation->_purpose = SNJSONString(SNJSONObject(json, @"purpose"), @"value");
    conversation->_memberCount = SNJSONInteger(json, @"num_members");
    // DMs are always the user's own; their JSON leaves is_member out.
    conversation->_isMember = SNJSONBool(json, @"is_member") || conversation.isDirect;
    conversation->_isArchived = SNJSONBool(json, @"is_archived");
    conversation->_isGeneral = SNJSONBool(json, @"is_general");
    conversation->_isShared = SNJSONBool(json, @"is_shared") || SNJSONBool(json, @"is_org_shared");
    conversation->_isExternallyShared = SNJSONBool(json, @"is_ext_shared");
    conversation->_created = SNJSONDouble(json, @"created");
    conversation->_lastRead = SNJSONString(json, @"last_read");
    id latest = json[@"latest"];
    conversation->_latest = [latest isKindOfClass:NSString.class] ? latest : SNJSONString(latest, @"ts");
    conversation->_isOpen = json[@"is_open"] ? SNJSONBool(json, @"is_open") : YES;
    conversation->_hasUnreads = SNJSONBool(json, @"has_unreads");
    conversation->_mentionCount = SNJSONInteger(json, @"mention_count");
    conversation->_isMuted = SNJSONBool(json, @"sn_muted");
    return conversation;
}

- (NSDictionary *)json {
    NSMutableDictionary *dict = [NSMutableDictionary new];
    dict[@"id"] = _conversationID;
    if (_kind == SNConversationDirect) dict[@"is_im"] = @YES;
    else if (_kind == SNConversationGroupDirect) dict[@"is_mpim"] = @YES;
    else if (_kind == SNConversationPrivateChannel) dict[@"is_private"] = @YES;
    if (_name.length) dict[@"name"] = _name;
    if (_userID) dict[@"user"] = _userID;
    if (_topic) dict[@"topic"] = @{@"value" : _topic};
    if (_purpose) dict[@"purpose"] = @{@"value" : _purpose};
    if (_memberCount) dict[@"num_members"] = @(_memberCount);
    if (_isMember) dict[@"is_member"] = @YES;
    if (_isArchived) dict[@"is_archived"] = @YES;
    if (_isGeneral) dict[@"is_general"] = @YES;
    if (_isShared) dict[@"is_shared"] = @YES;
    if (_isExternallyShared) dict[@"is_ext_shared"] = @YES;
    if (_created) dict[@"created"] = @(_created);
    if (_lastRead) dict[@"last_read"] = _lastRead;
    if (_latest) dict[@"latest"] = _latest;
    if (!_isOpen) dict[@"is_open"] = @NO;
    if (_hasUnreads) dict[@"has_unreads"] = @YES;
    if (_mentionCount) dict[@"mention_count"] = @(_mentionCount);
    if (_isMuted) dict[@"sn_muted"] = @YES;
    return dict;
}

- (BOOL)isEqualToConversation:(SNConversation *)other {
    if (self == other) return YES;
    if (!other) return NO;
    return [_conversationID isEqualToString:other->_conversationID] && _kind == other->_kind && [_name isEqualToString:other->_name] &&
           EqualStr(_userID, other->_userID) && EqualStr(_topic, other->_topic) && EqualStr(_purpose, other->_purpose) &&
           _memberCount == other->_memberCount && _isMember == other->_isMember && _isArchived == other->_isArchived &&
           _isGeneral == other->_isGeneral && _isShared == other->_isShared && _isExternallyShared == other->_isExternallyShared &&
           _created == other->_created && EqualStr(_lastRead, other->_lastRead) && EqualStr(_latest, other->_latest) &&
           _isOpen == other->_isOpen && _hasUnreads == other->_hasUnreads && _mentionCount == other->_mentionCount && _isMuted == other->_isMuted;
}

- (instancetype)conversationWithCounts:(NSDictionary *)counts {
    NSMutableDictionary *changes = [@{@"has_unreads" : @(SNJSONBool(counts, @"has_unreads")),
                                      @"mention_count" : @(SNJSONInteger(counts, @"mention_count"))} mutableCopy];
    for (NSString *key in @[ @"last_read", @"latest" ])
        if (SNJSONString(counts, key)) changes[key] = counts[key];
    return [self conversationByMergingJSON:changes];
}

- (instancetype)conversationByMergingJSON:(NSDictionary *)changes {
    return [SNConversation conversationWithJSON:SNJSONMerge(self.json, changes)] ?: self;
}

- (instancetype)conversationWithMuted:(BOOL)muted { return [self conversationByMergingJSON:@{@"sn_muted" : @(muted)}]; }

- (BOOL)isDirect { return self.kind == SNConversationDirect || self.kind == SNConversationGroupDirect; }
- (id)copyWithZone:(NSZone *)zone { return self; }

@end

SNSectionType const SNSectionStarred = @"stars";
SNSectionType const SNSectionChannels = @"channels";
SNSectionType const SNSectionDirectMessages = @"direct_messages";
SNSectionType const SNSectionApps = @"recent_apps";
SNSectionType const SNSectionSlackConnect = @"slack_connect";
SNSectionType const SNSectionCustom = @"standard";

@implementation SNSection

+ (instancetype)sectionWithJSON:(NSDictionary *)json {
    NSString *sectionID = SNJSONString(json, @"channel_section_id");
    if (!sectionID.length) return nil;
    SNSection *section = [self new];
    section->_sectionID = sectionID;
    section->_type = SNJSONString(json, @"type") ?: SNSectionCustom;
    section->_name = SNJSONString(json, @"name") ?: @"";
    NSString *emoji = SNJSONString(json, @"emoji");
    section->_emoji = emoji.length ? emoji : nil;
    NSString *next = SNJSONString(json, @"next_channel_section_id");
    section->_nextSectionID = next.length ? next : nil;
    section->_conversationIDs = SNJSONStrings(SNJSONObject(json, @"channel_ids_page"), @"channel_ids");
    section->_isCollapsed = SNJSONBool(json, @"is_collapsed");
    return section;
}

+ (NSArray<SNSection *> *)orderedSections:(NSArray<SNSection *> *)sections {
    NSMutableDictionary<NSString *, SNSection *> *byID = [NSMutableDictionary new];
    NSMutableSet<NSString *> *pointedTo = [NSMutableSet new];
    for (SNSection *section in sections) {
        byID[section.sectionID] = section;
        if (section.nextSectionID) [pointedTo addObject:section.nextSectionID];
    }
    NSMutableArray<SNSection *> *ordered = [NSMutableArray new];
    NSMutableSet<NSString *> *placed = [NSMutableSet new];
    SNSection *head = nil;
    for (SNSection *section in sections)
        if (![pointedTo containsObject:section.sectionID]) {
            head = section;
            break;
        }
    for (SNSection *section = head; section && ![placed containsObject:section.sectionID]; section = byID[section.nextSectionID ?: @""]) {
        [ordered addObject:section];
        [placed addObject:section.sectionID];
    }
    for (SNSection *section in sections)
        if (![placed containsObject:section.sectionID]) [ordered addObject:section];
    return ordered;
}

- (id)copyWithZone:(NSZone *)zone { return self; }

@end
