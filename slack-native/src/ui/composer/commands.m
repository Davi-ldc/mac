// Owns running the client's own slash commands: parsing what follows them, their checks, dialogs,
// requests and answers, as the web client's slash-commands-local handlers do.
#import "model/json.h"
#import "render/expandable.h"
#import "render/strings.h"
#import "theme/theme.h"
#import "ui/composer/addpeople.h"
#import "ui/composer/commands.h"
#import "ui/composer/invitepeople.h"
#import "ui/composer/reminder.h"
#import "ui/composer/richtext.h"
#import "ui/kit/dialog.h"
#import "ui/present/message.h"
#import "ui/present/names.h"

/// Topics past this many characters are refused before asking Slack.
static const NSUInteger kTopicLimit = 250;

static BOOL IsUserID(NSString *value) { return [value hasPrefix:@"U"] || [value hasPrefix:@"W"]; }
static BOOL IsChannelID(NSString *value) { return [value hasPrefix:@"C"] || [value hasPrefix:@"G"]; }
static BOOL IsGroupID(NSString *value) { return [value hasPrefix:@"S"]; }

NSArray<NSDictionary *> *SNSlashCommandParams(NSAttributedString *rest) {
    NSMutableArray<NSDictionary *> *params = [NSMutableArray new];
    NSString *string = rest.string;
    [rest enumerateAttribute:SNRichEntityAttribute inRange:NSMakeRange(0, rest.length) options:0 usingBlock:^(SNRichEntity *entity, NSRange range, BOOL *stop) {
        // A mention picked before its ID is known carries no value; it is passed on as the words it shows.
        if (entity.value.length && (entity.kind == SNRichEntityUser || entity.kind == SNRichEntityChannel || entity.kind == SNRichEntityUsergroup)) {
            [params addObject:@{@"type" : @"mention", @"value" : entity.value, @"range" : [NSValue valueWithRange:range]}];
            return;
        }
        NSScanner *scanner = [NSScanner scannerWithString:[string substringWithRange:range]];
        scanner.charactersToBeSkipped = nil;
        NSCharacterSet *space = NSCharacterSet.whitespaceAndNewlineCharacterSet;
        while (!scanner.isAtEnd) {
            [scanner scanCharactersFromSet:space intoString:NULL];
            NSUInteger start = scanner.scanLocation;
            NSString *word = nil;
            if ([scanner scanUpToCharactersFromSet:space intoString:&word])
                [params addObject:@{@"type" : @"string", @"value" : word, @"range" : [NSValue valueWithRange:NSMakeRange(range.location + start, word.length)]}];
        }
    }];
    return params;
}

/// "#name" for a channel, the person or people for a DM, as Slack's dialogs name it.
static NSString *Label(SNConversation *conversation, id<SNSource> source) {
    return conversation.isDirect ? SNConversationTitle(conversation, source) : [@"#" stringByAppendingString:conversation.name];
}

static NSString *Trimmed(NSString *text) { return [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]; }

/// BaseArchiveDialog's renderError.
static NSString *ArchiveRefusal(NSString *error, BOOL leaving, BOOL priv) {
    if ([error isEqualToString:@"last_ra_channel"]) return SNLocalized(@"composer.command.archive.lastGuestChannel");
    if ([error isEqualToString:@"restricted_action"] || [error isEqualToString:@"user_is_restricted"])
        return SNLocalized(leaving ? @"composer.command.leaveArchive.restricted" : priv ? @"composer.command.archive.restrictedPrivate" : @"composer.command.archive.restricted");
    if ([error isEqualToString:@"already_archived"]) return SNLocalized(@"composer.command.archive.already");
    if ([error isEqualToString:@"cant_archive_general"]) return SNLocalized(@"composer.command.archive.general");
    return SNLocalizedFormat(@"composer.command.archive.failed", error);
}

/// One command being run: what it was given and where it answers.
@interface SNCommandRun : NSObject <NSTextFieldDelegate>
@property (nonatomic) id<SNSource> source;
@property (nonatomic, weak) id<SNNavigator> navigator;
@property (nonatomic, weak) NSWindow *window;
/// `cmd` is the command as typed in lower case, which Slack's answers name; `name` the command it runs.
@property (nonatomic, copy) NSString *typed, *cmd, *name, *conversationID;
@property (nonatomic, copy, nullable) NSString *threadTS;
@property (nonatomic) NSAttributedString *rest;
@property (nonatomic) NSArray<NSDictionary *> *params;
@property (nonatomic, copy) void (^restore)(void);
@property (nonatomic, copy, nullable) void (^openGifPicker)(NSString *query);
/// The rename dialog, its field and the name it started from.
@property (nonatomic, weak) SNConfirmDialog *dialog;
@property (nonatomic, weak) NSTextField *field;
@property (nonatomic, copy) NSString *currentName;
@end

