// The user's menu from the rail's avatar: presence, the status dialog and clearing a status.
#import "../net/stub.h"
#import "app/launch.h"
#import "render/strings.h"
#import "test.h"
#import "ui/kit/dialog.h"
#import "ui/kit/popover.h"
#import "ui/shell/shell.h"
#import "ui/shell/status.h"
#import "ui/shell/youmenu.h"

static NSArray<NSString *> *Titles(NSArray<SNMenuItem *> *items) {
    NSMutableArray *titles = [NSMutableArray new];
    for (SNMenuItem *item in items) [titles addObject:item.title.length ? item.title : @"-"];
    return titles;
}

static NSArray *Calls(SNFixtureSource *source, NSString *method) {
    NSMutableArray *params = [NSMutableArray new];
    for (NSArray *call in source.calls)
        if ([call[0] isEqualToString:method]) [params addObject:call[1]];
    return params;
}

static void Choose(NSArray<SNMenuItem *> *items, NSString *title) {
    for (SNMenuItem *item in items)
        if ([item.title isEqualToString:title]) {
            void (^action)(void) = [item valueForKey:@"action"];
            if (action) action();
            return;
        }
}

SN_TEST(YouMenuOpensFromTheAvatar) {
    SNSetLanguage(@"en");
    SNShell *shell = [[SNShell alloc] initWithSource:SNOpenFixture(SNPublicFixture()) defaults:nil];
    [shell.window.contentView layoutSubtreeIfNeeded];
    shell.rail.youChosen(shell.rail.youButton);
    NSView *content = SNPopover.current.content;
    while (content && ![content isKindOfClass:SNMenu.class]) content = content.subviews.firstObject;
    SNExpect(content != nil, "the avatar opens a menu beside it");
    [SNPopover.current close];
}

SN_TEST(YouMenuSetsPresence) {
    SNSetLanguage(@"en");
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    SNShell *shell = [[SNShell alloc] initWithSource:source defaults:nil];
    NSArray *items = SNYouMenuItems(source, shell, shell.window);
    NSArray *expected = @[ @"Update your status", @"Set yourself as away", @"-", @"Profile", @"Preferences", @"-", @"Sign out of Northwind Studio" ];
    SNExpect([Titles(items) isEqualToArray:expected], "status, presence, profile, preferences, sign out");
    Choose(items, @"Set yourself as away");
    SNExpect([source presenceOfUser:source.me.userID] == SNPresenceAway && [[Calls(source, @"presence.set").lastObject objectForKey:@"presence"] isEqualToString:@"away"],
             "away at once, presence.set away");
    items = SNYouMenuItems(source, shell, shell.window);
    SNExpect([Titles(items)[1] isEqualToString:@"Set yourself as active"], "then it offers active");
    Choose(items, @"Set yourself as active");
    SNExpect([source presenceOfUser:source.me.userID] == SNPresenceActive && [[Calls(source, @"presence.set").lastObject objectForKey:@"presence"] isEqualToString:@"active"],
             "and back to active");
    source.failsRequests = YES;
    Choose(SNYouMenuItems(source, shell, shell.window), @"Set yourself as away");
    SNExpect([source presenceOfUser:source.me.userID] == SNPresenceAway && SNWaitUntil(1, ^BOOL { return [source presenceOfUser:source.me.userID] == SNPresenceActive; }), "a refusal puts it back");
    source.failsRequests = NO;
    Choose(items, @"Profile");
    SNExpect([shell.location.panel isEqualToString:SNPanelProfile(source.me.userID)], "Profile opens the user's own profile");
}

