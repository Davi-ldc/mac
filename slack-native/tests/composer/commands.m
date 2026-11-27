// The slash commands Slack's client runs itself, in the shapes its static JS sends and reads
// (values made up): each command's request, its confirmation dialog, and the answers only the user
// sees when Slack refuses or the command cannot run.
#import "../net/stub.h"
#import "model/json.h"
#import "render/strings.h"
#import "store/store.h"
#import "test.h"
#import "ui/composer/commands.h"
#import "ui/composer/richtext.h"
#import "ui/kit/dialog.h"

/// Records where commands send the window.
@interface SNCommandTestNavigator : NSObject <SNNavigator>
@property (nonatomic) SNLocation *location;
@property (nonatomic) NSMutableArray<NSString *> *moves;
@end

@implementation SNCommandTestNavigator
- (instancetype)init {
    if (!(self = [super init])) return nil;
    _location = [SNLocation locationWithTab:SNTabHome conversation:@"C01DESIGN" thread:nil];
    _moves = [NSMutableArray new];
    return self;
}
- (void)go:(SNLocation *)location { self.location = location; }
- (void)openConversation:(NSString *)conversationID { [self.moves addObject:conversationID]; }
- (void)openThread:(NSString *)threadTS inConversation:(NSString *)conversationID {}
- (void)closeThread {}
- (void)selectTab:(SNTab)tab { [self.moves addObject:[NSString stringWithFormat:@"tab %ld", (long)tab]]; }
- (void)openSearchWithQuery:(NSString *)query { [self.moves addObject:[@"search " stringByAppendingString:query ?: @""]]; }
- (void)resetSidebarFilter {}
@end

static SNStore *Store(SNTestAPI *api) {
    SNStore *store = [[SNStore alloc] initWithDatabase:nil api:api];
    [store performChanges:^{
        [store applyWorkspace:@{@"id" : @"T0NORTHWND", @"name" : @"Northwind Studio", @"domain" : @"northwind-studio"}];
        [store applySelfUserID:@"U01ALEX"];
        [store applyUsers:@[
            @{@"id" : @"U01ALEX", @"name" : @"alex", @"profile" : @{@"display_name" : @"Alex"}},
            @{@"id" : @"U02KIM", @"name" : @"kim", @"profile" : @{@"display_name" : @"Kim"}},
            @{@"id" : @"U03SAM", @"name" : @"sam", @"profile" : @{@"display_name" : @"Sam"}},
            @{@"id" : @"USLACKBOT", @"name" : @"slackbot", @"is_bot" : @YES}
        ]];
        [store applyConversations:@[
            @{@"id" : @"C01DESIGN", @"name" : @"design", @"is_channel" : @YES, @"is_member" : @YES, @"num_members" : @6},
            @{@"id" : @"C02ALL", @"name" : @"general", @"is_channel" : @YES, @"is_member" : @YES, @"is_general" : @YES},
            @{@"id" : @"G03SECRET", @"name" : @"secret-plans", @"is_group" : @YES, @"is_private" : @YES, @"is_member" : @YES, @"num_members" : @4},
            @{@"id" : @"C04LOBBY", @"name" : @"lobby", @"is_channel" : @YES, @"is_member" : @NO},
            @{@"id" : @"D05KIM", @"is_im" : @YES, @"user" : @"U02KIM", @"is_open" : @YES}
        ]];
    }];
    [store applyNewestHistory:@{@"messages" : @[
        @{@"type" : @"message", @"ts" : @"1795400000.000200", @"user" : @"U01ALEX", @"text" : @"the colour is grey, the grey one"},
        @{@"type" : @"message", @"ts" : @"1795400000.000100", @"user" : @"U02KIM", @"text" : @"which colour?"}
    ],
                                @"has_more" : @NO}
               inConversation:@"C01DESIGN"];
    return store;
}

/// The rest of a command: strings as typed and @{kind: value} mentions as picked from the list.
static NSAttributedString *Rest(NSArray *parts) {
    NSMutableAttributedString *rest = [NSMutableAttributedString new];
    for (id part in parts) {
        if ([part isKindOfClass:NSString.class]) {
            [rest appendAttributedString:[[NSAttributedString alloc] initWithString:part]];
            continue;
        }
        NSString *value = [part allValues].firstObject;
        SNRichEntityKind kind = [[part allKeys].firstObject integerValue];
        SNRichEntity *entity = [SNRichEntity entityWithKind:kind value:value];
        [rest appendAttributedString:[[NSAttributedString alloc] initWithString:[@"@" stringByAppendingString:value] attributes:@{SNRichEntityAttribute : entity}]];
    }
    return rest;
}

