// Owns decoding a user.
#import "model/json.h"
#import "model/user.h"
#import "model/workspace.h"

/// team.avatar_base_url (one host for every workspace) and the sizes it serves. The edge API's
/// users carry only profile.avatar_hash, never image_<size>; Slack's client builds
/// <base><team>-<user>-<hash>-<size> from it, custom pictures and Gravatar defaults alike.
static NSString *const kAvatarBase = @"https://ca.slack-edge.com/";
static const int kAvatarSizes[] = {24, 32, 48, 72, 192, 512, 1024};

@implementation SNUser {
    NSString *_avatarHash;
    /// Populated only when explicit image_<size> URLs differ from the ca.slack-edge.com template.
    NSDictionary<NSNumber *, NSURL *> *_explicitAvatarURLs;
    NSString *_pronouns, *_email, *_statusTextCanonical;
    NSDictionary *_profileFields;
    BOOL _isAgentforceBot;
}

static BOOL EqualObj(id a, id b) { return a == b || [a isEqual:b]; }

+ (instancetype)userWithJSON:(NSDictionary *)json {
    NSString *userID = SNJSONString(json, @"id");
    if (!userID.length) return nil;
    NSDictionary *profile = SNJSONObject(json, @"profile");
    SNUser *user = [self new];
    user->_userID = userID;
    user->_teamID = SNJSONString(json, @"team_id") ?: SNJSONString(profile, @"team");
    user->_handle = SNJSONString(json, @"name") ?: @"";
    user->_realName = SNJSONString(profile, @"real_name") ?: SNJSONString(json, @"real_name") ?: @"";
    user->_displayName = SNJSONString(profile, @"display_name") ?: @"";
    user->_title = SNJSONString(profile, @"title");
    user->_color = SNJSONString(json, @"color");
    user->_timeZone = SNJSONString(json, @"tz");
    user->_timeZoneOffset = SNJSONInteger(json, @"tz_offset");
    user->_locale = SNJSONString(json, @"locale");
    user->_statusText = SNJSONString(profile, @"status_text");
    user->_statusTextCanonical = SNJSONString(profile, @"status_text_canonical");
    user->_statusEmoji = SNJSONString(profile, @"status_emoji");
    user->_statusExpiration = SNJSONDouble(profile, @"status_expiration");
    user->_huddleState = SNJSONString(profile, @"huddle_state");
    user->_huddleStateExpiration = SNJSONDouble(profile, @"huddle_state_expiration_ts");
    user->_huddleChannelID = SNJSONString(profile, @"huddle_state_channel_id");
    user->_pronouns = SNJSONString(profile, @"pronouns");
    user->_email = SNJSONString(profile, @"email");
    NSDictionary *fields = SNJSONObject(profile, @"fields");
    if (fields.count) user->_profileFields = [fields copy];
    NSString *hash = SNJSONString(profile, @"avatar_hash");
    user->_avatarHash = hash.length ? hash : nil;
    NSString *prefix = (hash.length && user->_teamID.length) ? [NSString stringWithFormat:@"%@%@-%@-%@-", kAvatarBase, user->_teamID, userID, hash] : nil;
    NSMutableDictionary *avatars = nil;
    BOOL allTemplate = prefix != nil;
    for (NSString *key in profile) {
        if (![key hasPrefix:@"image_"]) continue;
        NSInteger size = [key substringFromIndex:6].integerValue;
        if (!size) continue;
        NSString *raw = SNJSONString(profile, key);
        if (!raw.length) continue;
        if (allTemplate) {
            NSString *expected = [NSString stringWithFormat:@"%@%ld", prefix, (long)size];
            if ([raw isEqualToString:expected]) continue;
            allTemplate = NO;
            // Re-collect any earlier template URLs we skipped so explicit dictionary is complete.
            avatars = [NSMutableDictionary new];
            for (NSString *k in profile) {
                NSInteger s = [k hasPrefix:@"image_"] ? [k substringFromIndex:6].integerValue : 0;
                NSURL *u = s ? SNJSONURL(profile, k) : nil;
                if (u) avatars[@(s)] = u;
            }
            break;
        }
        NSURL *url = SNJSONURL(profile, key);
        if (url) {
            if (!avatars) avatars = [NSMutableDictionary new];
            avatars[@(size)] = url;
        }
    }
    user->_explicitAvatarURLs = avatars;
    user->_deleted = SNJSONBool(json, @"deleted");
    user->_isBot = SNJSONBool(json, @"is_bot");
    user->_isAppUser = SNJSONBool(json, @"is_app_user");
    user->_isAdmin = SNJSONBool(json, @"is_admin");
    user->_isOwner = SNJSONBool(json, @"is_owner");
    user->_isRestricted = SNJSONBool(json, @"is_restricted");
    user->_isUltraRestricted = SNJSONBool(json, @"is_ultra_restricted");
    user->_isAgentforceBot = SNJSONBool(json, @"is_agentforce_bot");
    user->_updated = SNJSONDouble(json, @"updated");
    return user;
}

