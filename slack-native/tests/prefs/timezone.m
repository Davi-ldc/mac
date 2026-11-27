// The time zone (Preferences, Language & region) as the web client's TimezonePref saves it, the
// client's own list of zones, the zone every time follows, and the Mac's zone in automatic mode
// (values made up, shapes as Slack sends them).
#import "../net/stub.h"
#import "app/launch.h"
#import "model/json.h"
#import "model/timezone.h"
#import "render/format.h"
#import "render/strings.h"
#import "snapshot.h"
#import "store/fixture.h"
#import "test.h"
#import "ui/channel/messagelayout.h"
#import "ui/channel/pane.h"
#import "ui/channel/row.h"
#import "ui/kit/hoverview.h"
#import "ui/kit/overlay.h"
#import "ui/kit/popover.h"
#import "ui/prefs/prefs.h"
#import "ui/profile/profilecard.h"
#import "ui/shell/shell.h"

static NSString *T(NSString *key) { return SNLocalized([@"prefs." stringByAppendingString:key]); }

static NSArray<NSDictionary *> *Calls(SNFixtureSource *source, NSString *method) {
    NSMutableArray *calls = [NSMutableArray new];
    for (NSArray *call in source.calls)
        if ([call[0] isEqualToString:method]) [calls addObject:call[1]];
    return calls;
}

static NSDictionary *PrefSet(NSString *name, NSString *value) { return @{@"name" : name, @"value" : value, @"_x_reason" : @"prefs-api/setUserPrefByApi"}; }

/// A body as Slack sends it.
static NSDictionary *JSON(NSString *text) { return [NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil]; }

/// Back to the Mac's zone, which the other cases expect.
static void FollowTheMac(SNStore *store) {
    store.macTimeZone = NSTimeZone.systemTimeZone;
    [store applyPreferences:@{@"set_tz_automatically" : @YES}];
}

SN_TEST(TimeZoneChoicesAreSlacks) {
    NSArray *english = SNTimeZoneChoices(@"en-US"), *portuguese = SNTimeZoneChoices(@"pt-BR");
    SNExpect(english.count == 124 && portuguese.count == 124, "the client's 124 zones");
    SNExpect([english containsObject:(@[ @"(UTC-03:00) Brasilia", @"America/Sao_Paulo" ])] &&
                 [portuguese containsObject:(@[ @"(UTC-03:00) Brasília", @"America/Sao_Paulo" ])],
             "labelled in the user's language, English for any other");
    NSMutableSet *englishZones = [NSMutableSet new], *portugueseZones = [NSMutableSet new];
    for (NSArray *choice in english) [englishZones addObject:choice[1]];
    for (NSArray *choice in portuguese) [portugueseZones addObject:choice[1]];
    SNExpect([englishZones isEqualToSet:portugueseZones], "the same zones in every language");
    SNExpect([SNTimeZoneChoiceForZone([NSTimeZone timeZoneWithName:@"America/Sao_Paulo"]) isEqualToString:@"America/Sao_Paulo"], "a listed zone is saved as it is");
    SNExpect([SNTimeZoneChoiceForZone([NSTimeZone timeZoneWithName:@"Europe/Lisbon"]) isEqualToString:@"Europe/London"] &&
                 [SNTimeZoneChoiceForZone([NSTimeZone timeZoneWithName:@"Brazil/East"]) isEqualToString:@"America/Sao_Paulo"],
             "others as the client's tables name them");
    NSString *nuuk = SNTimeZoneChoiceForZone([NSTimeZone timeZoneWithName:@"America/Nuuk"]);
    NSDate *now = NSDate.date;
    SNExpect(nuuk && [[NSTimeZone timeZoneWithName:nuuk] secondsFromGMTForDate:now] == [[NSTimeZone timeZoneWithName:@"America/Nuuk"] secondsFromGMTForDate:now],
             "and one newer than the tables as a listed zone keeping its time");
}

