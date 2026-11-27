// Slash commands in the shapes the web client's static JS reads and sends (values made up): the
// list from client.appCommands, chat.command's request, its answer and errors shown as messages
// only the user sees, and ephemeral messages from the websocket, never stored.
#import "../net/stub.h"
#import "model/json.h"
#import "render/strings.h"
#import "store/database.h"
#import "store/store.h"
#import "test.h"

static NSDictionary *CommandList(void) {
    NSData *data = [NSData dataWithContentsOfURL:[SNPublicFixture() URLByAppendingPathComponent:@"client.appCommands.json"]];
    return [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
}

static SNStore *CommandStore(SNDatabase *database, SNTestAPI *api) {
    SNStore *store = [[SNStore alloc] initWithDatabase:database api:api];
    [store performChanges:^{
        [store applyWorkspace:@{@"id" : @"T0NORTHWND", @"name" : @"Northwind Studio", @"domain" : @"northwind-studio"}];
        [store applySelfUserID:@"U01ALEX"];
        [store applyUsers:@[ @{@"id" : @"U01ALEX", @"name" : @"alex"}, @{@"id" : @"USLACKBOT", @"name" : @"slackbot", @"is_bot" : @YES} ]];
        [store applyConversations:@[
            @{@"id" : @"C01GENERAL", @"name" : @"design", @"is_channel" : @YES, @"is_member" : @YES},
            @{@"id" : @"C01ALL", @"name" : @"general", @"is_channel" : @YES, @"is_member" : @YES, @"is_general" : @YES},
            @{@"id" : @"D01KIM", @"is_im" : @YES, @"user" : @"U01KIM", @"is_open" : @YES}
        ]];
    }];
    [store applyNewestHistory:@{@"messages" : @[ @{@"type" : @"message", @"ts" : @"1795400000.000100", @"user" : @"U01ALEX", @"text" : @"parent"} ], @"has_more" : @NO}
               inConversation:@"C01GENERAL"];
    [store applyReplies:@{@"messages" : @[ @{@"type" : @"message", @"ts" : @"1795400000.000100", @"thread_ts" : @"1795400000.000100", @"user" : @"U01ALEX", @"text" : @"parent"} ]}
                 thread:@"1795400000.000100"
         inConversation:@"C01GENERAL"];
    return store;
}

static NSArray *Blocks(NSString *text) {
    return @[ @{@"type" : @"rich_text", @"elements" : @[ @{@"type" : @"rich_text_section", @"elements" : @[ @{@"type" : @"text", @"text" : text} ]} ]} ];
}

static NSDictionary *LastCall(SNTestAPI *api, NSString *method) {
    for (NSArray *call in api.calls.reverseObjectEnumerator)
        if ([call[0] isEqualToString:method]) return call[1];
    return nil;
}

static NSArray<NSString *> *Listed(SNStore *store, NSString *query, NSString *conversationID, NSString *threadTS) {
    return [[store commandsMatching:query inConversation:conversationID threadTS:threadTS limit:50] valueForKey:@"name"];
}

SN_TEST(StoreListsSlashCommandsFromClientAppCommands) {
    SNTestAPI *api = [SNTestAPI new];
    api.answer = ^NSDictionary *(NSString *method, NSDictionary *params) { return [method isEqualToString:@"client.appCommands"] ? CommandList() : @{@"ok" : @YES}; };
    SNStore *store = CommandStore(nil, api);
    NSArray<NSString *> *before = Listed(store, @"", @"C01GENERAL", nil);
    SNExpect([before containsObject:@"/archive"] && ![before containsObject:@"/remind"], "the client's own commands at once, the apps' once Slack answers");
    SNExpect([LastCall(api, @"client.appCommands")[@"_x_reason"] isEqualToString:@"app-commands-conditional-fetching:no-local-ts"], "asked once it is needed");
    SNWaitUntil(2, ^BOOL { return [Listed(store, @"", @"C01GENERAL", nil) containsObject:@"/remind"]; });
    NSArray<NSString *> *all = Listed(store, @"", @"C01GENERAL", nil);
    SNExpect([all containsObject:@"/away"] && ![all containsObject:@"/hidden"] && ![all containsObject:@"/vote"], "commands not autocompleted and aliases stay out of the list");
    SNExpect(![all containsObject:@"/msg"] && ![all containsObject:@"/topic"] && ![all containsObject:@"/search"] && ![all containsObject:@"/invite"] && ![all containsObject:@"/color"],
             "so do the ones Slack offers elsewhere and /color");
    SNExpect([[Listed(store, @"re", @"C01GENERAL", nil) subarrayWithRange:NSMakeRange(0, 3)] isEqualToArray:(@[ @"/remind", @"/remove", @"/rename" ])],
             "names that start with the query first");
    SNExpect([Listed(store, @"vo", @"C01GENERAL", nil) isEqualToArray:@[ @"/poll" ]], "an alias finds its command");
    SNExpect([Listed(store, @"standup bot", @"C01GENERAL", nil) containsObject:@"/standup"], "so does the integration's name");
    SNExpect([Listed(store, @"gif", @"C01GENERAL", nil) containsObject:@"/giphy"] && [store commandsMatching:@"" inConversation:@"C01GENERAL" threadTS:nil limit:2].count == 2,
             "the description counts, within the limit");
    NSArray<NSString *> *general = Listed(store, @"", @"C01ALL", nil), *dm = Listed(store, @"", @"D01KIM", nil);
    SNExpect(![general containsObject:@"/leave"] && ![general containsObject:@"/archive"] && [all containsObject:@"/leave"], "#general can be neither left nor archived");
    SNExpect([dm containsObject:@"/leave"] && ![dm containsObject:@"/archive"] && ![dm containsObject:@"/rename"] && ![dm containsObject:@"/remove"], "a DM can be left (closed), not archived");
    NSArray<NSString *> *thread = Listed(store, @"", @"C01GENERAL", @"1795400000.000100");
    SNExpect([thread containsObject:@"/remind"] && [thread containsObject:@"/away"] && ![thread containsObject:@"/leave"] && ![thread containsObject:@"/poll"],
             "a thread lists only what runs in threads");
    SNExpect([[store commandNamed:@"/Part"].name isEqualToString:@"/leave"] && [[store commandNamed:@"/vote"].name isEqualToString:@"/poll"] && ![store commandNamed:@"/nope"],
             "a typed name finds its command");
    Listed(store, @"", nil, nil);
    SNExpect([[api.methods filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF == 'client.appCommands'"]] count] == 1, "once a session");
}

SN_TEST(StoreRunsSlashCommandsWithChatCommand) {
    SNTestAPI *api = [SNTestAPI new];
    api.answer = ^NSDictionary *(NSString *method, NSDictionary *params) {
        if ([method isEqualToString:@"client.appCommands"]) return CommandList();
        if ([method isEqualToString:@"chat.command"]) return @{@"ok" : @YES, @"response" : @"Me lembrarei de “regar as plantas” em 5 minutos.", @"keep_input" : @NO};
        return @{@"ok" : @YES};
    };
    SNStore *store = CommandStore(nil, api);
    __block BOOL answered = NO;
    [store runCommand:@"/Remind" blocks:Blocks(@"me to water the plants in 5 minutes") inConversation:@"C01GENERAL" threadTS:nil completion:^(BOOL keepInput) {
        answered = !keepInput;
    }];
    NSDictionary *sent = LastCall(api, @"chat.command");
    NSArray *blocks = [NSJSONSerialization JSONObjectWithData:[sent[@"blocks"] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    SNExpect([sent[@"command"] isEqualToString:@"/remind"] && [sent[@"disp"] isEqualToString:@"/Remind"] && [sent[@"channel"] isEqualToString:@"C01GENERAL"] &&
                 [blocks isEqualToArray:Blocks(@"me to water the plants in 5 minutes")] && [sent[@"_x_reason"] isEqualToString:@"executeCommand"] && !sent[@"text"],
             "chat.command with the command, what was typed, the rest as rich_text and the channel");
    SNExpect([sent[@"client_token"] hasPrefix:@"web-"] && [[sent[@"client_token"] substringFromIndex:4] longLongValue] > 1700000000000, "a web- token of the time");
    SNWaitUntil(2, ^BOOL { return answered; });
    SNMessage *answer = [store messagesInConversation:@"C01GENERAL"].lastObject;
    SNExpect(answer.isEphemeral && [answer.userID isEqualToString:@"USLACKBOT"] && [answer.text hasPrefix:@"Me lembrarei"], "the answer shows as Slackbot, to the user only");

    [store runCommand:@"/shrug" blocks:nil inConversation:@"C01GENERAL" threadTS:@"1795400000.000100" completion:nil];
    sent = LastCall(api, @"chat.command");
    SNExpect([sent[@"thread_ts"] isEqualToString:@"1795400000.000100"] && !sent[@"blocks"], "from a thread, with its ts; no blocks without arguments");
    SNWaitUntil(2, ^BOOL { return [store threadInConversation:@"C01GENERAL" ts:@"1795400000.000100"].lastObject.isEphemeral; });
    SNExpect([store threadInConversation:@"C01GENERAL" ts:@"1795400000.000100"].lastObject.isEphemeral, "an answer to a thread's command shows in the thread");
}

SN_TEST(StoreShowsWhySlashCommandsFailed) {
    SNSetLanguage(@"en");
    SNTestAPI *api = [SNTestAPI new];
    __block NSString *error = @"unknown_command";
    api.answer = ^NSDictionary *(NSString *method, NSDictionary *params) {
        return [method isEqualToString:@"chat.command"] ? @{@"ok" : @NO, @"error" : error} : @{@"ok" : @YES, @"commands" : @[]};
    };
    SNStore *store = CommandStore(nil, api);
    [store runCommand:@"/nope" blocks:nil inConversation:@"C01GENERAL" threadTS:nil completion:nil];
    SNWaitUntil(2, ^BOOL { return [store messagesInConversation:@"C01GENERAL"].lastObject.isEphemeral; });
    NSString *text = [store messagesInConversation:@"C01GENERAL"].lastObject.text;
    SNExpect([text hasPrefix:@"*/nope* is not a valid command."] && [text containsString:@"preceding the \"/\" with an empty space"], "Slack's words for an unknown command");
    error = @"dispatch_failed";
    [store runCommand:@"/poll" blocks:nil inConversation:@"C01GENERAL" threadTS:nil completion:nil];
    SNWaitUntil(2, ^BOOL { return [[store messagesInConversation:@"C01GENERAL"].lastObject.text containsString:@"did not respond"]; });
    SNExpect([[[store messagesInConversation:@"C01GENERAL"] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"isEphemeral == YES"]] count] == 1,
             "an app that did not answer, in place of the answer before");
    error = @"invalid_arguments";
    api.answer = ^NSDictionary *(NSString *method, NSDictionary *params) {
        return [method isEqualToString:@"chat.command"] ? @{@"ok" : @NO, @"error" : error} : CommandList();
    };
    [store commandsMatching:@"" inConversation:nil threadTS:nil limit:1];
    SNWaitUntil(2, ^BOOL { return [store commandNamed:@"/vote"] != nil; });
    [store runCommand:@"/Vote" blocks:nil inConversation:@"C01GENERAL" threadTS:nil completion:nil];
    SNExpect([LastCall(api, @"chat.command")[@"command"] isEqualToString:@"/poll"] && [LastCall(api, @"chat.command")[@"disp"] isEqualToString:@"/Vote"],
             "the request names the command as listed");
    SNWaitUntil(2, ^BOOL { return [[store messagesInConversation:@"C01GENERAL"].lastObject.text containsString:@"invalid_arguments"]; });
    SNExpect([[store messagesInConversation:@"C01GENERAL"].lastObject.text hasPrefix:@"*/vote* failed with the error"], "the answer names it as typed, in lower case");
}

SN_TEST(StoreKeepsEphemeralMessagesOutOfTheCache) {
    NSURL *url = [NSFileManager.defaultManager.temporaryDirectory URLByAppendingPathComponent:@"slack-native-tests/ephemeral.sqlite"];
    [NSFileManager.defaultManager createDirectoryAtURL:url.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    for (NSString *suffix in @[ @"", @"-wal", @"-shm" ]) [NSFileManager.defaultManager removeItemAtPath:[url.path stringByAppendingString:suffix] error:nil];
    SNDatabase *database = [SNDatabase databaseAtURL:url];
    SNStore *store = CommandStore(database, [SNTestAPI new]);
    [store applyEvent:@{@"type" : @"message", @"channel" : @"C01GENERAL", @"user" : @"U0FIXBOT", @"bot_id" : @"B0FIXPOLLS", @"text" : @"Only you can see this poll draft",
                        @"ts" : @"1795400100.000200", @"is_ephemeral" : @YES}];
    SNMessage *shown = [store messagesInConversation:@"C01GENERAL"].lastObject;
    SNExpect(shown.isEphemeral && [shown.ts isEqualToString:@"1795400100.000200"], "an app's ephemeral message shows in its conversation");
    SNExpect(![database messageWithTS:@"1795400100.000200" inConversation:@"C01GENERAL" thread:nil], "and is never written to the cache");
    [store deleteMessage:shown];
    SNExpect(![[[store messagesInConversation:@"C01GENERAL"] valueForKey:@"ts"] containsObject:@"1795400100.000200"], "deleting it only drops it here");
}