@implementation SNCommandRun

#pragma mark Answers

/// A temporary answer from Slackbot where the command was typed.
- (void)say:(NSString *)text { [self.source showCommandFeedback:text inConversation:self.conversationID threadTS:self.threadTS temporary:YES]; }

- (void)alert:(NSString *)title text:(NSString *)text {
    if (self.window) [SNConfirmDialog showAlertInWindow:self.window title:title text:text buttonTitle:SNLocalized(@"composer.command.ok")];
    else [self say:text];
}

- (SNConversation *)here { return [self.source conversationWithID:self.conversationID]; }

/// The conversation a mention names: a channel, or a person's DM; nil for anything else.
- (SNConversation *)conversationNamedBy:(NSDictionary *)param {
    if (![param[@"type"] isEqualToString:@"mention"]) return nil;
    NSString *value = param[@"value"];
    if (IsChannelID(value)) return [self.source conversationWithID:value];
    if (IsUserID(value))
        for (SNConversation *conversation in self.source.directMessages)
            if (conversation.kind == SNConversationDirect && [conversation.userID isEqualToString:value]) return conversation;
    return nil;
}

#pragma mark Running

- (void)start {
    NSString *name = self.name;
    if ([name isEqualToString:@"/leave"]) return [self leave];
    if ([name isEqualToString:@"/msg"]) return [self message];
    if ([name isEqualToString:@"/open"]) return [self open];
    if ([name isEqualToString:@"/topic"]) return [self topic];
    if ([name isEqualToString:@"/invite"]) return [self invite];
    if ([name isEqualToString:@"/remove"]) return [self removeMember];
    if ([name isEqualToString:@"/rename"]) return [self rename];
    if ([name isEqualToString:@"/archive"]) return [self archive];
    if ([name isEqualToString:@"/search"]) return [self.navigator openSearchWithQuery:Trimmed(self.rest.string)];
    if ([name isEqualToString:@"/collapse"]) return [self setFilesExpanded:NO];
    if ([name isEqualToString:@"/expand"]) return [self setFilesExpanded:YES];
    if ([name isEqualToString:@"/shortcuts"]) return [self togglePanel:SNPanelShortcuts];
    if ([name isEqualToString:@"/feedback"]) {
        SNSetFeedbackStartText(Trimmed(self.rest.string));
        return [self openPanel:SNPanelFeedback];
    }
    if ([name isEqualToString:@"/gif"]) return [self gif];
    if ([name isEqualToString:@"/invite_people"]) return [self invitePeople];
}

#pragma mark /shortcuts, /feedback

/// toggleKeyboardShortcuts: the panel closes when it is the one open.
- (void)togglePanel:(NSString *)panel {
    SNLocation *here = self.navigator.location;
    [self.navigator go:[here locationWithPanel:[here.panel isEqualToString:panel] ? nil : panel]];
}

- (void)openPanel:(NSString *)panel { [self.navigator go:[self.navigator.location locationWithPanel:panel]]; }

#pragma mark /gif, /invite_people

// The team's allow_native_gif_picker turns the picker off.
- (void)gif {
    id allowed = SNJSONObject(self.source.workspace.json, @"prefs")[@"allow_native_gif_picker"];
    if ([allowed isKindOfClass:NSNumber.class] && ![allowed boolValue]) return [self say:SNLocalized(@"composer.command.gif.disabled")];
    NSMutableArray<NSString *> *words = [NSMutableArray new];
    for (NSDictionary *param in self.params)
        if ([param[@"type"] isEqualToString:@"string"]) [words addObject:param[@"value"]];
    if (self.openGifPicker) self.openGifPicker([words componentsJoinedByString:@" "]);
}

// invitePeopleCommand: the typed addresses fill the dialog's To.
- (void)invitePeople {
    if (!self.window) return;
    NSMutableArray<NSString *> *emails = [NSMutableArray new];
    for (NSString *email in [Trimmed(self.rest.string) componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@", \n\t"]])
        if (email.length) [emails addObject:email];
    [SNInvitePeopleDialog showInWindow:self.window source:self.source emails:emails];
}

