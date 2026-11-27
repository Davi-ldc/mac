// Rendering the message shapes a signed-in cache holds (values made up): integration messages
// known only by bot_id, Slack's system messages in the reader's language, deleted parents,
// huddles, and shared messages whose blocks come in the attachment itself.
#import "../net/stub.h"
#import "model/json.h"
#import "render/message.h"
#import "render/strings.h"
#import "store/store.h"
#import "test.h"

static SNStore *RenderStore(void) {
    SNTestAPI *api = [SNTestAPI new];
    api.answer = ^NSDictionary *(NSString *method, NSDictionary *params) {
        if (![method isEqualToString:@"bots.info"]) return @{@"ok" : @YES};
        return @{@"ok" : @YES, @"bot" : @{@"id" : params[@"bot"], @"name" : @"Review Digest", @"icons" : @{@"image_72" : @"https://avatars.example.com/digest_72.png"}}};
    };
    SNStore *store = [[SNStore alloc] initWithDatabase:nil api:api];
    [store performChanges:^{
        [store applyWorkspace:@{@"id" : @"T0NORTHWND", @"name" : @"Northwind Studio", @"domain" : @"northwind-studio"}];
        [store applySelfUserID:@"U01ALEX"];
        [store applyUsers:@[ @{@"id" : @"U01ALEX", @"name" : @"alex", @"profile" : @{@"real_name" : @"Alex Rivera"}},
                             @{@"id" : @"U02SAM", @"name" : @"sam", @"profile" : @{@"real_name" : @"Sam Chen"}} ]];
        [store applyConversations:@[ @{@"id" : @"C01GENERAL", @"name" : @"general", @"is_channel" : @YES, @"is_member" : @YES} ]];
    }];
    return store;
}

static SNMessage *Shape(NSDictionary *json) { return [SNMessage messageWithJSON:json conversationID:@"C01GENERAL"]; }

SN_TEST(RenderNamesIntegrationsByTheirBot) {
    SNStore *store = RenderStore();
    SNRenderer *renderer = [[SNRenderer alloc] initWithSource:store];
    // An incoming webhook's message: no user, no username, no bot_profile.
    SNMessage *digest = Shape(@{@"type" : @"message", @"subtype" : @"bot_message", @"bot_id" : @"B0DIGEST", @"ts" : @"1795400000.000100", @"text" : @"",
                                @"blocks" : @[ @{@"type" : @"rich_text", @"block_id" : @"x1", @"elements" : @[ @{@"type" : @"rich_text_section", @"elements" : @[
                                    @{@"type" : @"broadcast", @"range" : @"channel"}, @{@"type" : @"text", @"text" : @" 2 pull requests"} ]} ]} ]});
    SNExpect([[renderer senderOfMessage:digest] isEqualToString:@""], "nameless until bots.info answers");
    SNExpect(SNWaitUntil(1, ^BOOL { return [store botWithID:@"B0DIGEST"] != nil; }), "asked of Slack");
    SNExpect([renderer isStaleAfterChange:SNChangeOf(SNChangeUsers, @"B0DIGEST")], "its arrival makes the name stale");
    SNExpect([[renderer senderOfMessage:digest] isEqualToString:@"Review Digest"], "then the bot's name");
    NSString *body = [renderer documentForMessage:digest].plainText;
    SNExpect([body containsString:@"@channel"] && [body hasSuffix:@" 2 pull requests"], "and its blocks");
    SNMessage *named = Shape(@{@"type" : @"message", @"subtype" : @"bot_message", @"bot_id" : @"B0OTHER", @"username" : @"Deploys", @"ts" : @"1795400000.000200", @"text" : @"ok"});
    SNExpect([[renderer senderOfMessage:named] isEqualToString:@"Deploys"], "a message's own username wins");
    SNMessage *added = Shape(@{@"type" : @"message", @"subtype" : @"bot_add", @"bot_id" : @"B0DIGEST", @"user" : @"U02SAM", @"ts" : @"1795400000.000300",
                               @"text" : @"added an integration to this channel: <https://northwind-studio.slack.com/services/B0DIGEST|Review Digest>",
                               @"bot_link" : @"<https://northwind-studio.slack.com/services/B0DIGEST|Review Digest>"});
    SNExpect([[renderer senderOfMessage:added] isEqualToString:@"Sam Chen"], "who added an integration is a person");
}