SN_TEST(TimeZonePreferenceSavesAsSlack) {
    SNSetLanguage(@"en");
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    SNShell *shell = [[SNShell alloc] initWithSource:source defaults:nil];
    [shell go:[SNLocation locationWithTab:SNTabHome conversation:@"C03DESIGN" thread:nil]];
    [shell.window.contentView layoutSubtreeIfNeeded];
    SNChannelPane *channel = (SNChannelPane *)[shell paneInSlot:SNPaneSlotPrimary];
    SNMessage *message = nil;
    for (SNMessage *candidate in [source messagesInConversation:@"C03DESIGN"])
        if ([channel.list rowForTS:candidate.ts].layout.time.length) message = candidate;
    NSString * (^shownTime)(void) = ^NSString * {
        [shell.window.contentView layoutSubtreeIfNeeded];
        return [channel.list rowForTS:message.ts].layout.time;
    };
    NSTimeZone *mac = NSTimeZone.systemTimeZone;
    SNExpect(message && [shownTime() isEqualToString:SNFormatTimeInZone(message.date, mac)], "messages show the Mac's time by default");

    SNPreferencesDialog *dialog = [SNPreferencesDialog showInWindow:shell.window source:source section:SNPrefsLanguage];
    SNExpect([dialog.optionTitles containsObject:T(@"language.timezone.automatic")] && [dialog.optionTitles containsObject:T(@"language.timezone")],
             "Language & region: Set time zone automatically and the time zone");
    SNExpect(![dialog chooseOption:T(@"language.timezone") value:@"Pacific/Chatham"], "the picker is off while the zone is set automatically");

    [dialog chooseOption:T(@"language.timezone.automatic") value:nil];
    SNExpect([Calls(source, @"users.prefs.set").lastObject isEqualToDictionary:PrefSet(@"set_tz_automatically", @"false")], "off: users.prefs.set set_tz_automatically");
    NSUInteger sets = Calls(source, @"users.prefs.set").count;
    SNExpect([dialog chooseOption:T(@"language.timezone") value:@"Pacific/Chatham"], "then the picker takes a zone");
    SNExpect([Calls(source, @"users.prefs.set").lastObject isEqualToDictionary:PrefSet(@"tz", @"Pacific/Chatham")] && Calls(source, @"users.prefs.set").count == sets + 1,
             "saved as users.prefs.set tz");
    NSTimeZone *chatham = [NSTimeZone timeZoneWithName:@"Pacific/Chatham"];
    SNExpect([NSTimeZone.defaultTimeZone isEqualToTimeZone:chatham], "times follow it at once");
    SNExpect([shownTime() isEqualToString:SNFormatTimeInZone(message.date, chatham)] && ![shownTime() isEqualToString:SNFormatTimeInZone(message.date, mac)],
             "the messages' times among them");

    // Another device of the user's chose a zone.
    [source applyEvent:JSON(@"{\"type\":\"pref_change\",\"name\":\"tz\",\"value\":\"Asia/Kolkata\",\"event_ts\":\"1795400000.000100\"}")];
    NSTimeZone *kolkata = [NSTimeZone timeZoneWithName:@"Asia/Kolkata"];
    SNExpect([NSTimeZone.defaultTimeZone isEqualToTimeZone:kolkata] && [shownTime() isEqualToString:SNFormatTimeInZone(message.date, kolkata)],
             "a pref_change of tz moves them too");

    // Back to automatic: the client saves the zone it detects, as it does at every connection.
    sets = Calls(source, @"users.prefs.set").count;
    [dialog chooseOption:T(@"language.timezone.automatic") value:nil];
    NSArray *calls = Calls(source, @"users.prefs.set");
    SNExpect(calls.count == sets + 2 && [calls[sets] isEqualToDictionary:PrefSet(@"set_tz_automatically", @"true")] &&
                 [calls[sets + 1] isEqualToDictionary:PrefSet(@"tz", SNTimeZoneChoiceForZone(mac))],
             "on: set_tz_automatically, then tz as the client names the Mac's zone");
    SNExpect([NSTimeZone.defaultTimeZone isEqualToTimeZone:mac] && [shownTime() isEqualToString:SNFormatTimeInZone(message.date, mac)], "and times follow the Mac again");
    [dialog close];
    FollowTheMac(source);
}

