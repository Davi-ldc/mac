// The Preferences' VIP section on the public fixture (a paid plan; Priya is a VIP; Slack recommends
// Priya, Sam, a deactivated Casey and Jordan): where it is, its check, the list and its buttons.
#import "../net/stub.h"
#import "app/launch.h"
#import "render/strings.h"
#import "store/fixture.h"
#import "test.h"
#import "ui/prefs/prefs.h"
#import "ui/prefs/vips.h"
#import "ui/profile/toast.h"
#import "ui/shell/shell.h"

SN_TEST(PrefsOfferTheVIPSectionAfterNotifications) {
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    SNSetLanguage(@"en");
    SNShell *shell = [[SNShell alloc] initWithSource:source defaults:nil];
    SNPreferencesDialog *dialog = [SNPreferencesDialog showInWindow:shell.window source:source section:SNPrefsNotifications];
    SNExpect([dialog.sections[1] integerValue] == SNPrefsVIP, "VIP comes right after Notifications");
    SNExpect([dialog.optionTitles containsObject:@"Messages from VIPs, even if notifications are paused"], "Notifications has the VIPs' check");
    dialog.section = SNPrefsVIP;
    SNExpect([dialog.optionTitles containsObject:@"Always allow notifications from VIPs"], "the VIP section's check");
    [dialog chooseOption:@"Always allow notifications from VIPs" value:nil];
    NSArray *call = source.calls.lastObject;
    SNExpect([call[0] isEqualToString:@"users.prefs.set"] && [call[1][@"name"] isEqualToString:@"priority_dnd_override"] && [call[1][@"value"] isEqualToString:@"true"],
             "it saves priority_dnd_override with users.prefs.set");
    SNExpect(SNPreferenceBool(source.preferences, @"priority_dnd_override", NO), "at once");

    SNPrefsVIPList *list = (SNPrefsVIPList *)dialog.customView;
    SNExpect([list isKindOfClass:SNPrefsVIPList.class], "the VIP list is the section's last part");
    NSString *priya = [source userWithID:@"U03PRIYA"].visibleName, *sam = [source userWithID:@"U02SAM"].visibleName, *jordan = [source userWithID:@"U04JORDAN"].visibleName;
    SNExpect(SNWaitUntil(1, ^BOOL { return [list.texts containsObject:@"Recommended"]; }), "the recommendations arrive");
    NSArray *expected = @[ @"Added to your VIP list", [priya stringByAppendingString:@": Remove"], @"Recommended", [sam stringByAppendingString:@": Add"],
                           [jordan stringByAppendingString:@": Add"] ];
    SNExpect([list.texts isEqualToArray:expected], "VIPs with Remove; recommendations who are not VIPs nor deactivated, with Add");
    NSUInteger asked = NSNotFound;
    for (NSUInteger i = 0; i < source.calls.count; i++)
        if ([source.calls[i][0] isEqualToString:@"users.priority.getRecommendations"]) asked = i;
    SNExpect(asked != NSNotFound && [source.calls[asked][1][@"limit"] isEqualToString:@"99"], "users.priority.getRecommendations, 99 of them");

    [list clickButtonOfUser:@"U03PRIYA"];
    SNExpect(source.vipUserIDs.count == 0 && [list.texts[1] isEqualToString:@"No VIPs added yet"], "Remove takes Priya off; the list says it is empty");
    SNExpect([list.texts containsObject:[priya stringByAppendingString:@": Add"]], "and she is recommended again");
    [list clickButtonOfUser:@"U02SAM"];
    SNExpect([source.vipUserIDs isEqualToArray:@[ @"U02SAM" ]] && [list.texts[1] isEqualToString:[sam stringByAppendingString:@": Remove"]], "Add makes Sam a VIP");
    [list choose:@"U04JORDAN"];
    SNExpect([source.vipUserIDs containsObject:@"U04JORDAN"], "choosing someone in the search adds them");
    [SNToast close];
    [dialog close];
}

SN_TEST(PrefsLeaveVIPsOutOfAFreePlan) {
    SNStore *store = [[SNStore alloc] initWithDatabase:nil api:[SNTestAPI new]];
    [store performChanges:^{
        [store applyWorkspace:@{@"id" : @"T0NORTHWND", @"name" : @"Northwind Studio", @"domain" : @"northwind-studio"}];
        [store applySelfUserID:@"U01ALEX"];
        [store applyUsers:@[ @{@"id" : @"U01ALEX", @"name" : @"alex"} ]];
    }];
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1000, 800) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:YES];
    window.releasedWhenClosed = NO;
    window.contentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 1000, 800)];
    SNPreferencesDialog *dialog = [SNPreferencesDialog showInWindow:window source:store section:SNPrefsNotifications];
    SNExpect(![dialog.sections containsObject:@(SNPrefsVIP)], "no VIP section without a plan");
    [dialog close];
}
