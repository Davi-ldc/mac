// Decoding the API's shapes and the fixture source's behaviour.
#import "app/launch.h"
#import "model/json.h"
#import "test.h"

static SNFixtureSource *Fixture(void) { return [SNFixtureSource sourceWithFolder:SNPublicFixture()]; }

SN_TEST(ModelDecodesWorkspaceAndUsers) {
    SNFixtureSource *source = Fixture();
    SNExpect(source != nil, "public fixture loads");
    SNExpect([source.workspace.name isEqualToString:@"Northwind Studio"], "workspace name");
    SNExpect([source.workspace.url.absoluteString isEqualToString:@"https://northwind-studio.slack.com/"], "workspace url");
    SNExpect([[source.workspace iconURLForPixels:72].lastPathComponent isEqualToString:@"team-88.png"], "smallest icon at least 72 px");
    SNExpect([source.me.userID isEqualToString:@"U01ALEX"], "signed-in user from auth.test");
    SNExpect([source.me.locale isEqualToString:@"en-US"], "locale");
    SNExpect([source presenceOfUser:source.me.userID] == SNPresenceActive, "presence from users.list");
    SNUser *sam = [source userWithID:@"U02SAM"];
    SNExpect([sam.visibleName isEqualToString:@"Sam Chen"], "visible name falls back to the real name");
    SNExpect([source doNotDisturbOfUser:sam.userID], "dnd.teamInfo applied");
    SNExpect([sam.statusEmoji isEqualToString:@":headphones:"], "status emoji");
    SNExpect([[sam avatarURLForPixels:48].lastPathComponent isEqualToString:@"u02sam-48.png"], "avatar for 48 px");
    SNExpect([[sam avatarURLForPixels:4000].lastPathComponent isEqualToString:@"u02sam-512.png"], "largest avatar when none is big enough");
    SNExpect([source userWithID:@"U05TAYLOR"].isRestricted, "guest");
    SNExpect([source userWithID:@"U06BUILD"].isBot, "bot");
    SNExpect([source userWithID:@"U07CASEY"].deleted, "deleted");
}

SN_TEST(ModelDecodesConversationsAndCounts) {
    SNFixtureSource *source = Fixture();
    SNConversation *general = [source conversationWithID:@"C01GENERAL"];
    SNExpect(general.kind == SNConversationChannel && general.isGeneral, "public channel");
    SNExpect([general.topic isEqualToString:@"Company-wide announcements"], "topic");
    SNExpect(general.hasUnreads && general.mentionCount == 1, "client.counts applied");
    SNExpect([source conversationWithID:@"G04ENG"].kind == SNConversationPrivateChannel, "private channel");
    SNConversation *dm = [source conversationWithID:@"D05SAM"];
    SNExpect(dm.kind == SNConversationDirect && [dm.userID isEqualToString:@"U02SAM"] && dm.isMember, "DM");
    SNExpect([source conversationWithID:@"G07MPDM"].kind == SNConversationGroupDirect, "group DM");
    NSArray *ids = [source.directMessages valueForKey:@"conversationID"];
    SNExpect(([ids isEqualToArray:@[ @"D05SAM", @"D06PRIYA", @"G07MPDM" ]]), "DMs newest first, closed ones left out");
}

SN_TEST(ModelOrdersSections) {
    NSArray *ids = [Fixture().sections valueForKey:@"sectionID"];
    SNExpect(([ids isEqualToArray:@[ @"L01STARS", @"L02PROJECTS", @"L03CHANNELS", @"L04DMS" ]]), "sections follow next_channel_section_id");
    SNSection *projects = Fixture().sections[1];
    SNExpect([projects.type isEqualToString:SNSectionCustom] && [projects.name isEqualToString:@"Projects"], "custom section");
    SNExpect([projects.emoji isEqualToString:@"rocket"], "section emoji");
    SNSection *loop = [SNSection sectionWithJSON:@{@"channel_section_id" : @"A", @"next_channel_section_id" : @"A"}];
    SNExpect([SNSection orderedSections:@[ loop ]].count == 1, "a section pointing at itself is kept once");
}

