// The client's own commands that open Slack's views (values made up, shapes as its static JS
// sends and reads them): /remind alone, /collapse and /expand, /open alone, /invite in DMs and
// private channels, /shortcuts, /feedback, /gif and /invite_people.
#import "../net/stub.h"
#import "model/json.h"
#import "render/expandable.h"
#import "render/strings.h"
#import "store/database.h"
#import "store/store.h"
#import "test.h"
#import "ui/channel/browser.h"
#import "ui/channel/messagelayout.h"
#import "ui/composer/addpeople.h"
#import "ui/composer/commands.h"
#import "ui/composer/gifpicker.h"
#import "ui/composer/invitepeople.h"
#import "ui/composer/reminder.h"
#import "ui/composer/richtext.h"
#import "ui/kit/dialog.h"
#import "ui/kit/people.h"
#import "ui/right/panels.h"

@interface SNLocalTestNavigator : NSObject <SNNavigator>
@property (nonatomic) SNLocation *location;
@property (nonatomic) NSMutableArray<NSString *> *moves;
@end

@implementation SNLocalTestNavigator
- (instancetype)init {
    if (!(self = [super init])) return nil;
    _location = [SNLocation locationWithTab:SNTabDirectMessages conversation:@"C01DESIGN" thread:nil];
    _moves = [NSMutableArray new];
    return self;
}
- (void)go:(SNLocation *)location { self.location = location; }
- (void)openConversation:(NSString *)conversationID {
    [self.moves addObject:conversationID];
    self.location = [SNLocation locationWithTab:self.location.tab conversation:conversationID thread:nil page:nil panel:self.location.panel];
}
- (void)openThread:(NSString *)threadTS inConversation:(NSString *)conversationID {}
- (void)closeThread {}
- (void)selectTab:(SNTab)tab {}
- (void)openSearchWithQuery:(NSString *)query {}
- (void)resetSidebarFilter {}
@end

static NSURL *TemporaryDatabase(NSString *name) {
    NSURL *folder = [NSFileManager.defaultManager.temporaryDirectory URLByAppendingPathComponent:@"slack-native-tests" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *url = [folder URLByAppendingPathComponent:[name stringByAppendingPathExtension:@"sqlite"]];
    for (NSString *suffix in @[ @"", @"-wal", @"-shm" ]) [NSFileManager.defaultManager removeItemAtPath:[url.path stringByAppendingString:suffix] error:nil];
    return url;
}

static SNStore *Store(SNTestAPI *api, SNDatabase *database) {
    SNStore *store = [[SNStore alloc] initWithDatabase:database api:api];
    [store performChanges:^{
        [store applyWorkspace:@{@"id" : @"T0NORTHWND", @"name" : @"Northwind Studio", @"domain" : @"northwind-studio"}];
        [store applySelfUserID:@"U01ALEX"];
        [store applyUsers:@[
            @{@"id" : @"U01ALEX", @"name" : @"alex", @"profile" : @{@"display_name" : @"Alex", @"email" : @"alex@northwind.example"}},
            @{@"id" : @"U02KIM", @"name" : @"kim", @"profile" : @{@"display_name" : @"Kim", @"real_name" : @"Kim Lee"}},
            @{@"id" : @"U03SAM", @"name" : @"sam", @"profile" : @{@"display_name" : @"Sam", @"real_name" : @"Sam Rivera"}},
            @{@"id" : @"B04BOT", @"name" : @"deploybot", @"is_bot" : @YES, @"profile" : @{@"display_name" : @"Deploybot"}}
        ]];
        [store applyConversations:@[
            @{@"id" : @"C01DESIGN", @"name" : @"design", @"is_channel" : @YES, @"is_member" : @YES, @"num_members" : @6},
            @{@"id" : @"G03SECRET", @"name" : @"secret-plans", @"is_group" : @YES, @"is_private" : @YES, @"is_member" : @YES, @"num_members" : @4},
            @{@"id" : @"D05KIM", @"is_im" : @YES, @"user" : @"U02KIM", @"is_open" : @YES},
            @{@"id" : @"D06SELF", @"is_im" : @YES, @"user" : @"U01ALEX", @"is_open" : @YES}
        ]];
    }];
    return store;
}

static NSAttributedString *Rest(NSArray *parts) {
    NSMutableAttributedString *rest = [NSMutableAttributedString new];
    for (id part in parts) {
        if ([part isKindOfClass:NSString.class]) {
            [rest appendAttributedString:[[NSAttributedString alloc] initWithString:part]];
            continue;
        }
        SNRichEntity *entity = [SNRichEntity entityWithKind:SNRichEntityUser value:part[@"user"]];
        [rest appendAttributedString:[[NSAttributedString alloc] initWithString:[@"@" stringByAppendingString:part[@"user"]] attributes:@{SNRichEntityAttribute : entity}]];
    }
    return rest;
}

static void Run(SNSlashCommands *commands, NSString *typed, NSArray *rest, NSString *conversationID, NSString *threadTS, NSWindow *window) {
    [commands run:typed rest:Rest(rest) inConversation:conversationID threadTS:threadTS window:window restore:^{}];
}

static NSDictionary *LastCall(SNTestAPI *api, NSString *method) {
    for (NSArray *call in api.calls.reverseObjectEnumerator)
        if ([call[0] isEqualToString:method]) return call[1];
    return nil;
}

static NSWindow *Window(void) {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1000, 800) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:YES];
    window.releasedWhenClosed = NO;
    return window;
}

