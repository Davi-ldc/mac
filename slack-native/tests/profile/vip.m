// The VIP button of the profile card on the public fixture (a paid plan; Priya is a VIP): who has
// it, its state, the toggle's requests and toasts, Slack's refusals.
#import "../net/stub.h"
#import "app/launch.h"
#import "render/strings.h"
#import "store/fixture.h"
#import "test.h"
#import "ui/profile/profilecard.h"
#import "ui/profile/toast.h"
#import "ui/profile/vip.h"

static NSWindow *Window(void) {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 800, 600) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:YES];
    window.releasedWhenClosed = NO;
    window.contentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
    return window;
}

static SNProfileCardView *Card(SNFixtureSource *source, NSString *userID, NSWindow *window) {
    SNProfileCardView *card = [[SNProfileCardView alloc] initWithUser:[source userWithID:userID] source:source];
    [window.contentView addSubview:card];
    return card;
}

SN_TEST(ProfileCardShowsTheVIPButtonAsSlack) {
    SNSetLanguage(@"en");
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    NSWindow *window = Window();
    SNExpect(([Card(source, @"U03PRIYA", window).buttonTitles isEqualToArray:@[ @"Message", @"Huddle", @"Remove from VIP" ]]), "a VIP's card offers to remove them");
    SNExpect(([Card(source, @"U02SAM", window).buttonTitles isEqualToArray:@[ @"Message", @"Huddle", @"Add to VIP" ]]), "someone else's offers to add them");
    SNExpect(Card(source, source.me.userID, window).buttonTitles.count == 2, "one's own card has no VIP button");
    SNExpect(Card(source, @"U07CASEY", window).buttonTitles.count == 2, "nor a deactivated person's");
    SNUser *agent = [[source userWithID:@"U02SAM"] userByMergingJSON:@{@"is_agentforce_bot" : @YES}];
    SNExpect(!SNCanToggleVIP(source, agent), "nor an Agentforce agent's");
}

SN_TEST(ProfileCardTogglesVIPsWithToasts) {
    SNSetLanguage(@"en");
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    NSWindow *window = Window();
    SNProfileCardView *card = Card(source, @"U02SAM", window);
    NSString *name = [source userWithID:@"U02SAM"].visibleName;
    [card clickButton:@"Add to VIP"];
    SNExpect([source.vipUserIDs containsObject:@"U02SAM"], "the click makes Sam a VIP at once");
    SNExpect([card.buttonTitles.lastObject isEqualToString:@"Remove from VIP"], "and the button says so");
    NSArray *call = source.calls.lastObject;
    SNExpect([call[0] isEqualToString:@"users.priority.add"] && [call[1][@"user"] isEqualToString:@"U02SAM"], "users.priority.add for Sam");
    NSString *added = [NSString stringWithFormat:@"Added %@ to VIPs", name];
    SNExpect(SNWaitUntil(1, ^BOOL { return [SNToast.currentText isEqualToString:added]; }), "the toast says who was added, after Slack agreed");
    [card clickButton:@"Remove from VIP"];
    SNExpect(![source.vipUserIDs containsObject:@"U02SAM"] && [card.buttonTitles.lastObject isEqualToString:@"Add to VIP"], "a second click takes Sam off");
    NSString *removed = [NSString stringWithFormat:@"Removed %@ from VIPs", name];
    SNExpect(SNWaitUntil(1, ^BOOL { return [SNToast.currentText isEqualToString:removed]; }), "and the toast says so");
    [SNToast close];
    source.failsRequests = YES;
    [card clickButton:@"Add to VIP"];
    SNExpect(SNWaitUntil(1, ^BOOL { return ![source.vipUserIDs containsObject:@"U02SAM"]; }) && SNToast.currentText == nil, "without an answer it is undone, silently");
}

SN_TEST(ProfileCardSaysWhySlackRefusedAVIP) {
    SNSetLanguage(@"en");
    SNTestAPI *api = [SNTestAPI new];
    __block NSString *refusal = @"too_many_vips";
    api.answer = ^NSDictionary *(NSString *method, NSDictionary *params) { return @{@"ok" : @NO, @"error" : refusal, @"max_vip_limit" : @25}; };
    SNStore *store = [[SNStore alloc] initWithDatabase:nil api:api];
    [store performChanges:^{
        [store applyWorkspace:@{@"id" : @"T0NORTHWND", @"name" : @"Northwind Studio", @"domain" : @"northwind-studio", @"plan" : @"std"}];
        [store applySelfUserID:@"U01ALEX"];
        [store applyUsers:@[ @{@"id" : @"U01ALEX", @"name" : @"alex"}, @{@"id" : @"U02SAM", @"name" : @"sam", @"profile" : @{@"display_name" : @"Sam"}} ]];
    }];
    NSWindow *window = Window();
    SNUser *sam = [store userWithID:@"U02SAM"];
    SNToggleVIP(store, sam, window);
    SNExpect(SNWaitUntil(1, ^BOOL { return [SNToast.currentText isEqualToString:@"Sam could not be added to VIP. You can only have a maximum of 25 VIPs."]; }),
             "too_many_vips names the limit Slack gave");
    SNExpect(store.vipUserIDs.count == 0, "and Sam is not a VIP");
    refusal = @"user_not_found";
    SNToggleVIP(store, sam, window);
    SNExpect(SNWaitUntil(1, ^BOOL { return [SNToast.currentText isEqualToString:@"User is not eligible to be added as VIP."]; }), "user_not_found");
    refusal = @"no_bot_vip";
    SNToggleVIP(store, sam, window);
    SNExpect(SNWaitUntil(1, ^BOOL { return [SNToast.currentText isEqualToString:@"Hmm, something went wrong. Try again?"]; }), "anything else");
    [SNToast close];
}
