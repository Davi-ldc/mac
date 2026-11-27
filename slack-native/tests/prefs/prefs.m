// The Preferences dialog: its sections and options, the requests each option sends as the web
// client's prefs-dialog sends them (values made up), what the client does with them, and the
// dialog drawn as the client's CSS lays it out.
#import "../net/stub.h"
#import "app/launch.h"
#import "model/json.h"
#import "notify/notify.h"
#import "render/strings.h"
#import "snapshot.h"
#import "store/fixture.h"
#import "test.h"
#import "ui/composer/composer.h"
#import "ui/composer/textview.h"
#import "ui/prefs/prefs.h"
#import "ui/shell/shell.h"
#import "ui/sidebar/pane.h"

static NSDictionary *LastCall(SNFixtureSource *source, NSString *method) {
    for (NSArray *call in source.calls.reverseObjectEnumerator)
        if ([call[0] isEqualToString:method]) return call[1];
    return nil;
}

static BOOL Near(uint32_t a, uint32_t b, int tolerance) {
    for (int shift = 8; shift < 32; shift += 8)
        if (abs((int)((a >> shift) & 0xff) - (int)((b >> shift) & 0xff)) > tolerance) return NO;
    return YES;
}

static SNShell *Shell(void) {
    SNSetLanguage(@"en");
    return [[SNShell alloc] initWithSource:SNOpenFixture(SNPublicFixture()) defaults:nil];
}

static NSString *T(NSString *key) { return SNLocalized([@"prefs." stringByAppendingString:key]); }

