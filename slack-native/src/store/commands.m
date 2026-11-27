// Owns slash commands as Slack's web client lists and sends them: its own commands and
// client.appCommands' in one list, the chat.command request, and the answers only the user sees
// (ephemeral messages, kept in memory). The client's own commands run in ui/composer/commands.m.
#import "model/json.h"
#import "render/strings.h"
#import "store/internal.h"

// Implements part of SNSource, which the primary class adopts (see internal.h).
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

/// The commands Slack's client runs itself (Zrd3 getCommands) that this client runs too, in its
/// order, with its descriptions; its developer commands (/slackdevtools...) are not offered.
static NSArray<SNCommand *> *SNClientCommands(void) {
    NSMutableArray *json = [NSMutableArray new];
    void (^add)(NSString *, NSArray<NSString *> *, BOOL, BOOL) = ^(NSString *name, NSArray<NSString *> *aliases, BOOL usage, BOOL autocomplete) {
        NSString *key = [@"store.command.client." stringByAppendingString:[name substringFromIndex:1]];
        [json addObject:@{@"name" : name, @"type" : @"client", @"autocomplete" : @(autocomplete), @"desc" : SNLocalized([key stringByAppendingString:@".desc"]),
                          @"usage" : usage ? SNLocalized([key stringByAppendingString:@".usage"]) : @""}];
        for (NSString *alias in aliases) [json addObject:@{@"name" : alias, @"alias_of" : name}];
    };
    add(@"/archive", @[], NO, YES);
    add(@"/collapse", @[], NO, YES);
    add(@"/expand", @[], NO, YES);
    add(@"/feedback", @[], NO, YES);
    add(@"/gif", @[], YES, YES);
    add(@"/invite", @[], YES, YES);
    add(@"/invite_people", @[], YES, YES);
    add(@"/leave", @[ @"/close", @"/part" ], YES, YES);
    add(@"/msg", @[ @"/dm" ], YES, YES);
    add(@"/open", @[ @"/join" ], YES, YES);
    add(@"/remove", @[ @"/kick" ], YES, YES);
    add(@"/rename", @[], NO, YES);
    add(@"/search", @[ @"/s" ], YES, YES);
    add(@"/shortcuts", @[ @"/keys" ], NO, YES);
    add(@"/topic", @[], YES, YES);
    return [SNCommand commandsWithJSON:json];
}

/// Whether Slack's list offers the command in `conversation` (P+cE iH and mE): not the ones it
/// offers elsewhere (the header's topic, the search field...) or without autocomplete, /leave and
/// /remove only where they can run, and in a thread only what runs there.
static BOOL SNIsOffered(SNCommand *command, SNConversation *conversation, BOOL thread) {
    static NSSet<NSString *> *elsewhere;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ elsewhere = [NSSet setWithArray:@[ @"/topic", @"/search", @"/invite", @"/invite_people", @"/status", @"/dm", @"/msg" ]]; });
    NSString *name = command.name.lowercaseString;
    if (!command.autocompletes || [elsewhere containsObject:name] || (thread && !command.runsInThreads)) return NO;
    BOOL channel = conversation && !conversation.isDirect;
    if ([name isEqualToString:@"/leave"]) return conversation && !conversation.isGeneral;
    if ([name isEqualToString:@"/remove"] || [name isEqualToString:@"/archive"]) return channel && !conversation.isGeneral && !conversation.isArchived;
    if ([name isEqualToString:@"/rename"]) return channel;
    return YES;
}

static NSString *Folded(NSString *text) { return [text stringByFoldingWithOptions:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch locale:nil] ?: @""; }

/// The letters of `query` appear in `text` in order.
static BOOL InOrder(NSString *query, NSString *text) {
    NSUInteger at = 0;
    for (NSUInteger i = 0; i < query.length; i++) {
        NSRange found = [text rangeOfString:[query substringWithRange:NSMakeRange(i, 1)] options:0 range:NSMakeRange(at, text.length - at)];
        if (found.location == NSNotFound) return NO;
        at = NSMaxRange(found);
    }
    return YES;
}

@implementation SNStore (Commands)

#pragma mark The list

- (void)loadCommandsCache {
    if (!self.commandsCachePending) return;
    self.commandsCachePending = NO;
    id json = [self.database jsonForKey:@"app_commands"];
    NSArray<SNCommand *> *cached = [SNCommand commandsWithJSON:[json isKindOfClass:NSArray.class] ? json : @[]];
    if (cached.count) {
        self.commands = cached;
        [self changed:SNChangeCommands value:nil];
    }
}

