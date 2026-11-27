// Owns deciding, writing and delivering notifications, and the dock badge.
#import <AppKit/AppKit.h>
#import <UserNotifications/UserNotifications.h>

#import "model/json.h"
#import "notify/notify.h"
#import "render/message.h"

__asm__(".linker_option \"-framework\", \"UserNotifications\"");

@interface SNNotifier () <UNUserNotificationCenterDelegate, SNChangeObserver>
@end

@implementation SNNotifier {
    __weak SNStore *_store;
    NSString *_badge;
}

- (instancetype)initWithStore:(SNStore *)store {
    if (!(self = [super init])) return nil;
    _store = store;
    _badge = @"";
    __weak SNStore *weakStore = store;
    // "Mute all messaging sounds from Slack".
    BOOL (^muted)(void) = ^BOOL { return SNPreferenceBool(weakStore.preferences, @"mute_sounds", NO); };
    _deliver = ^(NSString *identifier, NSString *title, NSString *subtitle, NSString *body, NSDictionary *userInfo) {
        UNMutableNotificationContent *content = [UNMutableNotificationContent new];
        content.title = title;
        if (subtitle) content.subtitle = subtitle;
        content.body = body;
        content.userInfo = userInfo;
        content.sound = muted() ? nil : UNNotificationSound.defaultSound;
        content.threadIdentifier = userInfo[@"conversation"] ?: @"";
        [UNUserNotificationCenter.currentNotificationCenter addNotificationRequest:[UNNotificationRequest requestWithIdentifier:identifier content:content trigger:nil]
                                                             withCompletionHandler:nil];
    };
    _showBadge = ^(NSString *label) { NSApp.dockTile.badgeLabel = label.length ? label : nil; };
    _bounce = ^(BOOL untilActive) { [NSApp requestUserAttention:untilActive ? NSCriticalRequest : NSInformationalRequest]; };
    __weak SNNotifier *weakSelf = self;
    store.messageArrived = ^(SNMessage *message, SNConversation *conversation) { [weakSelf arrived:message conversation:conversation]; };
    [store addChangeObserver:self];
    return self;
}

- (void)installDelegate {
    UNUserNotificationCenter.currentNotificationCenter.delegate = self;
}

- (void)start {
    UNUserNotificationCenter *center = UNUserNotificationCenter.currentNotificationCenter;
    center.delegate = self;
    [center requestAuthorizationWithOptions:UNAuthorizationOptionAlert | UNAuthorizationOptionSound | UNAuthorizationOptionBadge
                          completionHandler:^(BOOL granted, NSError *error) {}];
    [self updateBadge];
}

- (void)stop {
    _store.messageArrived = nil;
    _onOpen = nil;
    _focusedConversation = nil;
    _store = nil;
    if (_showBadge) _showBadge(@"");
}

#pragma mark Deciding