static NSDate *At(NSInteger hour, NSInteger minute) { return [NSCalendar.currentCalendar dateBySettingHour:hour minute:minute second:30 ofDate:NSDate.date options:0]; }

static id JSON(NSString *text) { return [NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil]; }

SN_TEST(SlashRemindAloneOpensSlacksReminderDialog) {
    SNSetLanguage(@"en");
    NSCalendar *calendar = NSCalendar.currentCalendar;
    SNExpect([[calendar dateBySettingHour:10 minute:15 second:0 ofDate:NSDate.date options:0] isEqualToDate:SNReminderDefaultTime(At(10, 7))] &&
                 [[calendar dateBySettingHour:10 minute:30 second:0 ofDate:NSDate.date options:0] isEqualToDate:SNReminderDefaultTime(At(10, 11))] &&
                 [[calendar dateBySettingHour:10 minute:15 second:0 ofDate:NSDate.date options:0] isEqualToDate:SNReminderDefaultTime(At(10, 10))],
             "it starts five minutes ahead, rounded up to the quarter hour");

    SNTestAPI *api = [SNTestAPI new];
    SNStore *store = Store(api, nil);
    SNSlashCommands *commands = [[SNSlashCommands alloc] initWithSource:store];
    commands.clock = ^NSDate * { return At(10, 7); };
    NSWindow *window = Window();
    Run(commands, @"/remind", @[], @"C01DESIGN", nil, window);
    SNReminderDialog *reminder = SNReminderDialog.current;
    SNExpect(reminder && !LastCall(api, @"chat.command"), "/remind alone opens the Reminder dialog, not Slack's command");
    SNExpect(!reminder.canSave && !SNConfirmDialog.current.confirmEnabled, "Save waits for a description");
    SNExpect([reminder.time isEqualToString:@"10:15"] && [reminder.timeValues.firstObject isEqualToString:@"10:15"] && reminder.timeValues.count == 55,
             "at 10:07 today offers the quarter hours from 10:12 on, starting at 10:15");
    NSDate *tomorrow = [calendar dateByAddingUnit:NSCalendarUnitDay value:1 toDate:[calendar startOfDayForDate:At(10, 7)] options:0];
    reminder.day = tomorrow;
    SNExpect([reminder.timeValues.firstObject isEqualToString:@"00:00"] && reminder.timeValues.count == 96, "another day offers all 96");
    reminder.time = @"09:15";
    reminder.descriptionText = @"Send the invoices";
    SNExpect(reminder.canSave, "a description enables Save");
    [reminder save];
    NSDictionary *saved = LastCall(api, @"saved.add");
    NSArray *description = JSON(saved[@"description"]);
    NSDate *due = [calendar dateBySettingHour:9 minute:15 second:0 ofDate:tomorrow options:0];
    SNExpect([saved[@"item_type"] isEqualToString:@"reminder"] && [saved[@"date_due"] isEqualToString:@((long long)due.timeIntervalSince1970).stringValue] &&
                 [saved[@"_x_reason"] isEqualToString:@"saved-api/saveReminder"] && !saved[@"todo_state"] && !saved[@"channel"],
             "saved.add item_type=reminder, due in whole seconds, no conversation");
    SNExpect([description.firstObject[@"type"] isEqualToString:@"rich_text"] && [saved[@"description"] containsString:@"Send the invoices"], "the description as rich_text");
    SNExpect([saved[@"client_id"] rangeOfString:@"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[0-9a-f]{4}-[0-9a-f]{12}$" options:NSRegularExpressionSearch].location == 0,
             "with a client_id of its own (a v4 UUID)");
    SNExpect(!SNConfirmDialog.current && !SNReminderDialog.current, "Save closes it at once, as Slack's does");
}

