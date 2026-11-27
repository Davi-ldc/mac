// Owns decoding rooms and huddle invitations.
#import "model/huddle.h"
#import "model/json.h"

@implementation SNHuddle

+ (instancetype)huddleWithJSON:(NSDictionary *)json {
    NSString *identifier = SNJSONString(json, @"id");
    if (!identifier.length) return nil;
    SNHuddle *huddle = [self new];
    huddle->_identifier = identifier;
    huddle->_json = [json copy];
    huddle->_conversationIDs = SNJSONStrings(json, @"channels");
    huddle->_name = SNJSONString(json, @"name").length ? SNJSONString(json, @"name") : nil;
    huddle->_creatorID = SNJSONString(json, @"created_by");
    huddle->_participantIDs = SNJSONStrings(json, @"participants");
    huddle->_historyIDs = SNJSONStrings(json, @"participant_history");
    huddle->_hasEnded = SNJSONBool(json, @"has_ended");
    huddle->_isDMCall = SNJSONBool(json, @"is_dm_call");
    huddle->_dateStart = SNJSONDouble(json, @"date_start");
    huddle->_dateEnd = SNJSONDouble(json, @"date_end");
    // Slack writes a zero ts for "no thread yet".
    for (NSString *key in @[ @"thread_root_ts", @"canvas_thread_ts" ]) {
        NSString *ts = SNJSONString(json, key);
        if (!huddle->_threadTS && ts.doubleValue > 0) huddle->_threadTS = ts;
    }
    return huddle;
}

- (BOOL)isActive { return !self.hasEnded && self.participantIDs.count > 0; }

- (instancetype)huddleByMergingJSON:(NSDictionary *)changes {
    return [SNHuddle huddleWithJSON:SNJSONMerge(self.json, changes)] ?: self;
}

@end

@implementation SNHuddleInvite

+ (instancetype)inviteWithJSON:(NSDictionary *)json received:(NSDate *)received {
    NSString *conversationID = SNJSONString(json, @"channel_id"), *huddleID = SNJSONString(json, @"call_id"), *senderID = SNJSONString(json, @"sender_user_id");
    if (!conversationID.length || !huddleID.length || !senderID.length) return nil;
    SNHuddleInvite *invite = [self new];
    invite->_conversationID = conversationID;
    invite->_huddleID = huddleID;
    invite->_senderID = senderID;
    invite->_received = received;
    invite->_json = [json copy];
    return invite;
}

@end