SN_TEST(YouMenuSetsAndClearsTheStatus) {
    SNSetLanguage(@"en");
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    SNShell *shell = [[SNShell alloc] initWithSource:source defaults:nil];
    Choose(SNYouMenuItems(source, shell, shell.window), @"Update your status");
    SNStatusDialog *status = SNStatusDialog.current;
    SNExpect(status && !SNConfirmDialog.current.confirmEnabled, "the dialog opens; Save waits for a status");
    NSArray *suggestions = @[ @"In a meeting", @"Commuting", @"Out sick", @"Vacationing", @"Working remotely" ];
    SNExpect([status.suggestionTitles isEqualToArray:suggestions], "Slack's suggestions");
    [status chooseSuggestionAtIndex:1];
    SNExpect([status.text isEqualToString:@"Commuting"] && [status.emoji isEqualToString:@"bus"] && [status.clearAfter isEqualToString:@"30_minutes"] &&
                 SNConfirmDialog.current.confirmEnabled,
             "a suggestion fills the text, the emoji and when it clears");
    NSDate *before = NSDate.date;
    [status save];
    NSDictionary *profile = [NSJSONSerialization JSONObjectWithData:[[Calls(source, @"users.profile.set").lastObject objectForKey:@"profile"] dataUsingEncoding:NSUTF8StringEncoding]
                                                            options:0
                                                              error:nil];
    double expiration = [profile[@"status_expiration"] doubleValue];
    SNExpect([profile[@"status_text"] isEqualToString:@"Commuting"] && [profile[@"status_text_canonical"] isEqualToString:@"Commuting"] &&
                 [profile[@"status_emoji"] isEqualToString:@":bus:"] &&
                 fabs(expiration - before.timeIntervalSince1970 - 1800) < 5,
             "users.profile.set with the text, the emoji and 30 minutes from now");
    SNExpect([source.me.statusText isEqualToString:@"Commuting"] && !SNConfirmDialog.current, "shown at once, the dialog closed");
    NSArray *items = SNYouMenuItems(source, shell, shell.window);
    SNExpect([Titles(items)[0] hasSuffix:@" Commuting"] && [Titles(items)[1] isEqualToString:@"Clear status"], "the menu shows the status and offers clearing it");
    Choose(items, @"Clear status");
    profile = [NSJSONSerialization JSONObjectWithData:[[Calls(source, @"users.profile.set").lastObject objectForKey:@"profile"] dataUsingEncoding:NSUTF8StringEncoding]
                                              options:0
                                                error:nil];
    SNExpect([profile[@"status_text"] isEqualToString:@""] && [profile[@"status_emoji"] isEqualToString:@""] && profile[@"status_text_canonical"] == NSNull.null &&
                 [profile[@"status_expiration"] isEqual:@0] && !source.me.statusText.length,
             "cleared as Slack clears it");

    Choose(SNYouMenuItems(source, shell, shell.window), @"Update your status");
    status = SNStatusDialog.current;
    status.text = @"Writing tests";
    SNExpect([status.clearAfter isEqualToString:@"all_day"] && SNConfirmDialog.current.confirmEnabled, "a status of one's own clears today by default");
    [status save];
    profile = [NSJSONSerialization JSONObjectWithData:[[Calls(source, @"users.profile.set").lastObject objectForKey:@"profile"] dataUsingEncoding:NSUTF8StringEncoding]
                                              options:0
                                                error:nil];
    SNExpect([profile[@"status_emoji"] isEqualToString:@":speech_balloon:"] && [profile[@"status_text_canonical"] isEqualToString:@""],
             "without an emoji Slack's speech balloon, and no canonical text");
}

SN_TEST(YouStatusClearsWhenSlackDoes) {
    NSCalendar *calendar = NSCalendar.currentCalendar;
    NSDate *now = [calendar dateBySettingHour:10 minute:7 second:0 ofDate:NSDate.date options:0];
    NSDate *midnight = [calendar dateByAddingUnit:NSCalendarUnitDay value:1 toDate:[calendar startOfDayForDate:now] options:0];
    SNExpect(SNStatusExpiration(@"no_expiration", now) == 0 && SNStatusExpiration(@"1_hour", now) == now.timeIntervalSince1970 + 3600 &&
                 SNStatusExpiration(@"all_day", now) == midnight.timeIntervalSince1970 - 1 &&
                 SNStatusExpiration(@"all_next_day", now) == [calendar dateByAddingUnit:NSCalendarUnitDay value:1 toDate:midnight options:0].timeIntervalSince1970 - 1,
             "never, an hour from now, the last second of today and of tomorrow");
    NSDate *week;
    [calendar rangeOfUnit:NSCalendarUnitWeekOfYear startDate:&week interval:NULL forDate:now];
    SNExpect(SNStatusExpiration(@"week", now) == [calendar dateByAddingUnit:NSCalendarUnitWeekOfYear value:1 toDate:week options:0].timeIntervalSince1970 - 1,
             "the last second of the week");
}

SN_TEST(YouMenuHandlesCustomEmojiOnlyStatus) {
    SNSetLanguage(@"en");
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    SNShell *shell = [[SNShell alloc] initWithSource:source defaults:nil];
    [source performChanges:^{
        [source applyUsers:@[ @{@"id" : source.me.userID, @"name" : @"alex", @"profile" : @{@"status_emoji" : @":party_parrot:", @"status_text" : @""}} ]];
    }];
    NSArray<SNMenuItem *> *items = SNYouMenuItems(source, shell, shell.window);
    SNExpect([items[0].title isEqualToString:@":party_parrot:"] && [items[1].title isEqualToString:@"Clear status"],
             "custom-emoji-only status with empty text shows fallback emoji name");
    [source performChanges:^{
        [source applyUsers:@[ @{@"id" : source.me.userID, @"name" : @"alex", @"profile" : @{@"status_emoji" : @":shipit:"}} ]];
    }];
    items = SNYouMenuItems(source, shell, shell.window);
    SNExpect(items[0].title != nil && [items[0].title isEqualToString:@":shipit:"],
             "custom-emoji-only status with nil status_text never passes nil or blanks the row");
    SNMenu *menu = [[SNMenu alloc] initWithItems:items width:0];
    SNExpect(menu != nil && NSHeight(menu.frame) > 0, "menu builds safely without crashing");
}