SNPresence SNPresenceNamed(NSString *name) {
    return [name isEqualToString:@"active"] ? SNPresenceActive : [name isEqualToString:@"away"] ? SNPresenceAway : SNPresenceUnknown;
}

static BOOL showsFullNames;
void SNSetShowsFullNames(BOOL fullNames) { showsFullNames = fullNames; }
BOOL SNShowsFullNames(void) { return showsFullNames; }

- (NSString *)visibleName {
    if (showsFullNames && self.realName.length) return self.realName;
    return self.displayName.length ? self.displayName : self.realName.length ? self.realName : self.handle;
}

- (NSDictionary<NSNumber *, NSURL *> *)avatarURLs {
    if (_explicitAvatarURLs) return _explicitAvatarURLs;
    if (!_avatarHash.length || !_teamID.length) return @{};
    NSMutableDictionary *avatars = [NSMutableDictionary dictionaryWithCapacity:sizeof kAvatarSizes / sizeof *kAvatarSizes];
    for (size_t i = 0; i < sizeof kAvatarSizes / sizeof *kAvatarSizes; i++) {
        NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@%@-%@-%@-%d", kAvatarBase, _teamID, _userID, _avatarHash, kAvatarSizes[i]]];
        if (url) avatars[@(kAvatarSizes[i])] = url;
    }
    return avatars;
}

- (NSURL *)avatarURLForPixels:(CGFloat)pixels {
    if (_explicitAvatarURLs) return SNBestURL(_explicitAvatarURLs, pixels);
    if (!_avatarHash.length || !_teamID.length) return nil;
    int chosen = kAvatarSizes[sizeof kAvatarSizes / sizeof *kAvatarSizes - 1];
    for (size_t i = 0; i < sizeof kAvatarSizes / sizeof *kAvatarSizes; i++) {
        if (kAvatarSizes[i] >= pixels) {
            chosen = kAvatarSizes[i];
            break;
        }
    }
    return [NSURL URLWithString:[NSString stringWithFormat:@"%@%@-%@-%@-%d", kAvatarBase, _teamID, _userID, _avatarHash, chosen]];
}

