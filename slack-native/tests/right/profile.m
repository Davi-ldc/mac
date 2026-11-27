// The profile flexpane on the public fixture: a click on a name opens it in the right column like
// a thread (X, back and forward), its requests and sections from Slack's made-up answers, the
// buttons, and a render of it.
#import "../net/stub.h"
#import "app/launch.h"
#import "render/strings.h"
#import "snapshot.h"
#import "store/fixture.h"
#import "test.h"
#import "ui/profile/profilecard.h"
#import "ui/right/profile.h"
#import "ui/right/thread.h"
#import "ui/shell/shell.h"

static SNShell *Shell(id<SNSource> source, SNLocation *location) {
    SNShell *shell = [[SNShell alloc] initWithSource:source defaults:nil];
    [shell go:location];
    [shell.window.contentView layoutSubtreeIfNeeded];
    return shell;
}

/// The panel the right column shows, if it shows one.
static SNProfilePanel *PanelIn(SNShell *shell) {
    NSView *column = [shell paneInSlot:SNPaneSlotSecondary].view;
    for (NSView *view in column.subviews)
        if ([view isKindOfClass:SNProfilePanel.class] && !view.hidden) return (SNProfilePanel *)view;
    return nil;
}

/// The texts of the panel's parts, depth first (labels, fields and rows as they draw them).
static NSArray<NSString *> *Texts(NSView *view) {
    NSMutableArray *texts = [NSMutableArray new];
    for (NSView *child in view.subviews) {
        if (child.hidden) continue;
        for (NSString *key in @[ @"text", @"label", @"value", @"title" ])
            if ([child respondsToSelector:NSSelectorFromString(key)]) {
                id text = [child valueForKey:key];
                if ([text isKindOfClass:NSString.class] && [text length]) [texts addObject:text];
            }
        [texts addObjectsFromArray:Texts(child)];
    }
    return texts;
}

SN_TEST(ProfilePanelOpensBesideTheConversation) {
    SNSetLanguage(@"en");
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    SNShell *shell = Shell(source, [SNLocation locationWithTab:SNTabHome conversation:@"C01GENERAL" thread:nil]);
    SNExpect(SNProfileCard.navigator == shell, "the card and the rows navigate this window");
    [SNProfileCard openProfileOfUser:@"U03PRIYA"];
    SNExpect([shell.location.panel isEqualToString:SNPanelProfile(@"U03PRIYA")] && [shell.location.conversationID isEqualToString:@"C01GENERAL"],
             "a click on a person opens their profile beside the conversation");
    SNExpect(shell.card.secondaryVisible && PanelIn(shell) != nil, "in the right column");
    NSArray *calls = source.calls;
    NSMutableArray *methods = [NSMutableArray new];
    for (NSArray *call in calls) [methods addObject:call[0]];
    NSUInteger sections = [methods indexOfObject:@"users.profile.getSections"], extras = [methods indexOfObject:@"users.profile.getExtras"];
    SNExpect(sections != NSNotFound && [calls[sections][1][@"user"] isEqualToString:@"U03PRIYA"] && [calls[sections][1][@"_x_reason"] isEqualToString:@"profiles"],
             "users.profile.getSections for the person, reason profiles");
    SNExpect(extras != NSNotFound && [calls[extras][1][@"keys"] isEqualToString:@"im_mpim_ids"], "users.profile.getExtras for the shared DMs");
    SNExpect([methods containsObject:@"users.profile.get"], "users.profile.get while the profile has no fields");

    [shell openThread:@"1795192800.000103" inConversation:@"C01GENERAL"];
    SNExpect(PanelIn(shell) == nil && shell.location.threadTS, "a thread takes the column's place");
    [shell goBack];
    SNExpect(PanelIn(shell) != nil, "back brings the profile again");
    [shell goForward];
    SNExpect(PanelIn(shell) == nil, "forward the thread");
    [shell goBack];
    [SNProfileCard openProfileOfUser:@"U02SAM"];
    SNExpect([PanelIn(shell).userID isEqualToString:@"U02SAM"], "another person's profile replaces it");
    [shell openConversation:@"C02RANDOM"];
    SNExpect([PanelIn(shell).userID isEqualToString:@"U02SAM"], "it stays beside the next conversation, as Slack's flexpanes");
    NSView *header = PanelIn(shell).subviews[1];
    for (NSView *view in header.subviews)
        if ([view isKindOfClass:SNButton.class]) ((SNButton *)view).action((SNButton *)view);
    SNExpect(!shell.location.panel && !shell.card.secondaryVisible, "its X closes it");
}