SN_TEST(ModelDecodesMessages) {
    SNFixtureSource *source = Fixture();
    NSArray<SNMessage *> *messages = [source messagesInConversation:@"C01GENERAL"];
    SNExpect(messages.count == 6, "history decoded");
    SNExpect(SNCompareTS(messages.firstObject.ts, messages.lastObject.ts) == NSOrderedAscending, "oldest first");
    SNMessage *edited = messages[0];
    SNExpect(edited.editedTS != nil && edited.blocks.count == 1, "edited message with rich text blocks");
    SNExpect([edited.conversationID isEqualToString:@"C01GENERAL"], "conversation from the listing");
    SNExpect([messages[1].subtype isEqualToString:@"channel_join"], "subtype");
    SNMessage *file = messages[2];
    SNExpect(file.files.count == 1 && CGSizeEqualToSize(file.files[0].originalSize, CGSizeMake(2400, 1600)), "file with size");
    SNExpect([[file.files[0] thumbnailURLForPixels:400].absoluteString hasSuffix:@"_480.png"], "thumbnail for 400 px");
    SNExpect(file.files[0].thumbnailURLs.count == 9, "thumb_360_w and the like are not sizes");
    SNMessage *parent = messages[3];
    SNExpect(parent.isThreadParent && parent.replyCount == 2 && parent.replyUserIDs.count == 2, "thread parent");
    SNMessage *bot = messages[4];
    SNExpect([bot.username isEqualToString:@"Build Bot"] && bot.botIconURLs.count == 3 && bot.attachments.count == 1, "bot message");
    SNMessage *last = messages[5];
    SNExpect(last.reactions.count == 2 && last.reactions[0].count == 2, "reactions");
    NSArray *thread = [source threadInConversation:@"C01GENERAL" ts:parent.ts];
    SNExpect(thread.count == 3 && [thread[1] isReply], "thread replies");
}

SN_TEST(ModelComparesTimestamps) {
    SNExpect(SNCompareTS(@"999999999.000100", @"1000000000.000001") == NSOrderedAscending, "more seconds digits is later");
    SNExpect(SNCompareTS(@"1700000000.000100", @"1700000000.000099") == NSOrderedDescending, "microseconds compare");
    SNExpect(SNCompareTS(@"1700000000.000100", @"1700000000.000100") == NSOrderedSame, "equal");
}

SN_TEST(ModelRejectsMalformedJSON) {
    SNExpect([SNUser userWithJSON:@{@"name" : @"no id"}] == nil, "user without id");
    SNExpect([SNMessage messageWithJSON:@{@"text" : @"no ts"} conversationID:nil] == nil, "message without ts");
    SNUser *odd = [SNUser userWithJSON:@{@"id" : @"U1", @"profile" : @[], @"deleted" : @"yes", @"tz_offset" : @"3600"}];
    SNExpect(odd && !odd.deleted && odd.timeZoneOffset == 3600 && odd.avatarURLs.count == 0, "wrong types are ignored");
    SNExpect(SNJSONURL(@{@"u" : @"javascript:alert(1)"}, @"u") == nil, "only http(s) URLs");
}