#pragma mark /leave

- (void)leave {
    SNConversation *target = self.params.count ? [self conversationNamedBy:self.params[0]] : self.here;
    if (!target) return [self say:SNLocalized(@"composer.command.channelRequired")];
    [self leaveConversation:target];
}

// maybeLeaveChannel: a DM closes; a channel Slack would refuse explains why; one that only the user
// is in may be archived on the way out; private and shared ones ask first; public ones leave at once.
- (void)leaveConversation:(SNConversation *)conversation {
    if (conversation.isDirect) return [self.source closeConversation:conversation.conversationID];
    SNUser *me = self.source.me;
    if (conversation.isGeneral) return [self explainLeaving:conversation error:@"cant_leave_general"];
    if (me.isRestricted && conversation.kind == SNConversationChannel) return [self explainLeaving:conversation error:@"user_is_restricted"];
    BOOL archivable = !conversation.isArchived && !me.isRestricted;
    BOOL priv = conversation.kind == SNConversationPrivateChannel;
    if ((!priv && !archivable) || conversation.isArchived) return [self leaveNow:conversation];
    if (conversation.memberCount == 1 && !conversation.isShared) return [self leaveAndArchive:conversation];
    if (!priv && !conversation.isShared) return [self leaveNow:conversation];
    if (!self.window) return [self leaveNow:conversation];
    NSString *text = SNLocalized(priv ? @"composer.command.leave.private" : @"composer.command.leave.shared");
    [SNConfirmDialog showInWindow:self.window
                            title:SNLocalizedFormat(@"composer.command.leave.title", Label(conversation, self.source))
                             text:text
                        accessory:nil
                     confirmTitle:SNLocalized(@"composer.command.leave.confirm")
                       completion:^(BOOL confirmed) {
                           if (confirmed) [self leaveNow:conversation];
                       }];
}

- (void)leaveNow:(SNConversation *)conversation {
    [self.source leaveConversation:conversation.conversationID completion:^(NSString *error) {
        if (error) [self explainLeaving:conversation error:error];
    }];
}

/// LeaveChannelError: the reason Slack gave, or Retry.
- (void)explainLeaving:(SNConversation *)conversation error:(NSString *)error {
    NSString *label = Label(conversation, self.source);
    NSString *failed = SNLocalizedFormat(@"composer.command.leave.failedTitle", label);
    if ([error isEqualToString:@"cant_leave_general"])
        return [self alert:SNLocalizedFormat(@"composer.command.leave.requiredTitle", label) text:SNLocalized(@"composer.command.leave.general")];
    if ([error isEqualToString:@"user_is_restricted"]) return [self alert:failed text:SNLocalized(@"composer.command.leave.guest")];
    if ([error isEqualToString:@"user_is_ultra_restricted"] || [error isEqualToString:@"last_ra_channel"])
        return [self alert:failed text:SNLocalized(@"composer.command.leave.lastChannel")];
    if (!self.window) return [self say:SNLocalized(@"composer.command.failed")];
    id<SNSource> source = self.source;
    [SNConfirmDialog showInWindow:self.window
                            title:failed
                             text:SNLocalized(@"composer.command.failed")
                        accessory:nil
                     confirmTitle:SNLocalized(@"composer.command.leave.retry")
                           danger:NO
                          perform:^(void (^finish)(NSString *)) {
                              [source leaveConversation:conversation.conversationID completion:^(NSString *again) {
                                  finish(again ? SNLocalized(@"composer.command.failed") : nil);
                              }];
                          }];
}

/// The archive dialog with andLeave: the last one in a channel archives it rather than leave it
/// empty.
- (void)leaveAndArchive:(SNConversation *)conversation {
    if (!self.window) return [self leaveNow:conversation];
    NSString *label = Label(conversation, self.source);
    id<SNSource> source = self.source;
    BOOL priv = conversation.kind == SNConversationPrivateChannel;
    [SNConfirmDialog showInWindow:self.window
                            title:SNLocalizedFormat(@"composer.command.leaveArchive.title", label)
                             text:SNLocalizedFormat(@"composer.command.leaveArchive.text", label)
                        accessory:nil
                     confirmTitle:SNLocalized(@"composer.command.leaveArchive.confirm")
                           danger:NO
                          perform:^(void (^finish)(NSString *)) {
                              [source archiveConversation:conversation.conversationID completion:^(NSString *error) {
                                  finish(error ? ArchiveRefusal(error, YES, priv) : nil);
                              }];
                          }];
}