SN_TEST(SlashCollapseAndExpandKeepEveryItemPerColumn) {
    SNSetLanguage(@"en");
    NSURL *url = TemporaryDatabase(@"expandables");
    SNTestAPI *api = [SNTestAPI new];
    NSDictionary *picture = @{@"id" : @"F01CHART", @"name" : @"chart.png", @"title" : @"chart.png", @"mimetype" : @"image/png", @"filetype" : @"png", @"original_w" : @800,
                              @"original_h" : @400, @"thumb_720" : @"https://files.example.com/chart-720.png", @"thumb_720_w" : @720, @"thumb_720_h" : @360};
    NSArray *history = @[
        @{@"type" : @"message", @"ts" : @"1795400000.000500", @"user" : @"U02KIM", @"text" : @"",
          @"blocks" : @[ @{@"type" : @"image", @"block_id" : @"chart", @"image_url" : @"https://files.example.com/plot.png", @"alt_text" : @"plot", @"image_bytes" : @20480,
                           @"title" : @{@"type" : @"plain_text", @"text" : @"Plot"}} ]},
        @{@"type" : @"message", @"ts" : @"1795400000.000400", @"user" : @"U02KIM", @"text" : @"<https://northwind.example/launch>",
          @"attachments" : @[ @{@"id" : @1, @"title" : @"Launch", @"title_link" : @"https://northwind.example/launch", @"image_url" : @"https://northwind.example/og.png",
                                @"image_width" : @1200, @"image_height" : @630} ]},
        @{@"type" : @"message", @"ts" : @"1795400000.000300", @"user" : @"U03SAM", @"text" : @"the chart", @"files" : @[ picture ]}
    ];
    @autoreleasepool {
        SNStore *store = Store(api, [SNDatabase databaseAtURL:url]);
        [store applyNewestHistory:@{@"messages" : history, @"has_more" : @NO} inConversation:@"C01DESIGN"];
        SNSlashCommands *commands = [[SNSlashCommands alloc] initWithSource:store];
        Run(commands, @"/collapse", @[], @"C01DESIGN", nil, nil);
        SNExpect([[store expandedStateOfItem:@"inline_files_msg_1795400000_000300F01CHARTChannel"] isEqual:@NO] &&
                     [[store expandedStateOfItem:@"img_msg_1795400000.0004001Channel"] isEqual:@NO] &&
                     [[store expandedStateOfItem:@"block_image_1795400000.000500_chart"] isEqual:@NO],
                 "/collapse keys every item as Slack's client does (files, link previews, Block Kit pictures)");
        SNMessage *last = [store messagesInConversation:@"C01DESIGN"].lastObject;
        SNExpect(last.isEphemeral && [last.text isEqualToString:@"I’ve collapsed all files in this channel for you."] &&
                     [SNJSONString(last.json, @"_ephemeral_type") isEqualToString:@"slash_cmd_feedback"],
                 "and Slackbot says so, to stay");
        SNRenderer *renderer = [[SNRenderer alloc] initWithSource:store];
        SNMessage *files = nil, *preview = nil, *block = nil;
        for (SNMessage *message in [store messagesInConversation:@"C01DESIGN"]) {
            if ([message.ts isEqualToString:@"1795400000.000300"]) files = message;
            if ([message.ts isEqualToString:@"1795400000.000400"]) preview = message;
            if ([message.ts isEqualToString:@"1795400000.000500"]) block = message;
        }
        SNMessageLayout *layout = [SNMessageLayout layoutForMessage:files continuation:NO style:SNMessageRowInConversation width:800 renderer:renderer];
        SNExpect(layout.files.count == 1 && layout.files[0].style == SNFileStyleCollapsed && [layout.files[0].metaTitle isEqualToString:@"chart.png"] &&
                     layout.files[0].frame.size.height == 22,
                 "collapsed files leave their name line with the caret");
        SNMessageLayout *thread = [SNMessageLayout layoutForMessage:files continuation:NO style:SNMessageRowThreadReply width:800 renderer:renderer];
        SNExpect(thread.files.count == 1 && thread.files[0].style == SNFileStyleImage, "the thread column keeps its own choice");
        BOOL (^hasImage)(SNMessage *) = ^BOOL(SNMessage *message) {
            for (SNRenderBlock *part in [renderer documentForMessage:message].blocks) {
                if ([part isKindOfClass:SNImageBlock.class]) return YES;
                if ([part isKindOfClass:SNGroupBlock.class])
                    for (SNRenderBlock *inner in ((SNGroupBlock *)part).blocks)
                        if ([inner isKindOfClass:SNImageBlock.class]) return YES;
            }
            return NO;
        };
        SNExpect(!hasImage(preview) && !hasImage(block), "link previews and Block Kit pictures lose their picture");
        SNRenderLayout *body = [[renderer documentForMessage:block] layoutForWidth:600];
        SNRenderTarget *caret = [SNRenderTarget targetWithKind:SNRenderTargetExpand value:@"block_image_1795400000.000500_chart"];
        SNExpect(!NSIsEmptyRect([body rectForTarget:caret]), "a Block Kit picture's title keeps the caret that expands it");

        Run(commands, @"/collapse", @[], @"C01DESIGN", @"1795400000.000300", nil);
        SNExpect([[store expandedStateOfItem:@"inline_files_msg_1795400000_000300F01CHARTThread"] isEqual:@NO], "in a thread, the thread's column");
        [store setItems:@[ @"inline_files_msg_1795400000_000300F01CHARTChannel" ] expanded:YES inMessages:@[ files ]];
        layout = [SNMessageLayout layoutForMessage:files continuation:NO style:SNMessageRowInConversation width:800 renderer:renderer];
        SNExpect(layout.files[0].style == SNFileStyleImage && layout.files[0].togglesFiles, "the caret expands them again");
    }
    SNStore *again = Store(api, [SNDatabase databaseAtURL:url]);
    SNExpect([[again expandedStateOfItem:@"img_msg_1795400000.0004001Channel"] isEqual:@NO] &&
                 [[again expandedStateOfItem:@"inline_files_msg_1795400000_000300F01CHARTChannel"] isEqual:@YES],
             "the choices stay on this device, as Slack's expandables store keeps them");
    [again applyNewestHistory:@{@"messages" : history, @"has_more" : @NO} inConversation:@"C01DESIGN"];
    SNSlashCommands *commands = [[SNSlashCommands alloc] initWithSource:again];
    Run(commands, @"/expand", @[], @"C01DESIGN", nil, nil);
    SNExpect([[again expandedStateOfItem:@"img_msg_1795400000.0004001Channel"] isEqual:@YES] &&
                 [[again messagesInConversation:@"C01DESIGN"].lastObject.text isEqualToString:@"I’ve expanded all files in this channel for you."],
             "/expand undoes it");
    SNMessage *preview = nil;
    for (SNMessage *message in [again messagesInConversation:@"C01DESIGN"])
        if ([message.ts isEqualToString:@"1795400000.000400"]) preview = message;
    SNRenderLayout *body = [[[[SNRenderer alloc] initWithSource:again] documentForMessage:preview] layoutForWidth:600];
    NSRect pictureRect = [body rectForTarget:[SNRenderTarget targetWithKind:SNRenderTargetImage value:@"https://northwind.example/og.png"]];
    SNRenderTarget *target = [body targetAtPoint:NSMakePoint(NSMidX(pictureRect), NSMidY(pictureRect))];
    SNExpect([target.detail isEqualToString:@"img_msg_1795400000.0004001Channel"], "a link preview's picture can be hidden from its More actions");
    SNExpect(api.calls.count == 0, "nothing of it is sent to Slack");
}