/// all_notifications_prefs: a JSON object in a string, {global: {global_desktop}, channels: {C: {desktop}}} (shape inferred).
- (NSString *)levelFor:(SNConversation *)conversation {
    NSData *data = [SNJSONString(_store.preferences, @"all_notifications_prefs") dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *prefs = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSString *level = SNJSONString(SNJSONObject(SNJSONObject(prefs, @"channels"), conversation.conversationID), @"desktop");
    if (!level.length || [level isEqualToString:@"default"]) level = SNJSONString(SNJSONObject(prefs, @"global"), @"global_desktop");
    return level.length ? level : @"mention";
}

// Preferences' "Channel keywords" keep them in global_keywords; older accounts in highlight_words.
- (BOOL)hasKeyword:(SNMessage *)message {
    id keywords = SNNotificationPreference(_store.preferences, @"global_keywords");
    NSString *words = [keywords isKindOfClass:NSString.class] ? keywords : SNJSONString(_store.preferences, @"highlight_words") ?: @"";
    for (NSString *word in [words componentsSeparatedByString:@","]) {
        NSString *trimmed = [word stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (trimmed.length && [message.text rangeOfString:trimmed options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch].location != NSNotFound) return YES;
    }
    return NO;
}

/// Slack's priority_dnd_override ("Always allow notifications from VIPs"): while notifications are
/// paused, a message that would notify gets through when a VIP sent it in a DM or group DM, or named
/// someone, a user group or a channel in it; so does a bot message posted for a VIP. It overrides the
/// pause alone: a muted conversation stays muted.
- (BOOL)isVIPMessageThroughPause:(SNMessage *)message inConversation:(SNConversation *)conversation {
    NSArray<NSString *> *vips = _store.vipUserIDs;
    if (!_store.offersVIPs || !vips.count || !SNPreferenceBool(_store.preferences, @"priority_dnd_override", NO)) return NO;
    NSString *botUser = SNJSONString(SNJSONObject(message.json, @"bot_profile"), @"user_id");
    if ([message.subtype isEqualToString:@"bot_message"] && botUser && [vips containsObject:botUser]) return YES;
    if (!message.userID || ![vips containsObject:message.userID]) return NO;
    return message.mentionsAnyone || conversation.isDirect;
}

- (BOOL)shouldNotify:(SNMessage *)message inConversation:(SNConversation *)conversation {
    SNUser *me = _store.me;
    if (!me || [message.userID isEqualToString:me.userID] || conversation.isMuted) return NO;
    if ([_store doNotDisturbOfUser:me.userID] && ![self isVIPMessageThroughPause:message inConversation:conversation]) return NO;
    id desktop = SNNotificationPreference(_store.preferences, @"global_desktop_push_enabled");
    if (desktop && ![desktop boolValue]) return NO;
    NSSet *shown = [NSSet setWithObjects:@"bot_message", @"thread_broadcast", @"file_share", @"me_message", nil];
    if (message.subtype && ![shown containsObject:message.subtype]) return NO;
    NSString *focused = self.focusedConversation ? self.focusedConversation() : nil;
    if (NSApp.isActive && [focused isEqualToString:conversation.conversationID]) return NO;
    NSString *level = [self levelFor:conversation];
    if ([level isEqualToString:@"nothing"]) return NO;
    BOOL mention = conversation.isDirect || [message mentionsUser:me.userID] || message.mentionsEveryone || [self hasKeyword:message];
    if (message.isReply) return mention;
    return [level isEqualToString:@"everything"] || mention;
}

- (void)arrived:(SNMessage *)message conversation:(SNConversation *)conversation {
    SNStore *store = _store;
    if (!store || ![self shouldNotify:message inConversation:conversation]) return;
    SNUser *author = message.userID ? [store userWithID:message.userID] : nil;
    NSString *who = author.visibleName ?: message.username ?: (message.botID ? [store botWithID:message.botID].name : nil) ?: @"Slack";
    NSString *title = who, *subtitle = nil;
    if (conversation.kind == SNConversationChannel || conversation.kind == SNConversationPrivateChannel) subtitle = [@"#" stringByAppendingString:conversation.name];
    NSMutableDictionary *info = [@{@"conversation" : conversation.conversationID, @"ts" : message.ts} mutableCopy];
    if (message.threadTS && !message.isThreadParent) info[@"thread"] = message.threadTS;
    // "Include a preview of the message" off leaves the text out.
    id hidden = SNNotificationPreference(store.preferences, @"no_text_in_notifications");
    NSString *body = [hidden boolValue] ? @"" : SNNotificationText(message, store);
    self.deliver(SNMessageKey(message), title, subtitle, body, info);
    // mac_ssb_bounce: "" never, "short" once, "long" until the app is active.
    NSString *bounce = SNPreferenceString(store.preferences, @"mac_ssb_bounce");
    if (bounce.length && self.bounce) self.bounce([bounce isEqualToString:@"long"]);
}

#pragma mark Badge

- (NSString *)badgeLabel { return _badge; }

- (void)sourceChanged:(SNChange *)change {
    if (change.counts || change.conversations || change.preferences) [self updateBadge];
}

- (void)updateBadge {
    SNStore *store = _store;
    NSInteger count = store.threadMentionCount;
    BOOL unread = store.hasUnreadThreads;
    NSMutableSet *seen = [NSMutableSet new];
    NSMutableArray<SNConversation *> *conversations = [store.directMessages mutableCopy];
    for (SNSection *section in store.sections)
        for (NSString *conversationID in section.conversationIDs) {
            SNConversation *conversation = [store knownConversationWithID:conversationID];
            if (conversation) [conversations addObject:conversation];
        }
    for (SNConversation *conversation in conversations) {
        if ([seen containsObject:conversation.conversationID] || conversation.isMuted) continue;
        [seen addObject:conversation.conversationID];
        count += conversation.mentionCount;
        unread = unread || conversation.hasUnreads;
    }
    // mac_ssb_bullet: the dot for unread activity without mentions.
    NSString *badge = count > 0 ? @(count).stringValue : unread && SNPreferenceBool(store.preferences, @"mac_ssb_bullet", YES) ? @"•" : @"";
    if ([badge isEqualToString:_badge]) return;
    _badge = badge;
    self.showBadge(badge);
}

#pragma mark Clicks

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
    didReceiveNotificationResponse:(UNNotificationResponse *)response
             withCompletionHandler:(void (^)(void))completionHandler {
    NSDictionary *info = response.notification.request.content.userInfo;
    NSString *conversationID = SNJSONString(info, @"conversation");
    dispatch_async(dispatch_get_main_queue(), ^{
        if (conversationID && self.onOpen) self.onOpen(conversationID, SNJSONString(info, @"thread"));
    });
    completionHandler();
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler {
    completionHandler(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionSound);
}

@end

NSString *SNNotificationText(SNMessage *message, SNStore *store) {
    return [[[SNRenderer alloc] initWithSource:store] previewOfMessage:message style:SNTextStyleBody prefix:nil].plainText;
}