SN_TEST(RenderSystemMessagesInTheReadersLanguage) {
    NSString *language = SNLanguage();
    SNStore *store = RenderStore();
    SNRenderer *renderer = [[SNRenderer alloc] initWithSource:store];
    SNMessage *purpose = Shape(@{@"type" : @"message", @"subtype" : @"channel_purpose", @"user" : @"U02SAM", @"ts" : @"1795400000.000100",
                                 @"text" : @"set the channel description: Design &lt;&gt; Ops", @"purpose" : @"Design &lt;&gt; Ops"});
    SNMessage *added = Shape(@{@"type" : @"message", @"subtype" : @"bot_add", @"bot_id" : @"B0DIGEST", @"user" : @"U02SAM", @"ts" : @"1795400000.000200",
                               @"text" : @"added an integration to this channel: <https://northwind-studio.slack.com/services/B0DIGEST|Review Digest>",
                               @"bot_link" : @"<https://northwind-studio.slack.com/services/B0DIGEST|Review Digest>"});
    SNMessage *renamed = Shape(@{@"type" : @"message", @"subtype" : @"channel_name", @"user" : @"U02SAM", @"ts" : @"1795400000.000300",
                                 @"old_name" : @"design", @"name" : @"design-crew", @"text" : @"renamed the channel from \"design\" to \"design-crew\""});
    SNMessage *tombstone = Shape(@{@"type" : @"message", @"subtype" : @"tombstone", @"hidden" : @YES, @"user" : @"USLACKBOT", @"ts" : @"1795400000.000400",
                                   @"text" : @"This message was deleted.", @"thread_ts" : @"1795400000.000400", @"reply_count" : @1});
    SNMessage *huddle = Shape(@{@"type" : @"message", @"subtype" : @"huddle_thread", @"user" : @"U02SAM", @"ts" : @"1795400000.000500", @"text" : @"",
                                @"room" : @{@"id" : @"R0HUDDLE", @"has_ended" : @YES, @"date_start" : @1795400000, @"date_end" : @1795400720,
                                            @"participant_history" : @[ @"U01ALEX", @"U02SAM" ]}});
    SNMessage *joiner = Shape(@{@"type" : @"message", @"subtype" : @"joiner_notification", @"user" : @"U02SAM", @"ts" : @"1795400000.000600",
                                @"text" : @"Sam Chen joined Slack — take a second to say hello."});
    SNSetLanguage(@"pt-BR");
    SNExpect([[renderer documentForMessage:purpose].plainText isEqualToString:@"definiu a descrição do canal: Design <> Ops"], "a new description, in pt-BR");
    SNExpect([[renderer documentForMessage:added].plainText isEqualToString:@"adicionou uma integração a este canal: Review Digest"], "an integration added");
    SNExpect([[renderer documentForMessage:renamed].plainText isEqualToString:@"renomeou o canal de “design” para “design-crew”"], "a rename");
    SNExpect([[renderer documentForMessage:tombstone].plainText isEqualToString:@"Esta mensagem foi excluída."], "a deleted parent");
    SNExpect([[renderer documentForMessage:huddle].plainText isEqualToString:@"Você e Sam Chen ficaram no círculo por 12 min."], "a huddle that ended");
    SNSetLanguage(@"en");
    SNExpect([[renderer documentForMessage:purpose].plainText isEqualToString:@"set the channel description: Design <> Ops"], "and in English");
    SNExpect([[renderer documentForMessage:joiner].plainText hasPrefix:@"Sam Chen joined Slack"], "Slackbot's greetings show their text");
    SNSetLanguage(language);
}