SN_TEST(TimeZoneFollowsTheMacAsSlack) {
    SNTestAPI *api = [SNTestAPI new];
    SNStore *store = [[SNStore alloc] initWithDatabase:nil api:api];
    NSDictionary *me = JSON(@"{\"id\":\"U01ALEX\",\"name\":\"alex\",\"tz\":\"America/Sao_Paulo\",\"tz_label\":\"Brasilia Standard Time\",\"tz_offset\":-10800}");
    [store performChanges:^{
        [store applyWorkspace:@{@"id" : @"T0NORTHWND", @"name" : @"Northwind Studio"}];
        [store applySelfUserID:@"U01ALEX"];
        [store applyUsers:@[ me ]];
    }];
    [store applyPreferences:JSON(@"{\"ok\":true,\"prefs\":{\"set_tz_automatically\":true,\"tz\":\"America/Sao_Paulo\",\"time24\":false}}")[@"prefs"]];
    __block BOOL moved = NO;
    id observer = SNObserveChanges(store, ^(SNChange *change) {
        moved |= change.timeZone;
    });
    NSArray * (^sent)(void) = ^NSArray * {
        NSMutableArray *calls = [NSMutableArray new];
        for (NSArray *call in api.calls)
            if ([call[0] isEqualToString:@"users.prefs.set"]) [calls addObject:call[1]];
        return calls;
    };

    // The Mac travels to Lisbon.
    store.macTimeZone = [NSTimeZone timeZoneWithName:@"Europe/Lisbon"];
    SNExpect(moved && [NSTimeZone.defaultTimeZone.name isEqualToString:@"Europe/Lisbon"], "times follow the Mac's new zone, announced");
    SNExpect([sent().lastObject isEqualToDictionary:PrefSet(@"tz", @"Europe/London")] && [SNPreferenceString(store.preferences, @"tz") isEqualToString:@"Europe/London"],
             "and Slack's tz follows, as the client names Lisbon");
    NSUInteger count = sent().count;
    store.connectionState = SNConnectionConnected;
    SNExpect(sent().count == count, "a connection with the zone already saved sends nothing");

    // Another device (elsewhere, also automatic) saved its own zone; this one saves the Mac's
    // again at its next connection, as the client does.
    [store applyEvent:JSON(@"{\"type\":\"pref_change\",\"name\":\"tz\",\"value\":\"America/New_York\",\"event_ts\":\"1795400000.000200\"}")];
    SNExpect([NSTimeZone.defaultTimeZone.name isEqualToString:@"Europe/Lisbon"] && sent().count == count, "automatic: times stay the Mac's, nothing sent");
    store.connectionState = SNConnectionConnecting;
    store.connectionState = SNConnectionConnected;
    SNExpect([sent().lastObject isEqualToDictionary:PrefSet(@"tz", @"Europe/London")], "reconnected: the Mac's zone is saved again");

    // By hand: the user's tz, from the prefs, else from the user's own tz field.
    [store applyEvent:JSON(@"{\"type\":\"pref_change\",\"name\":\"set_tz_automatically\",\"value\":false,\"event_ts\":\"1795400000.000300\"}")];
    [store applyEvent:JSON(@"{\"type\":\"pref_change\",\"name\":\"tz\",\"value\":\"Asia/Tokyo\",\"event_ts\":\"1795400000.000400\"}")];
    SNExpect([NSTimeZone.defaultTimeZone.name isEqualToString:@"Asia/Tokyo"], "set by hand: the tz pref");
    [store applyPreferences:@{@"tz" : NSNull.null}];
    SNExpect([NSTimeZone.defaultTimeZone.name isEqualToString:@"America/Sao_Paulo"], "without one, the user's tz field");
    [store applyEvent:@{@"type" : @"user_change", @"user" : SNJSONMerge(me, @{@"tz" : @"Australia/Perth", @"tz_label" : @"Australian Western Standard Time", @"tz_offset" : @28800})}];
    SNExpect([NSTimeZone.defaultTimeZone.name isEqualToString:@"Australia/Perth"], "which a user_change moves");
    count = sent().count;
    moved = NO;
    store.macTimeZone = [NSTimeZone timeZoneWithName:@"America/Denver"];
    SNExpect(!moved && [NSTimeZone.defaultTimeZone.name isEqualToString:@"Australia/Perth"] && sent().count == count, "the Mac's moves change nothing then");
    SNStopObserving(observer);
    FollowTheMac(store);
    SNExpect([NSTimeZone.defaultTimeZone isEqualToTimeZone:NSTimeZone.systemTimeZone], "automatic again: the Mac's");
}