SN_TEST(SlashOpenAloneShowsTheChannelBrowser) {
    SNSetLanguage(@"en");
    SNTestAPI *api = [SNTestAPI new];
    api.answer = ^NSDictionary *(NSString *method, NSDictionary *params) {
        if ([method isEqualToString:@"search.modules.channels"])
            return @{@"ok" : @YES,
                     @"items" : @[
                         @{@"id" : @"C07LOBBY", @"name" : @"lobby", @"purpose" : @{@"value" : @"Say hello"}, @"member_count" : @12, @"is_member" : @NO, @"is_archived" : @NO},
                         @{@"id" : @"C01DESIGN", @"name" : @"design", @"purpose" : @{@"value" : @""}, @"member_count" : @6, @"is_member" : @YES}
                     ],
                     @"pagination" : @{@"page" : @1, @"page_count" : @3, @"total_count" : @120}};
        if ([method isEqualToString:@"conversations.join"]) return @{@"ok" : @YES, @"channel" : @{@"id" : params[@"channel"], @"name" : @"lobby", @"is_channel" : @YES}};
        return @{@"ok" : @YES};
    };
    SNStore *store = Store(api, nil);
    SNSlashCommands *commands = [[SNSlashCommands alloc] initWithSource:store];
    SNLocalTestNavigator *navigator = [SNLocalTestNavigator new];
    commands.navigator = navigator;
    Run(commands, @"/join", @[], @"C01DESIGN", nil, nil);
    SNExpect([navigator.location.page isEqualToString:SNPageChannels] && navigator.location.tab == SNTabHome && !navigator.location.conversationID,
             "/open alone opens the Channels page, on Home");

    SNChannelBrowserView *browser = [[SNChannelBrowserView alloc] initWithSource:store navigator:navigator];
    browser.frame = NSMakeRect(0, 0, 900, 700);
    [browser reload];
    SNWaitUntil(2, ^BOOL { return browser.channels.count == 2; });
    NSDictionary *list = LastCall(api, @"search.modules.channels");
    SNExpect([list[@"module"] isEqualToString:@"channels"] && [list[@"sort"] isEqualToString:@"recommended"] && [list[@"recommend_source"] isEqualToString:@"channel-browser"] &&
                 [list[@"browse"] isEqualToString:@"standard"] && [list[@"channel_type"] isEqualToString:@"exclude_archived"] && [list[@"count"] isEqualToString:@"50"] &&
                 [list[@"search_context"] isEqualToString:@"desktop_channel_browser"] && [list[@"_x_reason"] isEqualToString:@"fetch-current-browser"] &&
                 [list[@"team"] isEqualToString:@"T0NORTHWND"] && !list[@"sort_dir"],
             "search.modules.channels as Slack's browser asks, recommendations first");
    SNExpect(browser.pageCount == 3 && browser.channels[0].memberCount == 12 && [browser.channels[0].purpose isEqualToString:@"Say hello"] && !browser.channels[0].isMember,
             "rows from the list's items and its pages");
    [browser search:@"lob"];
    SNWaitUntil(2, ^BOOL { return [LastCall(api, @"search.modules.channels")[@"query"] isEqualToString:@"lob"]; });
    list = LastCall(api, @"search.modules.channels");
    SNExpect([list[@"sort"] isEqualToString:@"relevant"] && [list[@"sort_dir"] isEqualToString:@"desc"] && [list[@"highlight"] isEqualToString:@"1"],
             "a search sorts by relevance and highlights");
    SNWaitUntil(2, ^BOOL { return browser.channels.count == 2; });
    [browser sortBy:@"name" ascending:YES];
    SNWaitUntil(2, ^BOOL { return [LastCall(api, @"search.modules.channels")[@"sort_dir"] isEqualToString:@"asc"]; });
    SNExpect([LastCall(api, @"search.modules.channels")[@"sort"] isEqualToString:@"name"], "A to Z");
    SNWaitUntil(2, ^BOOL { return browser.channels.count == 2; });
    [browser toggleMembershipOfChannelAtIndex:0];
    NSDictionary *join = LastCall(api, @"conversations.join");
    SNExpect([join[@"channel"] isEqualToString:@"C07LOBBY"] && [join[@"request_in_background"] isEqualToString:@"true"] && [join[@"_x_reason"] isEqualToString:@"browse-channels-page"],
             "Join stays on the list");
    [browser toggleMembershipOfChannelAtIndex:1];
    SNExpect([LastCall(api, @"conversations.leave")[@"channel"] isEqualToString:@"C01DESIGN"], "Leave for a channel the user is in");
    [browser openChannelAtIndex:0];
    SNExpect([navigator.moves.lastObject isEqualToString:@"C07LOBBY"], "a click opens the channel");
}