static NSDictionary *User(NSString *userID) { return @{@(SNRichEntityUser) : userID}; }
static NSDictionary *Channel(NSString *channelID) { return @{@(SNRichEntityChannel) : channelID}; }

static NSDictionary *LastCall(SNTestAPI *api, NSString *method) {
    for (NSArray *call in api.calls.reverseObjectEnumerator)
        if ([call[0] isEqualToString:method]) return call[1];
    return nil;
}

static NSWindow *Window(void) {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 900, 700) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:YES];
    window.releasedWhenClosed = NO;
    return window;
}

/// Runs `typed` with `rest` in #design (or `conversationID`) and returns the answer shown, if any.
static void Run(SNSlashCommands *commands, NSString *typed, NSArray *rest, NSString *conversationID, NSString *threadTS, NSWindow *window) {
    [commands run:typed rest:Rest(rest) inConversation:conversationID threadTS:threadTS window:window restore:^{}];
}

static NSString *Answer(SNStore *store, NSString *conversationID) {
    SNMessage *last = [store messagesInConversation:conversationID].lastObject;
    return last.isEphemeral ? last.text : nil;
}

SN_TEST(SlashCommandsParseMentionsAndWordsAsSlacksClient) {
    NSArray *params = SNSlashCommandParams(Rest(@[ User(@"U02KIM"), @"  to   ", Channel(@"C01DESIGN"), @" now" ]));
    SNExpect(params.count == 4 && [params[0][@"type"] isEqualToString:@"mention"] && [params[0][@"value"] isEqualToString:@"U02KIM"] &&
                 [params[1][@"value"] isEqualToString:@"to"] && [params[2][@"value"] isEqualToString:@"C01DESIGN"] && [params[3][@"type"] isEqualToString:@"string"],
             "mentions picked from the list are mentions; the text between splits on white space");
    SNExpect([SNSlashCommandParams(Rest(@[ @"@kim hi" ]))[0][@"type"] isEqualToString:@"string"], "a name typed without picking it stays a word");
    NSString *missing = nil;
    NSAttributedString *unresolved = [[NSAttributedString alloc] initWithString:@"@kim hi"
                                                                     attributes:@{SNRichEntityAttribute : [SNRichEntity entityWithKind:SNRichEntityUser value:missing]}];
    SNExpect([SNSlashCommandParams(unresolved).firstObject[@"type"] isEqualToString:@"string"], "a mention without an ID is a word, not a crash");
}