- (void)askForCommands:(NSString *)cause {
    self.commandsAsked = YES;
    NSString *reason = [@"app-commands-conditional-fetching:" stringByAppendingString:cause];
    [self request:@"client.appCommands" params:@{@"_x_reason" : reason} priority:SNCallBackground completion:^(NSDictionary *response, NSError *error) {
        NSArray *json = SNJSONArray(response, @"commands");
        if (!json) {
            self.commandsAsked = NO;
            return;
        }
        [self performChanges:^{
            self.commandsCachePending = NO;
            self.commands = [SNCommand commandsWithJSON:json];
            [self.database setJSON:json forKey:@"app_commands"];
            [self changed:SNChangeCommands value:nil];
        }];
    }];
}

- (void)applyCommandsChanged { [self askForCommands:@"ts-mismatch"]; }

- (SNCommand *)commandNamed:(NSString *)name {
    if (self.commandsCachePending) [self loadCommandsCache];
    NSString *typed = [name stringByReplacingOccurrencesOfString:@"\u2019" withString:@"'"];
    for (SNCommand *command in [SNClientCommands() arrayByAddingObjectsFromArray:self.commands])
        if ([command isNamed:typed]) return command;
    return nil;
}

// Slack's list matches loosely: the name first, then its aliases, then the description and the
// app's name, then the name's letters in order. Its own commands come before the apps'.
- (NSArray<SNCommand *> *)commandsMatching:(NSString *)query inConversation:(NSString *)conversationID threadTS:(NSString *)threadTS limit:(NSUInteger)limit {
    if (self.commandsCachePending) [self loadCommandsCache];
    if (!self.commandsAsked) [self askForCommands:self.commands.count ? @"not-loaded" : @"no-local-ts"];
    SNConversation *conversation = conversationID ? [self knownConversationWithID:conversationID] : nil;
    NSString *typed = Folded(query);
    NSMutableArray<NSArray *> *ranked = [NSMutableArray new];
    NSMutableSet<NSString *> *names = [NSMutableSet new];
    for (SNCommand *command in [SNClientCommands() arrayByAddingObjectsFromArray:self.commands]) {
        if ([names containsObject:command.name.lowercaseString] || !SNIsOffered(command, conversation, threadTS != nil)) continue;
        [names addObject:command.name.lowercaseString];
        NSString *name = Folded([command.name substringFromIndex:1]);
        NSUInteger rank = NSNotFound;
        if (!typed.length || [name hasPrefix:typed]) rank = 0;
        else if ([[command.aliases filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF BEGINSWITH[cd] %@", [@"/" stringByAppendingString:typed]]] count]) rank = 1;
        else if ([name containsString:typed]) rank = 2;
        else if ([Folded(command.summary) containsString:typed] || [Folded(command.serviceName ?: @"") containsString:typed]) rank = 3;
        else if (InOrder(typed, name)) rank = 4;
        if (rank != NSNotFound) [ranked addObject:@[ @(rank), command ]];
    }
    [ranked sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) {
        NSComparisonResult byRank = [a[0] compare:b[0]];
        return byRank != NSOrderedSame ? byRank : [[a[1] name] compare:[b[1] name]];
    }];
    NSMutableArray *commands = [NSMutableArray new];
    for (NSArray *entry in ranked) {
        if (commands.count == limit) break;
        [commands addObject:entry[1]];
    }
    return commands;
}

#pragma mark Running

- (void)runCommand:(NSString *)typed blocks:(NSArray<NSDictionary *> *)blocks inConversation:(NSString *)conversationID threadTS:(NSString *)threadTS
        completion:(void (^)(BOOL))completion {
    [self clearCommandFeedbackInConversation:conversationID threadTS:threadTS];
    // Slack's answers name the command as typed, in lower case; the request names it as listed.
    NSString *shown = [typed.lowercaseString stringByReplacingOccurrencesOfString:@"\u2019" withString:@"'"];
    SNCommand *known = [self commandNamed:typed];
    // Slack's client tags its tokens "web-" and the time in milliseconds.
    NSString *token = [NSString stringWithFormat:@"web-%lld", (long long)(NSDate.date.timeIntervalSince1970 * 1000)];
    NSMutableDictionary *params = [@{@"command" : known.name ?: shown, @"disp" : typed, @"channel" : conversationID, @"client_token" : token,
                                     @"_x_reason" : @"executeCommand"} mutableCopy];
    if (blocks.count) params[@"blocks"] = SNJSONText(blocks);
    if (threadTS) params[@"thread_ts"] = threadTS;
    if (known.appID) params[@"app_id"] = known.appID;
    [self request:@"chat.command" params:params priority:SNCallUserFacing completion:^(NSDictionary *response, NSError *error) {
        NSString *text = SNJSONString(response, @"response");
        if (!error && text.length) [self showCommandFeedback:text inConversation:conversationID threadTS:threadTS temporary:YES];
        if (error) {
            NSString *reason = SNAPIErrorName(error);
            NSString *feedback = [reason isEqualToString:@"unknown_command"]          ? SNLocalizedFormat(@"store.command.unknown", shown)
                               : [reason isEqualToString:@"restricted_action"]       ? SNLocalizedFormat(@"store.command.restricted", shown)
                               : [reason isEqualToString:@"restricted_in_threads"]   ? SNLocalizedFormat(@"store.command.threads", shown)
                               : [reason isEqualToString:@"dispatch_failed"]         ? SNLocalizedFormat(@"store.command.dispatch", shown)
                               : [reason isEqualToString:@"dlp_user_warning"]        ? SNLocalized(@"store.command.dlp")
                               : reason && error.code == SNAPIErrorSlack             ? SNLocalizedFormat(@"store.command.error", shown, reason)
                                                                                     : SNLocalizedFormat(@"store.command.failed", shown);
            [self showCommandFeedback:feedback inConversation:conversationID threadTS:threadTS temporary:YES];
        }
        if (completion) completion(SNJSONBool(response, @"keep_input"));
    }];
}

#pragma mark Ephemeral messages

/// Slack's client shows a command's answer as Slackbot, in the thread it came from; the name
/// stands in while Slackbot's profile is not loaded.
- (void)showCommandFeedback:(NSString *)text inConversation:(NSString *)conversationID threadTS:(NSString *)threadTS temporary:(BOOL)temporary {
    [self clearCommandFeedbackInConversation:conversationID threadTS:threadTS];
    NSString *after = threadTS ? [self threadInConversation:conversationID ts:threadTS].lastObject.ts : [self messagesInConversation:conversationID].lastObject.ts;
    NSString *type = temporary ? (threadTS ? @"threads_temp_slash_cmd_feedback" : @"temp_slash_cmd_feedback") : @"slash_cmd_feedback";
    NSMutableDictionary *json = [@{@"type" : @"message", @"user" : @"USLACKBOT", @"username" : @"Slackbot", @"text" : text, @"ts" : SNLocalTS(after), @"is_ephemeral" : @YES,
                                   @"_ephemeral_type" : type} mutableCopy];
    if (threadTS) json[@"thread_ts"] = threadTS;
    SNMessage *message = [SNMessage messageWithJSON:json conversationID:conversationID];
    [self performChanges:^{ [self putEphemeral:message]; }];
}

- (void)clearCommandFeedbackInConversation:(NSString *)conversationID threadTS:(NSString *)threadTS {
    SNHistory *run = threadTS ? self.threads[SNThreadKey(conversationID, threadTS)] : self.histories[conversationID];
    for (SNMessage *message in [run.messages copy])
        if ([SNJSONString(message.json, @"_ephemeral_type") hasSuffix:@"temp_slash_cmd_feedback"])
            [self performChanges:^{
                [self updateMessage:message.ts inConversation:conversationID threadTS:threadTS transform:^SNMessage *(SNMessage *held) { return nil; }];
            }];
}

- (void)putEphemeral:(SNMessage *)message {
    NSString *conversationID = message.conversationID;
    NSMutableArray<NSString *> *keys = [NSMutableArray new];
    if (!message.isReply) [keys addObject:conversationID];
    if (message.threadTS) [keys addObject:SNThreadKey(conversationID, message.threadTS)];
    for (NSString *key in keys) {
        BOOL thread = [key containsString:@"/"];
        SNHistory *run = thread ? [self threadOf:key] : [self historyOf:conversationID];
        if (!run) continue;
        [run put:message];
        [self changed:thread ? SNChangeThreads : SNChangeMessages value:key];
        [self changed:SNChangeMessageKeys value:SNMessageKey(message)];
    }
}

@end