SN_TEST(SlashInviteInADirectMessageMakesAGroupDM) {
    SNSetLanguage(@"en");
    SNTestAPI *api = [SNTestAPI new];
    api.answer = ^NSDictionary *(NSString *method, NSDictionary *params) {
        if ([method isEqualToString:@"conversations.createChild"])
            return @{@"ok" : @YES, @"channel" : @{@"id" : @"G09TRIO", @"name" : @"mpdm-alex--kim--sam-1", @"is_mpim" : @YES, @"is_open" : @YES}};
        return @{@"ok" : @YES};
    };
    SNStore *store = Store(api, nil);
    SNSlashCommands *commands = [[SNSlashCommands alloc] initWithSource:store];
    SNLocalTestNavigator *navigator = [SNLocalTestNavigator new];
    commands.navigator = navigator;
    NSWindow *window = Window();
    Run(commands, @"/invite", @[ @{@"user" : @"U03SAM"}, @" ", @{@"user" : @"U02KIM"} ], @"D05KIM", nil, window);
    SNAddPeopleDialog *add = SNAddPeopleDialog.current;
    SNExpect(add && [add.picker.userIDs isEqualToArray:@[ @"U03SAM" ]] && !LastCall(api, @"conversations.invite"),
             "a DM's /invite opens Add people with the mentioned who are not in it yet");
    [add.picker typeQuery:@"ki"];
    SNExpect(add.picker.suggestionTitles.count == 1 && [add.picker.suggestionTitles[0] isEqualToString:@"Kim"], "the picker finds people (Kim, already in, says so)");
    [add.picker chooseSuggestionAtIndex:0];
    SNExpect(add.picker.userIDs.count == 1, "someone already in cannot be chosen");
    [add confirm];
    SNExpect(add.history == SNGroupHistoryToday, "Next asks about history, from today by default");
    [add confirm];
    NSDictionary *child = LastCall(api, @"conversations.createChild");
    NSString *today = @((long long)[NSCalendar.currentCalendar startOfDayForDate:NSDate.date].timeIntervalSince1970).stringValue;
    SNExpect([child[@"channel"] isEqualToString:@"D05KIM"] && [child[@"user_ids"] isEqualToString:@"U03SAM"] && [child[@"migrate_history_start_ts"] isEqualToString:today] &&
                 !child[@"migrate_history_end_ts"] && [child[@"_x_reason"] isEqualToString:@"add-to-mpdm"],
             "conversations.createChild with the new people and today's history");
    SNWaitUntil(2, ^BOOL { return [navigator.moves.lastObject isEqualToString:@"G09TRIO"]; });
    SNExpect([navigator.moves.lastObject isEqualToString:@"G09TRIO"] && [store conversationWithID:@"G09TRIO"] && !SNConfirmDialog.current, "the new group DM opens");

    Run(commands, @"/invite", @[ @{@"user" : @"U03SAM"} ], @"D05KIM", nil, window);
    add = SNAddPeopleDialog.current;
    [add confirm];
    add.history = SNGroupHistoryAll;
    [add confirm];
    NSUInteger calls = api.calls.count;
    SNExpect(SNConfirmDialog.current && LastCall(api, @"conversations.createChild") == child, "from the beginning asks once more");
    [add confirm];
    SNExpect(api.calls.count == calls + 1 && [LastCall(api, @"conversations.createChild")[@"migrate_history_start_ts"] isEqualToString:@"0000000000.000001"], "and sends all of it");

    [store applyNewestHistory:@{@"messages" : @[], @"has_more" : @NO} inConversation:@"D06SELF"];
    Run(commands, @"/invite", @[ @{@"user" : @"U03SAM"} ], @"D06SELF", nil, window);
    SNMessage *answer = [store messagesInConversation:@"D06SELF"].lastObject;
    SNExpect(answer.isEphemeral && [answer.text isEqualToString:@"Sorry, you can’t perform this action."], "not in one's own DM");
    SNExpect([SNListOfNames(@[ @"Ana", @"Bia" ]) isEqualToString:@"Ana and Bia"] && [SNListOfNames(@[ @"Ana", @"Bia", @"Cris" ]) isEqualToString:@"Ana, Bia, and Cris"] &&
                 [SNListOfNames(@[ @"Ana", @"Bia", @"Cris", @"Dan" ]) isEqualToString:@"Ana, Bia, and 2 others"],
             "names listed as Slack lists them");
}