- (NSDictionary *)json {
    NSMutableDictionary *dict = [NSMutableDictionary new];
    dict[@"id"] = _userID;
    if (_teamID) dict[@"team_id"] = _teamID;
    if (_handle.length) dict[@"name"] = _handle;
    if (_realName.length) dict[@"real_name"] = _realName;
    if (_color) dict[@"color"] = _color;
    if (_timeZone) dict[@"tz"] = _timeZone;
    if (_timeZoneOffset) dict[@"tz_offset"] = @(_timeZoneOffset);
    if (_locale) dict[@"locale"] = _locale;
    if (_deleted) dict[@"deleted"] = @YES;
    if (_isBot) dict[@"is_bot"] = @YES;
    if (_isAppUser) dict[@"is_app_user"] = @YES;
    if (_isAdmin) dict[@"is_admin"] = @YES;
    if (_isOwner) dict[@"is_owner"] = @YES;
    if (_isRestricted) dict[@"is_restricted"] = @YES;
    if (_isUltraRestricted) dict[@"is_ultra_restricted"] = @YES;
    if (_isAgentforceBot) dict[@"is_agentforce_bot"] = @YES;
    if (_updated) dict[@"updated"] = @(_updated);
    NSMutableDictionary *profile = [NSMutableDictionary new];
    if (_realName.length) profile[@"real_name"] = _realName;
    if (_displayName.length) profile[@"display_name"] = _displayName;
    if (_title) profile[@"title"] = _title;
    if (_statusText) profile[@"status_text"] = _statusText;
    if (_statusTextCanonical) profile[@"status_text_canonical"] = _statusTextCanonical;
    if (_statusEmoji) profile[@"status_emoji"] = _statusEmoji;
    if (_statusExpiration) profile[@"status_expiration"] = @(_statusExpiration);
    if (_huddleState) profile[@"huddle_state"] = _huddleState;
    if (_huddleStateExpiration) profile[@"huddle_state_expiration_ts"] = @(_huddleStateExpiration);
    if (_huddleChannelID) profile[@"huddle_state_channel_id"] = _huddleChannelID;
    if (_avatarHash) profile[@"avatar_hash"] = _avatarHash;
    if (_pronouns) profile[@"pronouns"] = _pronouns;
    if (_email) profile[@"email"] = _email;
    if (_profileFields) profile[@"fields"] = _profileFields;
    [_explicitAvatarURLs enumerateKeysAndObjectsUsingBlock:^(NSNumber *size, NSURL *url, BOOL *stop) {
        profile[[NSString stringWithFormat:@"image_%@", size]] = url.absoluteString;
    }];
    if (profile.count) dict[@"profile"] = profile;
    return dict;
}

- (BOOL)isEqualToUser:(SNUser *)other {
    if (self == other) return YES;
    if (!other) return NO;
    return [_userID isEqualToString:other->_userID] && EqualObj(_teamID, other->_teamID) && [_handle isEqualToString:other->_handle] &&
           [_realName isEqualToString:other->_realName] && [_displayName isEqualToString:other->_displayName] && EqualObj(_title, other->_title) &&
           EqualObj(_color, other->_color) && EqualObj(_timeZone, other->_timeZone) && _timeZoneOffset == other->_timeZoneOffset &&
           EqualObj(_locale, other->_locale) && EqualObj(_statusText, other->_statusText) && EqualObj(_statusTextCanonical, other->_statusTextCanonical) &&
           EqualObj(_statusEmoji, other->_statusEmoji) && _statusExpiration == other->_statusExpiration && EqualObj(_huddleState, other->_huddleState) &&
           _huddleStateExpiration == other->_huddleStateExpiration && EqualObj(_huddleChannelID, other->_huddleChannelID) &&
           EqualObj(_avatarHash, other->_avatarHash) && EqualObj(_explicitAvatarURLs, other->_explicitAvatarURLs) &&
           EqualObj(_pronouns, other->_pronouns) && EqualObj(_email, other->_email) && EqualObj(_profileFields, other->_profileFields) &&
           _deleted == other->_deleted && _isBot == other->_isBot && _isAppUser == other->_isAppUser && _isAdmin == other->_isAdmin &&
           _isOwner == other->_isOwner && _isRestricted == other->_isRestricted && _isUltraRestricted == other->_isUltraRestricted &&
           _isAgentforceBot == other->_isAgentforceBot && _updated == other->_updated;
}

- (BOOL)isInHuddleAt:(NSDate *)date {
    return [self.huddleState isEqualToString:@"in_a_huddle"] && self.huddleStateExpiration > date.timeIntervalSince1970;
}

- (instancetype)userByMergingJSON:(NSDictionary *)changes {
    return [SNUser userWithJSON:SNJSONMerge(self.json, changes)] ?: self;
}

- (id)copyWithZone:(NSZone *)zone { return self; }

@end