#pragma mark /msg

// msgCommand: the person's DM or the channel opens, joined first when needed, and the rest after
// the mention is sent there as a message (never as a command).
- (void)message {
    if (!self.params.count) return [self.navigator selectTab:SNTabDirectMessages];
    NSDictionary *first = self.params[0];
    if (![first[@"type"] isEqualToString:@"mention"]) return [self say:SNLocalized(@"composer.command.memberRequired")];
    NSString *value = first[@"value"];
    NSUInteger after = NSMaxRange([first[@"range"] rangeValue]);
    NSAttributedString *body = [self.rest attributedSubstringFromRange:NSMakeRange(after, self.rest.length - after)];
    NSUInteger lead = 0;
    while (lead < body.length && [NSCharacterSet.whitespaceAndNewlineCharacterSet characterIsMember:[body.string characterAtIndex:lead]]) lead++;
    body = [body attributedSubstringFromRange:NSMakeRange(lead, body.length - lead)];
    SNRichMessage *message = SNRichMessageFromDocument(body);
    id<SNSource> source = self.source;
    __weak id<SNNavigator> navigator = self.navigator;
    void (^deliver)(NSString *) = ^(NSString *conversationID) {
        [navigator openConversation:conversationID];
        if (message) [source sendText:message.text blocks:message.blocks inConversation:conversationID threadTS:nil broadcast:NO];
    };
    if (IsGroupID(value)) return [self say:SNLocalizedFormat(@"composer.command.msg.groups", self.cmd)];
    if (IsUserID(value)) {
        SNUser *user = [source userWithID:value];
        if (!user) return [self say:SNLocalized(@"composer.command.memberRequired")];
        if (user.deleted && message) return [self say:SNLocalized(@"composer.command.deactivated")];
        [source openDirectMessageWithUsers:@[ value ] completion:^(NSString *conversationID) {
            if (conversationID) deliver(conversationID);
            else {
                [self say:SNLocalized(@"composer.command.failed")];
                self.restore();
            }
        }];
        return;
    }
    SNConversation *channel = [source conversationWithID:value];
    if (!channel) return [self say:SNLocalized(@"composer.command.channelRequired")];
    if (channel.isArchived && message)
        return [self say:SNLocalized(channel.kind == SNConversationPrivateChannel ? @"composer.command.archivedPrivate" : @"composer.command.archivedChannel")];
    if (channel.isMember) return deliver(value);
    [source joinConversation:value completion:^(NSString *error) {
        if (!error || [error isEqualToString:@"is_archived"]) return deliver(value);
        [self say:SNLocalized([error isEqualToString:@"channel_not_found"] ? @"composer.command.channelRequired" : @"composer.command.failed")];
        self.restore();
    }];
}

#pragma mark /open

- (void)open {
    // openChannelBrowser: the Channels page, on Home.
    if (!self.params.count) {
        SNLocation *here = self.navigator.location;
        return [self.navigator go:[SNLocation locationWithTab:SNTabHome conversation:nil thread:nil page:SNPageChannels panel:here.panel]];
    }
    NSDictionary *first = self.params[0];
    NSString *typedName = Trimmed(self.rest.string);
    if ([typedName hasPrefix:@"#"]) typedName = Trimmed([typedName substringFromIndex:1]);
    id<SNSource> source = self.source;
    __weak id<SNNavigator> navigator = self.navigator;
    if (![first[@"type"] isEqualToString:@"mention"]) {
        // Slack would offer to create the channel; a channel of that name this client knows opens.
        for (SNConversation *channel in [source channelsMatching:typedName limit:20])
            if ([channel.name caseInsensitiveCompare:typedName] == NSOrderedSame) return [self joinAndOpen:channel name:typedName];
        return [self say:SNLocalizedFormat(@"composer.command.open.notFound", typedName)];
    }
    NSString *value = first[@"value"];
    if (IsUserID(value)) {
        [source openDirectMessageWithUsers:@[ value ] completion:^(NSString *conversationID) {
            if (conversationID) [navigator openConversation:conversationID];
            else [self say:SNLocalized(@"composer.command.memberRequired")];
        }];
        return;
    }
    SNConversation *channel = IsChannelID(value) ? [source conversationWithID:value] : nil;
    if (!channel) return [self say:SNLocalizedFormat(@"composer.command.open.notFound", typedName)];
    [self joinAndOpen:channel name:channel.name];
}