SN_TEST(SlashInviteInAPrivateChannelGoesThroughSlacksDialog) {
    SNSetLanguage(@"en");
    SNTestAPI *api = [SNTestAPI new];
    __block NSDictionary *answer = @{@"ok" : @YES, @"channel" : @{@"id" : @"G03SECRET"}};
    api.answer = ^NSDictionary *(NSString *method, NSDictionary *params) { return answer; };
    SNStore *store = Store(api, nil);
    SNSlashCommands *commands = [[SNSlashCommands alloc] initWithSource:store];
    NSWindow *window = Window();
    Run(commands, @"/invite", @[ @{@"user" : @"U03SAM"} ], @"G03SECRET", nil, window);
    SNAddPeopleDialog *add = SNAddPeopleDialog.current;
    SNExpect(add && !LastCall(api, @"conversations.invite"), "a private channel's /invite warns first, inviting nobody yet");
    [add confirm];
    SNExpect([add.picker.userIDs isEqualToArray:@[ @"U03SAM" ]], "then Add people, with the person in it");
    [add.picker typeQuery:@"ki"];
    [add.picker chooseSuggestionAtIndex:0];
    answer = @{@"ok" : @YES, @"channel" : @{@"id" : @"G03SECRET"}, @"errors" : @[ @{@"user" : @"U02KIM", @"error" : @"cant_invite", @"ok" : @NO} ]};
    [add confirm];
    NSDictionary *invite = LastCall(api, @"conversations.invite");
    SNExpect([invite[@"channel"] isEqualToString:@"G03SECRET"] && [invite[@"users"] isEqualToString:@"U03SAM,U02KIM"] && [invite[@"force"] isEqualToString:@"true"] &&
                 [invite[@"subteams"] isEqualToString:@""] && [invite[@"invite_all"] isEqualToString:@"false"] &&
                 [invite[@"_x_reason"] isEqualToString:@"submit-invite-channel-invite-modal"],
             "Add invites everyone at once, with force");
    SNWaitUntil(2, ^BOOL { return add.dialog.errorText != nil; });
    SNExpect([add.picker.userIDs isEqualToArray:@[ @"U02KIM" ]] && [add.dialog.errorText hasPrefix:@"This person can’t be added to the channel"] && SNConfirmDialog.current,
             "who Slack refused stays, with why");
    answer = @{@"ok" : @YES, @"channel" : @{@"id" : @"G03SECRET"}, @"errors" : @[ @{@"user" : @"U02KIM", @"error" : @"already_in_channel", @"ok" : @NO} ]};
    [add confirm];
    SNWaitUntil(2, ^BOOL { return !SNConfirmDialog.current; });
    SNExpect(!SNConfirmDialog.current, "someone already in counts as added, and it closes");

    Run(commands, @"/invite", @[ @{@"user" : @"U03SAM"} ], @"C01DESIGN", nil, window);
    SNExpect([LastCall(api, @"conversations.invite")[@"_x_reason"] isEqualToString:@"submit-invite-slash-command"] && !SNConfirmDialog.current, "a public channel still invites at once");
}