/// edge users/info's "results" as a signed-in workspace answers them (made-up values): no
/// image_<size>, a custom picture's image_original on S3, avatar_hash for everyone.
SN_TEST(ModelBuildsPicturesFromTheAvatarHash) {
    NSDictionary *custom = @{
        @"id" : @"U0FAKE01",
        @"team_id" : @"T0FAKE",
        @"name" : @"pat",
        @"deleted" : @NO,
        @"is_bot" : @NO,
        @"is_app_user" : @NO,
        @"updated" : @1795000000,
        @"tz" : @"America/Sao_Paulo",
        @"profile" : @{
            @"avatar_hash" : @"0a1b2c3d4e5f",
            @"image_original" : @"https://s3-us-west-2.amazonaws.com/slack-files2/avatars/2026-01-01/1_0a1b2c3d4e5f_original.jpg",
            @"is_custom_image" : @YES,
            @"real_name" : @"Pat Example",
            @"display_name" : @"",
            @"team" : @"T0FAKE",
            @"fields" : @{},
            @"status_emoji_display_info" : @[],
        },
    };
    SNUser *pat = [SNUser userWithJSON:custom];
    SNExpect([[pat avatarURLForPixels:72].absoluteString isEqualToString:@"https://ca.slack-edge.com/T0FAKE-U0FAKE01-0a1b2c3d4e5f-72"],
             "a 36 pt avatar from the hash on Slack's avatar host");
    SNExpect([[pat avatarURLForPixels:32].absoluteString hasSuffix:@"-32"] && [[pat avatarURLForPixels:4000].absoluteString hasSuffix:@"-1024"],
             "every size it serves");
    NSDictionary *gravatar = SNJSONMerge(custom, @{@"id" : @"U0FAKE02", @"profile" : @{@"avatar_hash" : @"g0a1b2c3d4e5", @"team" : @"T0FAKE"}});
    SNExpect([[[SNUser userWithJSON:gravatar] avatarURLForPixels:72].absoluteString isEqualToString:@"https://ca.slack-edge.com/T0FAKE-U0FAKE02-g0a1b2c3d4e5-72"],
             "a Gravatar default the same way");
    SNUser *noHash = [SNUser userWithJSON:@{@"id" : @"U0FAKE03", @"team_id" : @"T0FAKE", @"profile" : @{@"real_name" : @"No Picture"}}];
    SNExpect(noHash.avatarURLs.count == 0, "nothing to build without a hash");
    SNUser *documented = [SNUser userWithJSON:SNJSONMerge(custom, @{@"profile" : @{@"avatar_hash" : @"0a1b2c3d4e5f", @"image_48" : @"https://avatars.slack-edge.com/x_48.png"}})];
    SNExpect(documented.avatarURLs.count == 1 && [[documented avatarURLForPixels:72].host isEqualToString:@"avatars.slack-edge.com"], "image_<size> wins when Slack sends it");
}

SN_TEST(ModelFixtureAppliesRequests) {
    SNFixtureSource *source = Fixture();
    __block SNChange *changes;
    id observer = SNObserveChanges(source, ^(SNChange *change) { changes = change; });
    [source sendText:@"hello" blocks:nil inConversation:@"D05SAM" threadTS:nil broadcast:NO];
    SNExpect([[source messagesInConversation:@"D05SAM"].lastObject.text isEqualToString:@"hello"], "sent message appended");
    SNExpect([changes.messages containsObject:@"D05SAM"], "change posted");
    SNMessage *last = [source messagesInConversation:@"C01GENERAL"].lastObject;
    [source toggleReaction:@"tada" onMessage:last];
    SNReaction *tada = [source messagesInConversation:@"C01GENERAL"].lastObject.reactions[0];
    SNExpect(tada.count == 1 && ![tada.userIDs containsObject:@"U01ALEX"], "own reaction removed");
    [source toggleReaction:@"eyes" onMessage:[source messagesInConversation:@"C01GENERAL"].lastObject];
    SNExpect([source messagesInConversation:@"C01GENERAL"].lastObject.reactions.count == 3, "new reaction added");
    SNExpect([source messagesInConversation:@"C01GENERAL"].lastObject.blocks.count == 1, "reacting keeps the message's blocks");
    [source markConversation:@"C01GENERAL" readThrough:last.ts];
    SNExpect(![source conversationWithID:@"C01GENERAL"].hasUnreads, "marked read");
    SNStopObserving(observer);
}