SN_TEST(ProfilePanelShowsSlacksSections) {
    SNSetLanguage(@"en");
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    SNShell *shell = Shell(source, [SNLocation locationWithTab:SNTabHome conversation:@"C01GENERAL" thread:nil]);
    [SNProfileCard openProfileOfUser:@"U03PRIYA"];
    SNProfilePanel *panel = PanelIn(shell);
    SNExpect(SNWaitUntil(2, ^BOOL { return [source profileSectionsOfUser:@"U03PRIYA"] && [source recentConversationsWithUser:@"U03PRIYA" more:NULL]; }), "the answers arrive");
    [panel layoutSubtreeIfNeeded];
    NSArray *texts = Texts(panel);
    SNExpect([texts containsObject:@"Profile"], "the header says Profile");
    for (NSString *text in @[ @"Contact information", @"Email address", @"priya@northwind.example", @"Phone", @"+44 20 7946 0000", @"Recent DMs", @"About me",
                              @"Team", @"Platform", @"northwind.example/priya", @"Go, Postgres, On-call" ])
        SNExpect([texts containsObject:text], [NSString stringWithFormat:@"shows %@", text].UTF8String);
    SNExpect(![texts containsObject:@"Secondary email"] && ![texts containsObject:@"Hobbies"], "missing elements are left out");
    SNExpect(![texts containsObject:@"Header"], "the HEADER section feeds the bio, not a section of its own");
    NSString *jordan = [source userWithID:@"U04JORDAN"].visibleName;
    SNExpect([texts containsObject:jordan], "a person field by name");
    NSUInteger contact = [texts indexOfObject:@"Contact information"], recent = [texts indexOfObject:@"Recent DMs"], about = [texts indexOfObject:@"About me"];
    SNExpect(contact < recent && recent < about, "Recent DMs right after the contact information, the rest in Slack's order");
    SNExpect([texts containsObject:@"Message"] && [texts containsObject:@"Huddle"] && [texts containsObject:@"VIP"], "the buttons");
}

SN_SNAPSHOT(ProfilePanelRendersAsTheFlexpane) {
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    SNSetLanguage(@"pt-BR");
    SNProfilePanel *panel = [[SNProfilePanel alloc] initWithUserID:@"U03PRIYA" source:source close:^{}];
    NSCalendar *calendar = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
    calendar.timeZone = [NSTimeZone timeZoneWithName:@"Europe/London"];
    panel.date = [calendar dateBySettingHour:14 minute:58 second:0 ofDate:[NSDate dateWithTimeIntervalSince1970:1795000000] options:0];
    SNWaitUntil(2, ^BOOL { return [source profileSectionsOfUser:@"U03PRIYA"] != nil && [source recentConversationsWithUser:@"U03PRIYA" more:NULL] != nil; });
    // The column paints the panel's surface.
    NSView *column = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 393, 1100)];
    column.wantsLayer = YES;
    column.layer.backgroundColor = SNCGColor(SNColorBasePry);
    panel.frame = column.bounds;
    [column addSubview:panel];
    SNSaveSnapshot(@"profile_panel", SNRenderView(column, column.frame.size));
    SNSetLanguage(@"en");
}