SN_TEST(SlashLeaveLeavesClosesAndConfirmsAsSlack) {
    SNSetLanguage(@"en");
    SNTestAPI *api = [SNTestAPI new];
    SNStore *store = Store(api);
    SNSlashCommands *commands = [[SNSlashCommands alloc] initWithSource:store];
    NSWindow *window = Window();

    Run(commands, @"/leave", @[], @"C01DESIGN", nil, window);
    SNExpect(![store conversationWithID:@"C01DESIGN"].isMember && [LastCall(api, @"conversations.leave")[@"channel"] isEqualToString:@"C01DESIGN"] &&
                 !SNConfirmDialog.current,
             "a public channel is left at once (conversations.leave), out of the sidebar before Slack answers");

    api.answer = ^NSDictionary *(NSString *method, NSDictionary *params) { return @{@"ok" : @NO, @"error" : @"internal_error"}; };
    [store applyConversations:@[ @{@"id" : @"C01DESIGN", @"name" : @"design", @"is_channel" : @YES, @"is_member" : @YES, @"num_members" : @6} ]];
    Run(commands, @"/Part", @[], @"C01DESIGN", nil, window);
    SNWaitUntil(2, ^BOOL { return SNConfirmDialog.current != nil; });
    SNExpect([store conversationWithID:@"C01DESIGN"].isMember, "refused, it comes back");
    SNExpect(SNConfirmDialog.current, "and Slack's dialog offers Retry");
    [SNConfirmDialog.current cancel];
    api.answer = nil;

    NSUInteger calls = api.calls.count;
    Run(commands, @"/leave", @[], @"G03SECRET", nil, window);
    SNExpect(SNConfirmDialog.current && api.calls.count == calls, "a private channel asks first");
    [SNConfirmDialog.current confirm];
    SNExpect([LastCall(api, @"conversations.leave")[@"channel"] isEqualToString:@"G03SECRET"], "and leaves once confirmed");

    calls = api.calls.count;
    Run(commands, @"/leave", @[], @"C02ALL", nil, window);
    SNExpect(SNConfirmDialog.current && api.calls.count == calls, "#general explains that membership is required, without asking Slack");
    [SNConfirmDialog.current cancel];

    Run(commands, @"/close", @[ User(@"U02KIM") ], @"C01DESIGN", nil, window);
    SNExpect([LastCall(api, @"conversations.close")[@"channel"] isEqualToString:@"D05KIM"] && ![store conversationWithID:@"D05KIM"].isOpen,
             "a person's DM closes (conversations.close)");

    [store applyNewestHistory:@{@"messages" : @[], @"has_more" : @NO} inConversation:@"C04LOBBY"];
    Run(commands, @"/leave", @[ @"lobby" ], @"C04LOBBY", nil, window);
    SNExpect([Answer(store, @"C04LOBBY") isEqualToString:@"A valid channel name is required."], "a typed name is not a channel");

    [store applyReplies:@{@"messages" : @[ @{@"type" : @"message", @"ts" : @"1795400000.000100", @"thread_ts" : @"1795400000.000100", @"user" : @"U02KIM", @"text" : @"which colour?"} ]}
                 thread:@"1795400000.000100"
         inConversation:@"C01DESIGN"];
    calls = api.calls.count;
    Run(commands, @"/leave", @[], @"C01DESIGN", @"1795400000.000100", window);
    SNExpect(api.calls.count == calls && [[store threadInConversation:@"C01DESIGN" ts:@"1795400000.000100"].lastObject.text isEqualToString:@"*/leave* is not supported in threads. Sorry!"],
             "not from a thread");
}

SN_TEST(SlashMsgOpensTheConversationAndSendsTheRest) {
    SNSetLanguage(@"en");
    SNTestAPI *api = [SNTestAPI new];
    api.answer = ^NSDictionary *(NSString *method, NSDictionary *params) {
        if ([method isEqualToString:@"conversations.open"]) return @{@"ok" : @YES, @"channel" : @{@"id" : @"D06SAM", @"is_im" : @YES, @"user" : @"U03SAM"}};
        if ([method isEqualToString:@"conversations.join"]) return @{@"ok" : @YES, @"channel" : @{@"id" : @"C04LOBBY", @"name" : @"lobby", @"is_channel" : @YES}};
        return @{@"ok" : @YES};
    };
    SNStore *store = Store(api);
    SNSlashCommands *commands = [[SNSlashCommands alloc] initWithSource:store];
    SNCommandTestNavigator *navigator = [SNCommandTestNavigator new];
    commands.navigator = navigator;

    Run(commands, @"/msg", @[ User(@"U03SAM"), @" lunch at noon?" ], @"C01DESIGN", nil, nil);
    SNWaitUntil(2, ^BOOL { return LastCall(api, @"chat.postMessage") != nil; });
    NSDictionary *open = LastCall(api, @"conversations.open"), *post = LastCall(api, @"chat.postMessage");
    SNExpect([open[@"users"] isEqualToString:@"U03SAM"] && [navigator.moves.lastObject isEqualToString:@"D06SAM"], "the person's DM opens (conversations.open)");
    SNExpect([post[@"channel"] isEqualToString:@"D06SAM"] && [post[@"text"] isEqualToString:@"lunch at noon?"], "and what follows the mention is sent there");

    Run(commands, @"/dm", @[ Channel(@"C04LOBBY"), @" hello" ], @"C01DESIGN", nil, nil);
    SNWaitUntil(2, ^BOOL { return [LastCall(api, @"chat.postMessage")[@"channel"] isEqualToString:@"C04LOBBY"]; });
    SNExpect([LastCall(api, @"conversations.join")[@"channel"] isEqualToString:@"C04LOBBY"] && [navigator.moves.lastObject isEqualToString:@"C04LOBBY"],
             "a channel the user is not in is joined first (conversations.join)");

    Run(commands, @"/msg", @[], @"C01DESIGN", nil, nil);
    NSString *dmsTab = [NSString stringWithFormat:@"tab %ld", (long)SNTabDirectMessages];
    SNExpect([navigator.moves.lastObject isEqualToString:dmsTab], "alone, it opens the DMs");
    Run(commands, @"/msg", @[ @"@kim hi" ], @"C01DESIGN", nil, nil);
    SNExpect([Answer(store, @"C01DESIGN") isEqualToString:@"A valid member name is required."], "a name not picked from the list is not a member");
}

