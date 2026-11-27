// The views the client's own commands open, drawn over the public fixture. No capture of the
// official ones exists: they are checked against the client's CSS (c-sk-modal, c-input_text,
// c-date_picker, c-token, c-channel_search_result, p-shortcuts_flexpane, p-gif_picker).
#import "app/launch.h"
#import "render/expandable.h"
#import "render/strings.h"
#import "snapshot.h"
#import "store/fixture.h"
#import "test.h"
#import "ui/composer/addpeople.h"
#import "ui/composer/gifpicker.h"
#import "ui/composer/invitepeople.h"
#import "ui/composer/reminder.h"
#import "ui/kit/dialog.h"
#import "ui/kit/forms.h"
#import "ui/kit/people.h"
#import "ui/shell/shell.h"

/// The first view of `kind` under `view`.
static id Find(NSView *view, Class kind) {
    if ([view isKindOfClass:kind]) return view;
    for (NSView *child in view.subviews) {
        id found = Find(child, kind);
        if (found) return found;
    }
    return nil;
}

SN_SNAPSHOT(LocalCommandViewsAsTheClientsCSS) {
    SNSetLanguage(@"en");
    SNShell *shell = [[SNShell alloc] initWithSource:SNOpenFixture(SNPublicFixture()) defaults:nil];
    SNFixtureSource *source = (SNFixtureSource *)shell.source;
    NSString *channel = shell.location.conversationID;
    NSWindow *window = shell.window;

    NSDate *morning = [NSCalendar.currentCalendar dateBySettingHour:10 minute:7 second:30 ofDate:NSDate.date options:0];
    SNReminderDialog *reminder = [SNReminderDialog showInWindow:window source:source conversation:channel threadTS:nil now:morning];
    reminder.descriptionText = @"Send the invoices";
    SNSettle(0.2);
    SNPixels *pixels = SNRenderWindow(window);
    SNSaveSnapshot(@"local_reminder", pixels);
    NSRect panel = [SNConfirmDialog.current.panel convertRect:SNConfirmDialog.current.panel.bounds toView:nil];
    SNExpect(NSWidth(panel) == 500, "the Reminder dialog is 500 wide (its maxWidth)");
    SNFormDatePicker *picker = Find(SNConfirmDialog.current.panel, SNFormDatePicker.class);
    [picker open];
    SNSettle(0.1);
    SNSaveSnapshot(@"local_reminder_calendar", SNRenderWindow(window));
    SNExpect(picker.calendar && NSWidth(picker.calendar.frame) == 332, "the calendar: 300 pt month in 16 pt of padding");
    [reminder cancel];
    SNSettle(0.1);

    [shell go:[SNLocation locationWithTab:SNTabHome conversation:nil thread:nil page:SNPageChannels panel:nil]];
    SNSettle(0.3);
    SNSaveSnapshot(@"local_channel_browser", SNRenderWindow(window));

    [shell openConversation:channel];
    [shell go:[shell.location locationWithPanel:SNPanelShortcuts]];
    SNSettle(0.2);
    SNSaveSnapshot(@"local_shortcuts_panel", SNRenderWindow(window));
    [shell go:[shell.location locationWithPanel:SNPanelFeedback]];
    SNSettle(0.2);
    pixels = SNRenderWindow(window);
    SNSaveSnapshot(@"local_feedback_panel", pixels);
    [shell go:[shell.location locationWithPanel:nil]];

    SNConversation *conversation = [source conversationWithID:channel];
    SNAddPeopleDialog *add = [SNAddPeopleDialog showForChannel:conversation users:@[] inWindow:window source:source];
    SNUser *someone = nil;
    for (SNUser *user in [source usersMatching:@"" limit:20])
        if (!user.isBot && ![user.userID isEqualToString:source.me.userID]) {
            someone = user;
            break;
        }
    if (someone) add.picker.userIDs = @[ someone.userID ];
    [add.picker typeQuery:[someone.handle substringToIndex:MIN(2, someone.handle.length)] ?: @"a"];
    SNSettle(0.2);
    SNSaveSnapshot(@"local_add_people", SNRenderWindow(window));
    [add.dialog cancel];

    SNInvitePeopleDialog *invite = [SNInvitePeopleDialog showInWindow:window source:source emails:@[ @"ana@acme.example", @"bia@acme.example" ]];
    SNSettle(0.1);
    pixels = SNRenderWindow(window);
    SNSaveSnapshot(@"local_invite_people", pixels);
    SNExpect(invite != nil, "the invite dialog opens");
    [invite.dialog cancel];

    SNConversation *dm = nil;
    for (SNConversation *candidate in source.directMessages)
        if (candidate.kind == SNConversationDirect && ![candidate.userID isEqualToString:source.me.userID]) dm = candidate;
    if (dm && someone) {
        SNAddPeopleDialog *group = [SNAddPeopleDialog showForConversation:dm users:@[ someone.userID ] inWindow:window source:source navigator:shell];
        [group confirm];
        SNSettle(0.1);
        SNSaveSnapshot(@"local_group_history", SNRenderWindow(window));
        [group.dialog cancel];
    }

    NSView *composer = Find(window.contentView, NSClassFromString(@"SNComposer"));
    NSView *emoji = composer.subviews.count ? Find(composer, NSClassFromString(@"SNComposerEmojiButton")) : nil;
    if (emoji) {
        [SNGifPicker showForRect:emoji.bounds inView:emoji source:source query:@"cats" picked:^(NSDictionary *attachment, NSURL *preview) {}];
        SNSettle(0.2);
        SNSaveSnapshot(@"local_gif_picker", SNRenderWindow(window));
        [SNGifPicker.current close];
    }

    NSArray<SNMessage *> *messages = [source messagesInConversation:channel];
    NSMutableArray *keys = [NSMutableArray new];
    for (SNMessage *message in messages) [keys addObjectsFromArray:SNExpandableKeysOfMessage(message, SNViewContextChannel)];
    [source setItems:keys expanded:NO inMessages:messages];
    SNSettle(0.2);
    SNSaveSnapshot(@"local_collapsed", SNRenderWindow(window));
    [source setItems:keys expanded:YES inMessages:messages];
}