/// joinAndSwitchToChannel: an archived channel opens without joining.
- (void)joinAndOpen:(SNConversation *)channel name:(NSString *)name {
    __weak id<SNNavigator> navigator = self.navigator;
    NSString *conversationID = channel.conversationID;
    if (channel.isMember || channel.isDirect) return [navigator openConversation:conversationID];
    [self.source joinConversation:conversationID completion:^(NSString *error) {
        if (!error || [error isEqualToString:@"is_archived"]) [navigator openConversation:conversationID];
        else [self say:SNLocalizedFormat(@"composer.command.open.joinFailed", name)];
    }];
}

#pragma mark /topic

- (void)topic {
    SNRichMessage *message = SNRichMessageFromDocument(self.rest);
    NSString *topic = Trimmed(message.text ?: @"");
    if (!topic.length) return;
    if (topic.length > kTopicLimit) return [self say:SNLocalizedFormat(@"composer.command.topic.long", @(kTopicLimit))];
    id<SNSource> source = self.source;
    [source setTopic:topic ofConversation:self.conversationID completion:^(NSString *error) {
        if (!error) return;
        NSString *key = [error isEqualToString:@"restricted_action"] || [error isEqualToString:@"user_is_restricted"] ? @"composer.command.topic.restricted"
                        : [error isEqualToString:@"method_not_supported_for_channel_type"]                            ? @"composer.command.topic.unsupported"
                        : [error isEqualToString:@"method_not_supported_for_dm"]                                      ? @"composer.command.topic.dm"
                                                                                                                      : @"composer.command.topic.failed";
        [self say:SNLocalized(key)];
    }];
}

#pragma mark /invite

// inviteCommand: one person or one user group, to this channel or the one mentioned. A DM's people
// are added in a new group DM through Slack's dialog, and a private channel's through its
// add-people dialog, after its warning.
- (void)invite {
    NSMutableArray<NSString *> *users = [NSMutableArray new], *groups = [NSMutableArray new], *channels = [NSMutableArray new];
    for (NSDictionary *param in self.params) {
        if (![param[@"type"] isEqualToString:@"mention"]) continue;
        NSString *value = param[@"value"];
        if (IsUserID(value)) [users addObject:value];
        else if (IsGroupID(value)) [groups addObject:value];
        else if (IsChannelID(value)) [channels addObject:value];
    }
    if (self.here.isDirect && !channels.count) return [self inviteToDirect:self.here users:users];
    if (!users.count && !groups.count) return [self say:SNLocalized(@"composer.command.memberRequired")];
    if (users.count + groups.count > 1) return [self say:SNLocalizedFormat(@"composer.command.invite.one", self.cmd)];
    if (channels.count > 1) return [self say:SNLocalizedFormat(@"composer.command.invite.oneChannel", self.cmd)];
    SNConversation *target = channels.count ? [self.source conversationWithID:channels[0]] : self.here;
    if (!target) return [self say:SNLocalized(@"composer.command.channelRequired")];
    if (target.isDirect) return [self inviteToDirect:target users:users];
    SNUser *user = users.count ? [self.source userWithID:users[0]] : nil;
    if (users.count && !user) return [self say:SNLocalized(@"composer.command.memberRequired")];
    if (user.deleted) return [self say:SNLocalized(@"composer.command.deactivated")];
    // inviteMemberToChannel: a person (not an app) goes through the dialog in a private channel.
    if (user && !user.isBot && target.kind == SNConversationPrivateChannel && self.window) {
        [SNAddPeopleDialog showForChannel:target users:users inWindow:self.window source:self.source];
        return;
    }
    NSString *name = user.visibleName ?: @"";
    NSString *team = self.source.workspace.name ?: @"";
    [self.source inviteUsers:users usergroups:groups toConversation:target.conversationID completion:^(NSString *error) {
        if (!error) return;
        NSString *text = [error isEqualToString:@"already_in_channel"]                ? (groups.count ? SNLocalized(@"composer.command.invite.groupAlready")
                                                                                                     : SNLocalizedFormat(@"composer.command.invite.already", name))
                         : [error isEqualToString:@"channel_not_found"]               ? SNLocalized(@"composer.command.channelRequired")
                         : [error isEqualToString:@"user_not_found"]                  ? SNLocalized(@"composer.command.memberRequired")
                         : [error isEqualToString:@"no_permission"]                   ? SNLocalizedFormat(@"composer.command.invite.team", team)
                         : [error isEqualToString:@"no_external_invite_permission"]   ? SNLocalized(@"composer.command.invite.external")
                         : [error isEqualToString:@"cant_invite"]                     ? SNLocalizedFormat(@"composer.command.invite.cant", name)
                         : [error isEqualToString:@"user_is_restricted"]              ? SNLocalizedFormat(@"composer.command.invite.guest", name)
                         : [error isEqualToString:@"user_disabled"]                   ? SNLocalized(@"composer.command.deactivated")
                                                                                      : SNLocalized(@"composer.command.failed");
        [self say:text];
    }];
}