SN_TEST(SlashTopicInviteAndColorSendSlacksRequests) {
    SNSetLanguage(@"en");
    SNTestAPI *api = [SNTestAPI new];
    __block NSString *refusal = nil;
    api.answer = ^NSDictionary *(NSString *method, NSDictionary *params) { return refusal ? @{@"ok" : @NO, @"error" : refusal} : @{@"ok" : @YES}; };
    SNStore *store = Store(api);
    SNSlashCommands *commands = [[SNSlashCommands alloc] initWithSource:store];
    SNCommandTestNavigator *navigator = [SNCommandTestNavigator new];
    commands.navigator = navigator;

    Run(commands, @"/topic", @[ @"Launch week, ask ", User(@"U02KIM") ], @"C01DESIGN", nil, nil);
    NSDictionary *topic = LastCall(api, @"conversations.setTopic");
    SNExpect([topic[@"channel"] isEqualToString:@"C01DESIGN"] && [topic[@"topic"] isEqualToString:@"Launch week, ask <@U02KIM>"] &&
                 [topic[@"_x_reason"] isEqualToString:@"submitChannelTopic"],
             "conversations.setTopic with mentions as <@U...>");
    refusal = @"method_not_supported_for_dm";
    Run(commands, @"/topic", @[ @"anything" ], @"C01DESIGN", nil, nil);
    SNWaitUntil(2, ^BOOL { return Answer(store, @"C01DESIGN") != nil; });
    SNExpect([Answer(store, @"C01DESIGN") isEqualToString:@"Regrettably, direct messages do not have topics."], "Slack's refusal in its words");
    refusal = nil;

    Run(commands, @"/invite", @[ User(@"U03SAM") ], @"C01DESIGN", nil, nil);
    NSDictionary *invite = LastCall(api, @"conversations.invite");
    SNExpect([invite[@"channel"] isEqualToString:@"C01DESIGN"] && [invite[@"users"] isEqualToString:@"U03SAM"] && [invite[@"invite_all"] isEqualToString:@"false"] &&
                 [invite[@"subteams"] isEqualToString:@""] && [invite[@"force"] isEqualToString:@"false"] &&
                 [invite[@"_x_reason"] isEqualToString:@"submit-invite-slash-command"],
             "conversations.invite as the client sends it");
    refusal = @"already_in_channel";
    Run(commands, @"/invite", @[ User(@"U03SAM"), @" ", Channel(@"C04LOBBY") ], @"C01DESIGN", nil, nil);
    SNExpect([LastCall(api, @"conversations.invite")[@"channel"] isEqualToString:@"C04LOBBY"], "a channel mention is where the invite goes");
    SNWaitUntil(2, ^BOOL { return Answer(store, @"C01DESIGN") != nil; });
    SNExpect([Answer(store, @"C01DESIGN") isEqualToString:@"Sam is already in this channel."], "already in, by name");
    refusal = nil;
    Run(commands, @"/invite", @[ User(@"U03SAM"), @" ", User(@"U02KIM") ], @"C01DESIGN", nil, nil);
    SNExpect([Answer(store, @"C01DESIGN") hasPrefix:@"*/invite* can only invite one user."], "one person at a time");

    Run(commands, @"/s", @[ @"quarterly plan" ], @"C01DESIGN", nil, nil);
    SNExpect([navigator.moves.lastObject isEqualToString:@"search quarterly plan"], "/s searches");
}