SN_TEST(RenderSharedMessagesFromTheirBlocks) {
    SNStore *store = RenderStore();
    SNRenderer *renderer = [[SNRenderer alloc] initWithSource:store];
    NSArray *list = @[ @{@"type" : @"rich_text", @"block_id" : @"s1", @"elements" : @[
        @{@"type" : @"rich_text_section", @"elements" : @[ @{@"type" : @"user", @"user_id" : @"U01ALEX"}, @{@"type" : @"text", @"text" : @" two things:\n"} ]},
        @{@"type" : @"rich_text_list", @"style" : @"ordered", @"indent" : @0, @"border" : @0, @"elements" : @[
            @{@"type" : @"rich_text_section", @"elements" : @[ @{@"type" : @"text", @"text" : @"the date"} ]},
            @{@"type" : @"rich_text_section", @"elements" : @[ @{@"type" : @"text", @"text" : @"the data"} ]} ]} ]} ];
    SNMessage *forwarded = Shape(@{@"type" : @"message", @"user" : @"U02SAM", @"ts" : @"1795400000.000100", @"text" : @"", @"client_msg_id" : @"5d1c2f9e-0000-4000-8000-000000000001",
                                   @"attachments" : @[ @{@"id" : @1, @"is_share" : @YES, @"is_msg_unfurl" : @YES, @"is_thread_root_unfurl" : @YES, @"channel_id" : @"C01GENERAL",
                                                         @"author_id" : @"U01ALEX", @"author_name" : @"Alex Rivera", @"author_subname" : @"Alex Rivera",
                                                         @"author_link" : @"https://northwind-studio.slack.com/team/U01ALEX",
                                                         @"text" : @"<@U01ALEX> two things:\n1. the date\n2. the data", @"fallback" : @"[November 18th] Alex: two things",
                                                         @"footer" : @"Thread in #general", @"ts" : @"1795300000.000100", @"mrkdwn_in" : @[ @"text" ],
                                                         @"blocks" : list} ]});
    NSArray<SNRenderBlock *> *blocks = [renderer documentForMessage:forwarded].blocks;
    SNExpect(blocks.count == 1 && [blocks[0] isKindOfClass:SNGroupBlock.class], "one card");
    NSArray<SNRenderBlock *> *inside = ((SNGroupBlock *)blocks[0]).blocks;
    NSUInteger items = 0;
    for (SNRenderBlock *block in inside)
        items += [block isKindOfClass:SNParagraphBlock.class] && ((SNParagraphBlock *)block).marker.length;
    SNExpect(items == 2, "the shared message's list keeps its numbered items");
}

SN_TEST(RenderBroadcastsAndEditsAsSlackDoes) {
    NSString *language = SNLanguage();
    SNSetLanguage(@"en");
    SNStore *store = RenderStore();
    SNRenderer *renderer = [[SNRenderer alloc] initWithSource:store];
    // A broadcast whose parent the loaded history does not reach: Slack sends it as "root".
    SNMessage *broadcast = Shape(@{@"type" : @"message", @"subtype" : @"thread_broadcast", @"user" : @"U01ALEX", @"ts" : @"1795400100.000100",
                                   @"thread_ts" : @"1795400000.000100", @"text" : @"done", @"client_msg_id" : @"5d1c2f9e-0000-4000-8000-000000000002",
                                   @"root" : @{@"type" : @"message", @"user" : @"U02SAM", @"ts" : @"1795400000.000100", @"thread_ts" : @"1795400000.000100",
                                               @"text" : @"Can we ship <@U01ALEX>?", @"reply_count" : @3}});
    NSString *inChannel = [renderer documentForMessage:broadcast].plainText;
    SNExpect([inChannel hasPrefix:@"replied to a thread: Can we ship @Alex Rivera?"], "the channel quotes the parent from root, without placeholders");
    SNExpect([[renderer documentForMessage:broadcast inThread:YES].plainText isEqualToString:@"Also sent to the channel\ndone"], "the thread says where else it went");
    SNMessage *edited = Shape(@{@"type" : @"message", @"user" : @"U02SAM", @"ts" : @"1795400200.000100", @"text" : @"done :white_check_mark:",
                                @"edited" : @{@"user" : @"U02SAM", @"ts" : @"1795400300.000000"},
                                @"blocks" : @[ @{@"type" : @"rich_text", @"elements" : @[ @{@"type" : @"rich_text_section", @"elements" : @[
                                    @{@"type" : @"text", @"text" : @"done "}, @{@"type" : @"emoji", @"name" : @"white_check_mark", @"unicode" : @"2705"} ]} ]} ]});
    SNParagraphBlock *last = (SNParagraphBlock *)[renderer documentForMessage:edited].blocks.lastObject;
    NSRange label = [last.text.string rangeOfString:@" (edited)"];
    NSFont *space = label.location == NSNotFound ? nil : [last.text attribute:NSFontAttributeName atIndex:label.location effectiveRange:NULL];
    SNExpect(space && space.pointSize < 14 && ![space.fontName containsString:@"Emoji"], "the space before (edited) is the label's, not the emoji's");
    SNSetLanguage(language);
}