SN_TEST(SlashShortcutsFeedbackGifAndInvitePeopleOpenSlacksViews) {
    SNSetLanguage(@"en");
    SNTestAPI *api = [SNTestAPI new];
    api.answer = ^NSDictionary *(NSString *method, NSDictionary *params) {
        if ([method isEqualToString:@"gif.search"] || [method isEqualToString:@"gif.featured"])
            return @{@"ok" : @YES, @"gifs" : @[ @{@"id" : @"1234", @"content_description" : @"Cat typing",
                                                  @"media_formats" : @{@"tinygif" : @{@"url" : @"https://media.example.com/cat-tiny.gif", @"dims" : @[ @220, @124 ], @"size" : @50000},
                                                                       @"gif" : @{@"url" : @"https://media.example.com/cat.gif", @"dims" : @[ @498, @280 ], @"size" : @900000}}} ]};
        if ([method isEqualToString:@"users.admin.inviteBulk"])
            return @{@"ok" : @YES, @"invites" : @[ @{@"email" : @"ana@acme.example", @"ok" : @YES}, @{@"email" : @"bia@acme.example", @"ok" : @NO, @"error" : @"already_in_team"} ]};
        return @{@"ok" : @YES};
    };
    SNStore *store = Store(api, nil);
    SNSlashCommands *commands = [[SNSlashCommands alloc] initWithSource:store];
    SNLocalTestNavigator *navigator = [SNLocalTestNavigator new];
    commands.navigator = navigator;
    NSWindow *window = Window();

    Run(commands, @"/shortcuts", @[], @"C01DESIGN", nil, nil);
    SNExpect([navigator.location.panel isEqualToString:SNPanelShortcuts] && [navigator.location.conversationID isEqualToString:@"C01DESIGN"], "/shortcuts opens the panel beside the conversation");
    Run(commands, @"/shortcuts", @[], @"C01DESIGN", nil, nil);
    SNExpect(!navigator.location.panel, "and closes it the next time");
    SNShortcutsPanel *shortcuts = (SNShortcutsPanel *)SNMakePanel(SNPanelShortcuts, store, ^{});
    SNExpect([shortcuts.sectionTitles.firstObject isEqualToString:@"Basics"] && [shortcuts.rowTexts containsObject:@"Jump to…: ⌘ K"] &&
                 [shortcuts.rowTexts containsObject:@"Format selection as code block: ⌥ ⇧ ⌘ C"],
             "Slack's sections and rows, the ones this app answers to");

    Run(commands, @"/feedback", @[ @"the sidebar flickers" ], @"C01DESIGN", nil, nil);
    SNExpect([navigator.location.panel isEqualToString:SNPanelFeedback], "/feedback opens the Feedback panel");
    SNFeedbackPanel *feedback = (SNFeedbackPanel *)SNMakePanel(SNPanelFeedback, store, ^{});
    SNExpect([feedback.text isEqualToString:@"the sidebar flickers"], "with what followed the command");
    [feedback send];
    NSDictionary *submitted = LastCall(api, @"feedback.submitFeedback");
    SNExpect([submitted[@"custom_input"] isEqualToString:@"the sidebar flickers"] && [submitted[@"attachments"] isEqualToString:@"[]"] &&
                 [submitted[@"_x_reason"] isEqualToString:@"flexpane/feedback"],
             "feedback.submitFeedback");
    SNWaitUntil(2, ^BOOL { return feedback.sent; });
    SNExpect(feedback.sent, "then Slack's thanks");

    __block NSString *gifQuery = nil;
    commands.openGifPicker = ^(NSString *query) { gifQuery = query; };
    Run(commands, @"/gif", @[ @"cat typing" ], @"C01DESIGN", nil, nil);
    SNExpect([gifQuery isEqualToString:@"cat typing"], "/gif opens the picker on its words");
    __block NSArray *gifs = nil;
    [store searchGIFs:@"cat typing" reason:@"gif-picker:initial-search" completion:^(NSArray<NSDictionary *> *found, NSString *error) { gifs = found; }];
    SNWaitUntil(2, ^BOOL { return gifs != nil; });
    NSDictionary *search = LastCall(api, @"gif.search");
    SNExpect([search[@"query"] isEqualToString:@"cat typing"] && [search[@"limit"] isEqualToString:@"50"] && [search[@"_x_reason"] isEqualToString:@"gif-picker:initial-search"],
             "gif.search, 50 at a time");
    [store searchGIFs:@"" reason:@"gif-picker:search" completion:^(NSArray<NSDictionary *> *found, NSString *error) {}];
    SNExpect([LastCall(api, @"gif.featured")[@"_x_reason"] isEqualToString:@"gif-picker:featured"], "without words, the featured ones");
    NSDictionary *attachment = SNGifAttachment(gifs.firstObject);
    NSDictionary *image = attachment[@"blocks"][0];
    SNExpect([image[@"type"] isEqualToString:@"image"] && [image[@"image_url"] isEqualToString:@"https://media.example.com/cat.gif"] && [image[@"image_width"] isEqual:@498] &&
                 [image[@"image_bytes"] isEqual:@900000] && [image[@"is_animated"] isEqual:@YES] && [image[@"title"][@"text"] isEqualToString:@"GIF"] &&
                 [image[@"alt_text"] isEqualToString:@"Cat typing"],
             "a pick becomes Slack's image block titled GIF");
    [store sendText:@"" blocks:nil attachments:@[ attachment ] inConversation:@"C01DESIGN" threadTS:nil broadcast:NO];
    NSArray *posted = JSON(LastCall(api, @"chat.postMessage")[@"attachments"]);
    SNExpect([posted[0][@"blocks"][0][@"image_url"] isEqualToString:@"https://media.example.com/cat.gif"], "and goes with the message as chat.postMessage's attachments");

    Run(commands, @"/invite_people", @[ @"ana@acme.example, bia@acme.example" ], @"C01DESIGN", nil, window);
    SNInvitePeopleDialog *invite = SNInvitePeopleDialog.current;
    SNExpect([invite.emailText isEqualToString:@"ana@acme.example, bia@acme.example"], "/invite_people opens the invite dialog with the addresses");
    [invite send];
    NSDictionary *bulk = LastCall(api, @"users.admin.inviteBulk");
    NSArray *invites = JSON(bulk[@"invites"]);
    SNExpect(invites.count == 2 && [invites[0][@"email"] isEqualToString:@"ana@acme.example"] && [invites[0][@"mode"] isEqualToString:@"manual"] &&
                 [invites[0][@"type"] isEqualToString:@"regular"] && !invites[0][@"invite_source"] && [bulk[@"team_id"] isEqualToString:@"T0NORTHWND"] &&
                 [bulk[@"restricted"] isEqualToString:@"false"] && [bulk[@"campaign"] isEqualToString:@"invite_people_slash_command"] &&
                 [bulk[@"_x_reason"] isEqualToString:@"submit-invite-to-workspace-invites"],
             "users.admin.inviteBulk as members");
    SNWaitUntil(2, ^BOOL { return !SNConfirmDialog.current.waiting; });
    SNExpect(SNConfirmDialog.current && SNConfirmDialog.current.confirmEnabled, "the summary shows, with Done");
    [invite send];
    SNExpect(!SNConfirmDialog.current, "Done closes it");
    SNExpect(SNInviteEmails(@"a@x.example,b@y.example  c@z.example").count == 3, "addresses split at commas and spaces");
    [store applyReplies:@{@"messages" : @[ @{@"type" : @"message", @"ts" : @"1795400000.000100", @"thread_ts" : @"1795400000.000100", @"user" : @"U02KIM", @"text" : @"hi"} ]}
                 thread:@"1795400000.000100"
         inConversation:@"C01DESIGN"];
    Run(commands, @"/invite_people", @[], @"C01DESIGN", @"1795400000.000100", window);
    SNExpect([[store threadInConversation:@"C01DESIGN" ts:@"1795400000.000100"].lastObject.text isEqualToString:@"*/invite_people* is not supported in threads. Sorry!"],
             "not from a thread");
}