/// A DM's or group DM's /invite: 9 people at most, the user included; not with oneself or an app.
- (void)inviteToDirect:(SNConversation *)conversation users:(NSArray<NSString *> *)users {
    NSMutableSet<NSString *> *members = [NSMutableSet setWithObject:self.source.me.userID ?: @""];
    for (SNUser *person in SNConversationPeople(conversation, self.source)) [members addObject:person.userID];
    if (conversation.userID) [members addObject:conversation.userID];
    if (members.count >= 9) return [self say:SNLocalized(@"composer.command.invite.groupFull")];
    SNUser *other = conversation.kind == SNConversationDirect ? [self.source userWithID:conversation.userID ?: @""] : nil;
    if (conversation.kind == SNConversationDirect && (members.count < 2 || other.isBot || [conversation.userID isEqualToString:@"USLACKBOT"]))
        return [self say:SNLocalized(@"composer.command.invite.notAllowed")];
    if (!self.window) return;
    NSMutableArray<NSString *> *added = [NSMutableArray new];
    for (NSString *userID in users) {
        SNUser *user = [self.source userWithID:userID];
        if (!user || user.isBot || user.deleted || [members containsObject:userID] || [added containsObject:userID]) continue;
        if (members.count + added.count >= 9) break;
        [added addObject:userID];
    }
    [SNAddPeopleDialog showForConversation:conversation users:added inWindow:self.window source:self.source navigator:self.navigator];
}

#pragma mark /remove

- (void)removeMember {
    NSDictionary *first = self.params.firstObject;
    if (!first) return [self say:SNLocalized(@"composer.command.remove.who")];
    if (![first[@"type"] isEqualToString:@"mention"] || !IsUserID(first[@"value"]))
        return [self say:SNLocalizedFormat(@"composer.command.remove.unknown", first[@"value"])];
    NSString *userID = first[@"value"];
    SNConversation *conversation = self.here;
    if (!conversation) return;
    if ([userID isEqualToString:self.source.me.userID]) return [self leaveConversation:conversation];
    NSString *label = Label(conversation, self.source);
    if (conversation.isDirect) return [self say:SNLocalized(@"composer.command.remove.dm")];
    if (conversation.isGeneral) return [self say:SNLocalizedFormat(@"composer.command.remove.general", label)];
    if (conversation.isArchived) return [self say:SNLocalizedFormat(@"composer.command.remove.archived", label)];
    SNUser *user = [self.source userWithID:userID];
    NSString *name = user.visibleName ?: userID;
    if (!self.window) return;
    id<SNSource> source = self.source;
    NSString *conversationID = conversation.conversationID;
    BOOL priv = conversation.kind == SNConversationPrivateChannel;
    [SNConfirmDialog showInWindow:self.window
                            title:SNLocalizedFormat(@"composer.command.remove.title", name, label)
                             text:SNLocalized(priv ? @"composer.command.remove.private" : @"composer.command.remove.public")
                        accessory:nil
                     confirmTitle:SNLocalized(@"composer.command.remove.confirm")
                           danger:YES
                          perform:^(void (^finish)(NSString *)) {
                              [source removeUser:userID fromConversation:conversationID completion:^(NSString *error) {
                                  if (!error) return finish(nil);
                                  finish([error isEqualToString:@"restricted_action"] ? SNLocalizedFormat(@"composer.command.remove.restricted", name)
                                         : [error isEqualToString:@"not_in_channel"]  ? SNLocalizedFormat(@"composer.command.remove.notIn", name, label)
                                                                                      : SNLocalizedFormat(@"composer.command.remove.failed", name, label));
                              }];
                          }];
}