SN_TEST(SlashRemoveRenameAndArchiveAskInSlacksDialogs) {
    SNSetLanguage(@"en");
    SNTestAPI *api = [SNTestAPI new];
    __block NSString *refusal = nil;
    api.answer = ^NSDictionary *(NSString *method, NSDictionary *params) {
        if (refusal) return @{@"ok" : @NO, @"error" : refusal};
        if ([method isEqualToString:@"conversations.rename"]) return @{@"ok" : @YES, @"channel" : @{@"id" : @"C01DESIGN", @"name" : params[@"name"]}};
        return @{@"ok" : @YES};
    };
    SNStore *store = Store(api);
    SNSlashCommands *commands = [[SNSlashCommands alloc] initWithSource:store];
    NSWindow *window = Window();

    refusal = @"not_in_channel";
    Run(commands, @"/kick", @[ User(@"U03SAM") ], @"C01DESIGN", nil, window);
    SNConfirmDialog *dialog = SNConfirmDialog.current;
    SNExpect(dialog && !LastCall(api, @"conversations.kick"), "removing someone asks first");
    [dialog confirm];
    NSDictionary *kick = LastCall(api, @"conversations.kick");
    SNExpect([kick[@"channel"] isEqualToString:@"C01DESIGN"] && [kick[@"user"] isEqualToString:@"U03SAM"] && [kick[@"_x_reason"] isEqualToString:@"submitKickFromChannel"],
             "conversations.kick once confirmed");
    SNWaitUntil(2, ^BOOL { return dialog.errorText != nil; });
    SNExpect(SNConfirmDialog.current == dialog && [dialog.errorText isEqualToString:@"Sam is not a member of #design."] && !dialog.confirmEnabled,
             "a refusal shows in the dialog, which stays");
    [dialog cancel];
    refusal = nil;

    Run(commands, @"/rename", @[ @"design-crit" ], @"C01DESIGN", nil, window);
    dialog = SNConfirmDialog.current;
    SNExpect(dialog.confirmEnabled, "a new name can be saved");
    [dialog confirm];
    NSDictionary *rename = LastCall(api, @"conversations.rename");
    SNExpect([rename[@"name"] isEqualToString:@"design-crit"] && [rename[@"validate"] isEqualToString:@"true"], "conversations.rename with validate");
    SNWaitUntil(2, ^BOOL { return !SNConfirmDialog.current; });
    SNExpect([[store conversationWithID:@"C01DESIGN"].name isEqualToString:@"design-crit"] && !SNConfirmDialog.current, "renamed, the dialog closes");
    Run(commands, @"/rename", @[], @"C01DESIGN", nil, window);
    SNExpect(!SNConfirmDialog.current.confirmEnabled, "the same name cannot be saved");
    [SNConfirmDialog.current cancel];
    Run(commands, @"/rename", @[], @"D05KIM", nil, window);
    SNExpect(!SNConfirmDialog.current, "a DM has no name to change");

    Run(commands, @"/archive", @[], @"C01DESIGN", nil, window);
    [SNConfirmDialog.current confirm];
    SNExpect([LastCall(api, @"conversations.archive")[@"channel"] isEqualToString:@"C01DESIGN"], "conversations.archive once confirmed");
    SNWaitUntil(2, ^BOOL { return [store conversationWithID:@"C01DESIGN"].isArchived; });
    NSUInteger calls = api.calls.count;
    [store applyNewestHistory:@{@"messages" : @[], @"has_more" : @NO} inConversation:@"C02ALL"];
    Run(commands, @"/archive", @[], @"C02ALL", nil, window);
    SNExpect(api.calls.count == calls && [Answer(store, @"C02ALL") hasPrefix:@"*/archive* is not a valid command."], "#general cannot be archived");
}

SN_TEST(SlashCommandsLeaveTheRestToSlack) {
    SNSetLanguage(@"en");
    SNTestAPI *api = [SNTestAPI new];
    SNStore *store = Store(api);
    SNSlashCommands *commands = [[SNSlashCommands alloc] initWithSource:store];

    Run(commands, @"/s/grey/gray/g", @[], @"C01DESIGN", nil, nil);
    NSDictionary *update = LastCall(api, @"chat.update");
    SNExpect([update[@"ts"] isEqualToString:@"1795400000.000200"] && [update[@"text"] isEqualToString:@"the colour is gray, the gray one"],
             "s/old/new/g edits the user's last message (chat.update)");
    Run(commands, @"/remind", @[ @"me to stretch in 5 minutes" ], @"C01DESIGN", nil, nil);
    SNExpect([LastCall(api, @"chat.command")[@"command"] isEqualToString:@"/remind"], "a server command goes to chat.command");
    NSUInteger calls = api.calls.count;
    SNCommandTestNavigator *navigator = [SNCommandTestNavigator new];
    commands.navigator = navigator;
    Run(commands, @"/keys", @[], @"C01DESIGN", nil, nil);
    SNExpect(api.calls.count == calls && [navigator.location.panel isEqualToString:SNPanelShortcuts], "the client's own commands run here, unsent");
}