SN_TEST(TimeZoneWordsEveryTime) {
    SNSetLanguage(@"en");
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    // Sunday 23:30 UTC: Monday 08:30 in Tokyo, Sunday 20:30 in Sao Paulo; `now` four hours on is
    // Monday in both.
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:1795390200], *now = [date dateByAddingTimeInterval:4 * 3600];
    [source applyPreferences:@{@"set_tz_automatically" : @NO, @"tz" : @"Asia/Tokyo"}];
    NSString *tokyo = SNFormatTime(date), *tokyoDay = SNFormatDay(date, now);
    NSString *slackDate = SNFormatSlackDate(date.timeIntervalSince1970, @"{date_num} {time}", now);
    [source applyPreferences:@{@"tz" : @"America/Sao_Paulo"}];
    SNExpect(![SNFormatTime(date) isEqualToString:tokyo] && [SNFormatTime(date) isEqualToString:SNFormatTimeInZone(date, [NSTimeZone timeZoneWithName:@"America/Sao_Paulo"])],
             "message times");
    SNExpect([tokyoDay isEqualToString:SNLocalized(@"render.day.today")] && [SNFormatDay(date, now) isEqualToString:SNLocalized(@"render.day.yesterday")],
             "day dividers: today in Tokyo, yesterday in Sao Paulo");
    SNExpect(![SNFormatSlackDate(date.timeIntervalSince1970, @"{date_num} {time}", now) isEqualToString:slackDate], "and dates inside messages");

    // The profile card: the person's local time, their day against the one here.
    SNUser *person = [SNUser userWithJSON:JSON(@"{\"id\":\"U05MINA\",\"name\":\"mina\",\"tz\":\"Asia/Tokyo\",\"tz_label\":\"Japan Standard Time\",\"tz_offset\":32400}")];
    SNProfileCardView *card = [[SNProfileCardView alloc] initWithUser:person source:source];
    card.date = date;
    NSString *at = SNFormatTimeInZone(date, [NSTimeZone timeZoneWithName:@"Asia/Tokyo"]);
    SNExpect(([card.localTime isEqualToString:[NSString stringWithFormat:@"%@ (tomorrow) local time", at]]), "a day ahead of Sao Paulo: (tomorrow)");
    [source applyPreferences:@{@"tz" : @"Asia/Seoul"}];
    SNExpect(([card.localTime isEqualToString:[NSString stringWithFormat:@"%@ local time", at]]), "the same day as Seoul: none");
    // 14:30 UTC: 23:30 in Tokyo, already 04:30 the next day in Kiritimati.
    card.date = [date dateByAddingTimeInterval:-9 * 3600];
    at = SNFormatTimeInZone(card.date, [NSTimeZone timeZoneWithName:@"Asia/Tokyo"]);
    [source applyPreferences:@{@"tz" : @"Pacific/Kiritimati"}];
    SNExpect(([card.localTime isEqualToString:[NSString stringWithFormat:@"%@ (yesterday) local time", at]]), "a day behind Kiritimati: (yesterday)");
    SNProfileCardView *own = [[SNProfileCardView alloc] initWithUser:source.me source:source];
    own.date = card.date;
    NSString *here = SNFormatTimeInZone(card.date, [NSTimeZone timeZoneWithName:@"Pacific/Kiritimati"]);
    SNExpect(([own.localTime isEqualToString:[NSString stringWithFormat:@"%@ local time", here]]), "one's own card: the zone chosen here");
    FollowTheMac(source);
}

SN_SNAPSHOT(TimeZonePreferenceAsTheClientsCSS) {
    SNSetLanguage(@"en");
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    SNShell *shell = [[SNShell alloc] initWithSource:source defaults:nil];
    [source applyPreferences:@{@"set_tz_automatically" : @NO, @"tz" : @"America/Sao_Paulo"}];
    SNPreferencesDialog *dialog = [SNPreferencesDialog showInWindow:shell.window source:source section:SNPrefsLanguage];
    SNSettle(0.1);
    SNSaveSnapshot(@"preferences_language", SNRenderWindow(shell.window));
    // The picker's list (the lower of the section's two selects): c-select's 240 pt at most,
    // scrolled to the choice.
    SNHoverView *picker = nil;
    NSMutableArray<NSView *> *views = [NSMutableArray arrayWithObject:dialog.panel];
    while (views.count) {
        NSView *view = views.lastObject;
        [views removeLastObject];
        if ([NSStringFromClass(view.class) isEqualToString:@"SNPrefsSelect"] && (!picker || NSMinY(view.frame) > NSMinY(picker.frame))) picker = (SNHoverView *)view;
        [views addObjectsFromArray:view.subviews];
    }
    picker.action(picker);
    SNSettle(0.1);
    SNPanelView *list = (SNPanelView *)SNPopover.current.content;
    NSScrollView *scroll = list.contentView.subviews.firstObject;
    SNExpect(NSHeight(list.frame) == 240 && [scroll isKindOfClass:NSScrollView.class] && NSMinY(scroll.contentView.bounds) > 0,
             "the list is 240 pt tall and scrolled to the choice");
    SNSaveSnapshot(@"preferences_timezone_list", SNRenderWindow(shell.window));
    [SNPopover.current close];
    [dialog close];
    FollowTheMac(source);
}