#pragma mark /rename

- (void)rename {
    SNConversation *conversation = self.here;
    if (!conversation) return;
    if (conversation.isDirect) return [self say:SNLocalized(@"composer.command.rename.dm")];
    if (!self.window) return;
    NSString *typedName = Trimmed(self.rest.string);
    NSTextField *field = [NSTextField textFieldWithString:typedName.length ? typedName : conversation.name];
    field.frame = NSMakeRect(0, 0, 464, 36);
    field.font = SNFont(SNFontSizeBase, SNFontWeightRegular);
    field.textColor = SNColor(SNColorContentPry);
    field.backgroundColor = SNColor(SNColorBasePry);
    field.bezelStyle = NSTextFieldRoundedBezel;
    field.focusRingType = NSFocusRingTypeNone;
    id<SNSource> source = self.source;
    NSString *conversationID = conversation.conversationID;
    field.delegate = self;
    self.field = field;
    self.currentName = conversation.name;
    // The block keeps this run, the field's delegate, while the dialog is open.
    self.dialog = [SNConfirmDialog showInWindow:self.window
                                          title:SNLocalized(@"composer.command.rename.title")
                                           text:nil
                                      accessory:field
                                   confirmTitle:SNLocalized(@"composer.command.rename.save")
                                         danger:NO
                                        perform:^(void (^finish)(NSString *)) {
                                            NSString *name = Trimmed(self.field.stringValue);
                                            [source renameConversation:conversationID to:name completion:^(NSString *error) {
                                                if (!error) return finish(nil);
                                                finish([error isEqualToString:@"name_taken"] ? SNLocalizedFormat(@"composer.command.rename.taken", name)
                                                       : [error hasPrefix:@"invalid_name"]   ? SNLocalized(@"composer.command.rename.special")
                                                                                             : SNLocalized(@"composer.command.rename.failed"));
                                            }];
                                        }];
    [self updateRenameButton];
    [field.window makeFirstResponder:field];
}

- (void)controlTextDidChange:(NSNotification *)notification { [self updateRenameButton]; }

// Save Changes waits for a name that differs from the channel's.
- (void)updateRenameButton {
    NSString *name = Trimmed(self.field.stringValue);
    self.dialog.confirmEnabled = name.length && ![name isEqualToString:self.currentName];
}

#pragma mark /archive

- (void)archive {
    SNConversation *conversation = self.here;
    if (!conversation || conversation.isDirect || conversation.isGeneral || conversation.isArchived || self.source.me.isRestricted)
        return [self say:SNLocalizedFormat(@"composer.command.unknown", self.cmd)];
    if (!self.window) return;
    id<SNSource> source = self.source;
    NSString *conversationID = conversation.conversationID;
    BOOL priv = conversation.kind == SNConversationPrivateChannel;
    [SNConfirmDialog showInWindow:self.window
                            title:SNLocalized(@"composer.command.archive.title")
                             text:SNLocalized(@"composer.command.archive.text")
                        accessory:nil
                     confirmTitle:SNLocalized(@"composer.command.archive.confirm")
                           danger:YES
                          perform:^(void (^finish)(NSString *)) {
                              [source archiveConversation:conversationID completion:^(NSString *error) { finish(error ? ArchiveRefusal(error, NO, priv) : nil); }];
                          }];
}

#pragma mark /collapse, /expand

// collapseCommand / expandCommand: every file, picture and video of the conversation (or the
// thread) as the column the command came from shows them; only a conversation says so.
- (void)setFilesExpanded:(BOOL)expanded {
    NSArray<SNMessage *> *messages = self.threadTS ? [self.source threadInConversation:self.conversationID ts:self.threadTS] : [self.source messagesInConversation:self.conversationID];
    NSString *viewContext = self.threadTS ? SNViewContextThread : SNViewContextChannel;
    NSMutableArray<NSString *> *keys = [NSMutableArray new];
    for (SNMessage *message in messages) [keys addObjectsFromArray:SNExpandableKeysOfMessage(message, viewContext)];
    [self.source setItems:keys expanded:expanded inMessages:messages];
    if (!self.threadTS)
        [self.source showCommandFeedback:SNLocalized(expanded ? @"composer.command.expand.done" : @"composer.command.collapse.done") inConversation:self.conversationID
                                threadTS:nil
                               temporary:NO];
}