SN_TEST(PreferencesSaveNotificationsAsSlack) {
    SNShell *shell = Shell();
    SNFixtureSource *source = (SNFixtureSource *)shell.source;
    SNPreferencesDialog *dialog = [SNPreferencesDialog showInWindow:shell.window source:source section:SNPrefsNotifications];
    SNExpect(SNPreferencesDialog.current == dialog && [dialog.optionTitles containsObject:T(@"notify.desktop")], "⌘, opens on Notifications");

    [dialog chooseOption:T(@"notify.desktop") value:nil];
    NSDictionary *sent = LastCall(source, @"users.prefs.setNotifications");
    SNExpect([sent isEqualToDictionary:(@{@"name" : @"global_desktop_push_enabled", @"value" : @"false", @"global" : @"true", @"sync" : @"false",
                                          @"_x_reason" : @"NotificationsGlobalPrefCheckbox"})],
             "Desktop notifications: users.prefs.setNotifications, global");
    SNExpect([SNNotificationPreference(source.preferences, @"global_desktop_push_enabled") isEqual:@NO], "kept in all_notifications_prefs' global at once");

    [dialog chooseOption:T(@"notify.what") value:@"everything"];
    sent = LastCall(source, @"users.prefs.setNotifications");
    NSArray *list = [NSJSONSerialization JSONObjectWithData:[sent[@"prefs"] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    SNExpect([list isEqualToArray:(@[ @{@"name" : @"global_desktop", @"value" : @"everything"}, @{@"name" : @"global_mobile", @"value" : @"everything"} ])] &&
                 [sent[@"_x_reason"] isEqualToString:@"NotificationsChannelDefaults"] && !sent[@"name"],
             "What to notify you about: desktop and mobile together, as a prefs list");

    [dialog chooseOption:T(@"notify.keywords") value:@"launch, rocket"];
    sent = LastCall(source, @"users.prefs.setNotifications");
    SNExpect([sent[@"name"] isEqualToString:@"global_keywords"] && [sent[@"value"] isEqualToString:@"launch,rocket"] &&
                 [sent[@"_x_reason"] isEqualToString:@"NotificationsKeywordsInput"],
             "Channel keywords, commas collapsed");

    [dialog chooseOption:T(@"notify.mute") value:nil];
    SNExpect([LastCall(source, @"users.prefs.set") isEqualToDictionary:(@{@"name" : @"mute_sounds", @"value" : @"true", @"_x_reason" : @"prefs-api/setUserPrefByApi"})],
             "Mute all messaging sounds: users.prefs.set");
    SNExpect([dialog chooseOption:T(@"notify.bounce") value:nil] && [SNPreferenceString(source.preferences, @"mac_ssb_bounce") isEqualToString:@"long"],
             "Bounce: long until asked to bounce once");
    // Its option shows once the dialog has the change.
    SNFlushChanges();
    [dialog chooseOption:T(@"notify.bounce.once") value:nil];
    SNExpect([SNPreferenceString(source.preferences, @"mac_ssb_bounce") isEqualToString:@"short"], "Only bounce it once: short");
    [dialog close];
    SNExpect(!SNPreferencesDialog.current, "closes");
}

SN_TEST(PreferencesTheClientHonours) {
    SNShell *shell = Shell();
    SNFixtureSource *source = (SNFixtureSource *)shell.source;
    SNPreferencesDialog *dialog = [SNPreferencesDialog showInWindow:shell.window source:source section:SNPrefsMessages];
    SNUser *someone = nil;
    for (SNUser *user in [source usersMatching:@"" limit:50])
        if (user.displayName.length && user.realName.length && ![user.displayName isEqualToString:user.realName]) someone = user;
    NSString *display = someone.visibleName;
    [dialog chooseOption:T(@"messages.names.full") value:nil];
    SNExpect([LastCall(source, @"users.prefs.set")[@"name"] isEqualToString:@"display_real_names_override"] &&
                 [LastCall(source, @"users.prefs.set")[@"value"] isEqualToString:@"1"],
             "Full & display names: display_real_names_override 1 when the workspace shows display names");
    SNExpect(!someone || ([[source userWithID:someone.userID].visibleName isEqualToString:someone.realName] && ![display isEqualToString:someone.realName]),
             "and everyone shows by their full name");
    [dialog chooseOption:T(@"messages.names.display") value:nil];
    SNExpect(!someone || [[source userWithID:someone.userID].visibleName isEqualToString:display], "display names again");
    [dialog chooseOption:T(@"messages.skin.3") value:nil];
    SNExpect(source.preferredSkinTone == 3, "the default skin tone");

    dialog.section = SNPrefsMarkAsRead;
    [dialog chooseOption:T(@"read.where") value:nil];
    NSDictionary *sent = LastCall(source, @"users.prefs.set");
    NSDictionary *prefs = [NSJSONSerialization JSONObjectWithData:[sent[@"prefs"] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    SNExpect([prefs isEqualToDictionary:(@{@"mark_msgs_read_immediately" : @"true", @"start_scroll_at_oldest" : @"true"})] &&
                 [sent[@"_x_reason"] isEqualToString:@"prefs-api/setMultipleUserPrefsByApi"],
             "When I view a channel: both prefs in one users.prefs.set");

    dialog.section = SNPrefsAdvanced;
    [dialog chooseOption:T(@"advanced.enter.line") value:nil];
    SNComposer *composer = nil;
    NSMutableArray<NSView *> *views = [NSMutableArray arrayWithObject:shell.window.contentView];
    while (views.count && !composer) {
        NSView *view = views.lastObject;
        [views removeLastObject];
        if ([view isKindOfClass:SNComposer.class]) composer = (SNComposer *)view;
        [views addObjectsFromArray:view.subviews];
    }
    SNComposerTextView *text = nil;
    views = [NSMutableArray arrayWithObject:composer ?: [NSView new]];
    while (views.count && !text) {
        NSView *view = views.lastObject;
        [views removeLastObject];
        if ([view isKindOfClass:SNComposerTextView.class]) text = (SNComposerTextView *)view;
        [views addObjectsFromArray:view.subviews];
    }
    SNExpect([LastCall(source, @"users.prefs.set")[@"name"] isEqualToString:@"msg_input_send_btn"] && text.returnStartsLine,
             "Enter starts a new line in the composer");
    [dialog chooseOption:T(@"advanced.code") value:nil];
    SNExpect(text.returnStartsLineInCode, "and in code blocks when asked");

    dialog.section = SNPrefsHome;
    SNSidebarPane *sidebar = (SNSidebarPane *)[shell paneInSlot:SNPaneSlotSidebar];
    NSUInteger before = sidebar.list.items.count;
    [dialog chooseOption:T(@"home.show.unreads") value:nil];
    SNExpect([LastCall(source, @"users.prefs.set")[@"value"] isEqualToString:@"hide_read_channels"], "Unreads only: sidebar_behavior");
    SNExpect(SNWaitUntil(1, ^BOOL { return sidebar.list.items.count < before; }), "the sidebar keeps what is unread");
    [dialog chooseOption:T(@"home.show.all") value:nil];
    SNExpect(SNWaitUntil(1, ^BOOL { return sidebar.list.items.count == before; }), "and shows everything again");
    [dialog close];
}

SN_TEST(PreferencesShapeNotifications) {
    SNStore *store = [[SNStore alloc] initWithDatabase:nil api:[SNTestAPI new]];
    [store performChanges:^{
        [store applyWorkspace:@{@"id" : @"T0NORTHWND", @"name" : @"Northwind Studio"}];
        [store applySelfUserID:@"U01ALEX"];
        [store applyUsers:@[ @{@"id" : @"U01ALEX", @"name" : @"alex"}, @{@"id" : @"U02SAM", @"name" : @"sam", @"profile" : @{@"real_name" : @"Sam Chen"}} ]];
        [store applyConversations:@[ @{@"id" : @"D05SAM", @"is_im" : @YES, @"user" : @"U02SAM"},
                                     @{@"id" : @"C02RANDOM", @"name" : @"random", @"is_channel" : @YES, @"is_member" : @YES} ]];
        [store applySections:@[ @{@"channel_section_id" : @"L01", @"type" : @"channels", @"channel_ids_page" : @{@"channel_ids" : @[ @"C02RANDOM" ]}} ]];
    }];
    SNNotifier *notifier = [[SNNotifier alloc] initWithStore:store];
    __block NSString *body = nil, *badge = nil;
    __block NSInteger bounces = 0;
    notifier.deliver = ^(NSString *identifier, NSString *title, NSString *subtitle, NSString *text, NSDictionary *info) { body = text; };
    notifier.showBadge = ^(NSString *label) { badge = label; };
    notifier.bounce = ^(BOOL untilActive) { bounces += untilActive ? 10 : 1; };
    NSDictionary *event = @{@"type" : @"message", @"channel" : @"D05SAM", @"ts" : @"1795400100.000100", @"user" : @"U02SAM", @"text" : @"lunch?"};
    [store applyPreferences:@{@"all_notifications_prefs" : @"{\"global\":{\"no_text_in_notifications\":true}}", @"mac_ssb_bounce" : @"short"}];
    [store applyEvent:event];
    SNExpect(body && body.length == 0 && bounces == 1, "no preview, and one bounce");
    body = nil;
    [store applyPreferences:@{@"all_notifications_prefs" : @"{\"global\":{\"global_desktop_push_enabled\":false}}"}];
    [store applyEvent:SNJSONMerge(event, @{@"ts" : @"1795400200.000100"})];
    SNExpect(!body, "desktop notifications off: none");
    [store applyPreferences:@{@"all_notifications_prefs" : @"{\"global\":{\"global_keywords\":\"rocket\"}}"}];
    SNMessage *rocket = [SNMessage messageWithJSON:@{@"ts" : @"1795400300.000100", @"user" : @"U02SAM", @"text" : @"the Rocket"} conversationID:@"C02RANDOM"];
    SNExpect([notifier shouldNotify:rocket inConversation:[store conversationWithID:@"C02RANDOM"]], "Channel keywords mention the user");
    [store markConversation:@"D05SAM" readThrough:@"1795400200.000100"];
    [store applyCounts:@{@"channels" : @[ @{@"id" : @"C02RANDOM", @"has_unreads" : @YES, @"mention_count" : @0} ],
                         @"ims" : @[ @{@"id" : @"D05SAM", @"has_unreads" : @NO, @"mention_count" : @0} ]}];
    SNExpect([badge isEqualToString:@"•"], "a dot for unread activity");
    [store applyPreferences:@{@"mac_ssb_bullet" : @NO}];
    SNExpect([badge isEqualToString:@""], "none once the badge is turned off");
    [store applyPreferences:@{@"show_typing" : @NO}];
    [store applyEvent:@{@"type" : @"user_typing", @"channel" : @"C02RANDOM", @"user" : @"U02SAM"}];
    SNExpect([store typingUserIDsInConversation:@"C02RANDOM" threadTS:nil].count == 0, "who is typing stays hidden");
}

SN_SNAPSHOT(PreferencesAsTheClientsCSS) {
    // No capture of the official dialog exists: its frame, list and controls are checked against
    // the client's CSS (c-sk-modal, c-tabs vertical, c-input_checkbox, c-select_button).
    SNShell *shell = Shell();
    SNFixtureSource *source = (SNFixtureSource *)shell.source;
    [source applyPreferences:@{@"mute_sounds" : @YES}];
    SNPreferencesDialog *dialog = [SNPreferencesDialog showInWindow:shell.window source:source section:SNPrefsNotifications];
    SNSettle(0.2);
    SNPixels *pixels = SNRenderWindow(shell.window);
    SNSaveSnapshot(@"preferences_notifications", pixels);
    NSRect panel = [dialog.panel convertRect:dialog.panel.bounds toView:nil];
    CGFloat height = NSHeight(shell.window.contentView.bounds), top = height - NSMaxY(panel), left = NSMinX(panel);
    SNExpect(NSWidth(panel) == MIN(800, NSWidth(shell.window.contentView.bounds) - 80) && NSHeight(panel) == MIN(700, height - 80), "800 x 700 at most, centred");
    SNExpect(Near([pixels colorAtPoint:NSMakePoint(left + 400, top + 76.5)], 0x373a3eff, 6), "a 1 pt otl-ter line under the 76 pt title bar");
    // Right of the labels, inside the 189 pt tabs.
    SNExpect(Near([pixels colorAtPoint:NSMakePoint(left + 16 + 180, top + 77 + 16 + 13)], SNColorBaseInvHgl1, 6), "the current section on base-inv-hgl-1, 16 pt in");
    SNExpect(Near([pixels colorAtPoint:NSMakePoint(left + 16 + 180, top + 77 + 16 + 27 + 4 + 13)], SNColorBasePry, 6), "the others on the dialog's base-pry");
    SNExpect(!Near([pixels colorAtPoint:NSMakePoint(left + 12, top + 77 + 16 + 13)], SNColorBaseInvHgl1, 6), "and 16 pt in from the dialog's edge");
    [dialog close];
    dialog = [SNPreferencesDialog showInWindow:shell.window source:source section:SNPrefsAdvanced];
    SNSettle(0.1);
    SNSaveSnapshot(@"preferences_advanced", SNRenderWindow(shell.window));
    [dialog close];
}