#pragma mark s/old/new

/// "s/old/new/gi": whole words of the user's last message here, every match with g, any case with
/// i, saved with chat.update; nothing happens without a match.
- (BOOL)substituteIn:(NSString *)text {
    NSRegularExpression *pattern = [NSRegularExpression regularExpressionWithPattern:@"^/s/([^/]+)/([^/]*)(?:/([a-z]+)?)?$" options:0 error:nil];
    NSTextCheckingResult *match = [pattern firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
    if (!match) return NO;
    NSString *old = [text substringWithRange:[match rangeAtIndex:1]], *replacement = [text substringWithRange:[match rangeAtIndex:2]];
    NSString *flags = [match rangeAtIndex:3].location != NSNotFound ? [text substringWithRange:[match rangeAtIndex:3]] : @"";
    NSArray<SNMessage *> *messages = self.threadTS ? [self.source threadInConversation:self.conversationID ts:self.threadTS] : [self.source messagesInConversation:self.conversationID];
    SNMessage *last = nil;
    for (SNMessage *message in messages.reverseObjectEnumerator)
        if (SNMessageIsEditable(message, self.source)) {
            last = message;
            break;
        }
    if (!last.text.length) return YES;
    NSRegularExpressionOptions options = [flags containsString:@"i"] ? NSRegularExpressionCaseInsensitive : 0;
    NSRegularExpression *word = [NSRegularExpression regularExpressionWithPattern:[NSString stringWithFormat:@"\\b%@\\b", [NSRegularExpression escapedPatternForString:old]]
                                                                          options:options
                                                                            error:nil];
    NSString *template = [NSRegularExpression escapedTemplateForString:replacement];
    NSRange range = [flags containsString:@"g"] ? NSMakeRange(0, last.text.length) : [word rangeOfFirstMatchInString:last.text options:0 range:NSMakeRange(0, last.text.length)];
    if (range.location == NSNotFound) return YES;
    NSString *edited = [word stringByReplacingMatchesInString:last.text options:0 range:range withTemplate:template];
    if (![edited isEqualToString:last.text]) [self.source editMessage:last text:edited blocks:nil];
    return YES;
}

@end

@implementation SNSlashCommands {
    id<SNSource> _source;
}

- (instancetype)initWithSource:(id<SNSource>)source {
    if (!(self = [super init])) return nil;
    _source = source;
    return self;
}

- (void)run:(NSString *)typed
            rest:(NSAttributedString *)rest
  inConversation:(NSString *)conversationID
        threadTS:(NSString *)threadTS
          window:(NSWindow *)window
         restore:(void (^)(void))restore {
    [_source clearCommandFeedbackInConversation:conversationID threadTS:threadTS];
    SNCommandRun *run = [SNCommandRun new];
    run.source = _source;
    run.navigator = self.navigator;
    run.window = window;
    run.typed = typed;
    run.cmd = [typed.lowercaseString stringByReplacingOccurrencesOfString:@"’" withString:@"'"];
    run.conversationID = conversationID;
    run.threadTS = threadTS;
    run.rest = rest;
    run.params = SNSlashCommandParams(rest);
    run.restore = restore;
    run.openGifPicker = self.openGifPicker;
    NSString *line = rest.length ? [NSString stringWithFormat:@"%@ %@", typed, rest.string] : typed;
    if ([run substituteIn:line]) return;
    SNCommand *command = [_source commandNamed:typed];
    if (threadTS && command && !command.runsInThreads) return [run say:SNLocalizedFormat(@"composer.command.threads", run.cmd)];
    // Slack's client opens its Reminder dialog for /remind alone; with words it is Slack's own.
    if ([run.cmd isEqualToString:@"/remind"] && !run.params.count && window) {
        [SNReminderDialog showInWindow:window source:_source conversation:conversationID threadTS:threadTS now:self.clock ? self.clock() : NSDate.date];
        return;
    }
    if ([command.type isEqualToString:@"client"]) {
        run.name = command.name;
        return [run start];
    }
    [_source runCommand:typed blocks:SNRichMessageFromDocument(rest).blocks inConversation:conversationID threadTS:threadTS completion:^(BOOL keepInput) {
        if (keepInput) restore();
    }];
}

@end
