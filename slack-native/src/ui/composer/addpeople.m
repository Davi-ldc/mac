// Owns the add-people dialogs: their steps, the people picker's rules and the requests they make.
#import "render/strings.h"
#import "ui/composer/addpeople.h"
#import "ui/kit/dialog.h"
#import "ui/kit/forms.h"
#import "ui/kit/label.h"
#import "ui/kit/people.h"
#import "ui/present/names.h"

/// c-sk-modal--fixed.
static const CGFloat kWidth = 520, kInner = kWidth - 2 * 28;
/// A group DM holds 9 people, the user included (MAX_MPDM_MEMBERS).
static const NSUInteger kGroupLimit = 9;
static const CGFloat kRadioLine = 22, kRadioGap = 12, kNoteGap = 8;
/// conversations.createChild's "from the beginning".
static NSString *const kHistoryAll = @"0000000000.000001";

typedef NS_ENUM(NSInteger, SNAddPeopleStep) {
    SNAddPeopleStepPrompt,
    SNAddPeopleStepPick,
    SNAddPeopleStepHistory,
    SNAddPeopleStepConfirmAll,
};

NSString *SNListOfNames(NSArray<NSString *> *names) {
    if (names.count <= 1) return names.firstObject ?: @"";
    if (names.count == 2) return SNLocalizedFormat(@"composer.people.two", names[0], names[1]);
    if (names.count == 3) return SNLocalizedFormat(@"composer.people.three", names[0], names[1], names[2]);
    return SNLocalizedFormat(@"composer.people.more", names[0], names[1], @(names.count - 2));
}

/// getInviteErrorText for the add-people dialog's refusals, `count` people sharing it.
static NSString *InviteErrorText(NSString *error, NSUInteger count) {
    BOOL many = count > 1;
    if ([error isEqualToString:@"cant_invite"]) return SNLocalized(many ? @"composer.addPeople.error.cantInvite.other" : @"composer.addPeople.error.cantInvite.one");
    if ([error isEqualToString:@"user_is_restricted"]) return SNLocalized(many ? @"composer.addPeople.error.guest.other" : @"composer.addPeople.error.guest.one");
    if ([error isEqualToString:@"not_enough_channels"]) return SNLocalized(@"composer.addPeople.error.singleGuest");
    if ([error isEqualToString:@"user_not_found"]) return SNLocalized(@"composer.addPeople.error.userNotFound");
    if ([error isEqualToString:@"channel_not_found"] || [error isEqualToString:@"method_not_supported_for_channel_type"]) return SNLocalized(@"composer.command.channelRequired");
    if ([error isEqualToString:@"no_permission"]) return SNLocalized(@"composer.addPeople.error.noPermission");
    if ([error isEqualToString:@"not_owner"]) return SNLocalized(@"composer.addPeople.error.notOwner");
    if ([error isEqualToString:@"too_many_users"]) return SNLocalized(@"composer.addPeople.error.tooManyUsers");
    if ([error isEqualToString:@"too_many_members"]) return SNLocalized(@"composer.addPeople.error.full");
    return nil;
}

/// A step's fields, stacked top-down.
@interface SNAddPeopleForm : NSView
@end

@implementation SNAddPeopleForm
- (BOOL)isFlipped { return YES; }
@end

@implementation SNAddPeopleDialog {
    id<SNSource> _source;
    __weak id<SNNavigator> _navigator;
    SNConversation *_conversation;
    BOOL _group;
    SNAddPeopleStep _step;
    NSArray<NSString *> *_members;
    SNAddPeopleForm *_pickForm, *_historyForm;
    NSView *_subtext;
    NSArray<SNFormRadio *> *_radios;
    SNFormDatePicker *_day;
}

static SNAddPeopleDialog *current;

+ (SNAddPeopleDialog *)current { return current && current->_dialog == SNConfirmDialog.current ? current : nil; }

+ (instancetype)showForChannel:(SNConversation *)channel users:(NSArray<NSString *> *)userIDs inWindow:(NSWindow *)window source:(id<SNSource>)source {
    SNAddPeopleDialog *add = [self new];
    add->_source = source;
    add->_conversation = channel;
    [add buildPickerWithPlaceholder:SNLocalized(@"composer.addPeople.placeholder") rowHeight:32 users:userIDs];
    BOOL prompt = channel.kind == SNConversationPrivateChannel;
    return [add showInWindow:window step:prompt ? SNAddPeopleStepPrompt : SNAddPeopleStepPick];
}

+ (instancetype)showForConversation:(SNConversation *)conversation
                              users:(NSArray<NSString *> *)userIDs
                           inWindow:(NSWindow *)window
                             source:(id<SNSource>)source
                          navigator:(id<SNNavigator>)navigator {
    SNAddPeopleDialog *add = [self new];
    add->_source = source;
    add->_navigator = navigator;
    add->_conversation = conversation;
    add->_group = YES;
    NSMutableArray<NSString *> *members = [NSMutableArray arrayWithObject:source.me.userID ?: @""];
    for (SNUser *user in SNConversationPeople(conversation, source)) [members addObject:user.userID];
    if (conversation.userID && ![members containsObject:conversation.userID]) [members addObject:conversation.userID];
    add->_members = members;
    add->_history = SNGroupHistoryToday;
    add->_historyDay = NSDate.date;
    [add buildPickerWithPlaceholder:SNLocalized(@"composer.addPeople.group.placeholder") rowHeight:28 users:userIDs];
    add->_picker.limit = 10;
    add->_picker.maximum = kGroupLimit > members.count ? kGroupLimit - members.count : 0;
    return [add showInWindow:window step:SNAddPeopleStepPick];
}

- (instancetype)showInWindow:(NSWindow *)window step:(SNAddPeopleStep)step {
    __weak SNAddPeopleDialog *weakSelf = self;
    _dialog = [SNConfirmDialog showFormInWindow:window title:@"" accessory:_pickForm width:kWidth confirmTitle:@"" confirmed:^{}];
    if (!_dialog) return nil;
    _dialog.confirmAction = ^{ [weakSelf confirm]; };
    _dialog.cancelAction = ^{ [weakSelf back]; };
    [self showStep:step];
    current = self;
    return self;
}

- (void)buildPickerWithPlaceholder:(NSString *)placeholder rowHeight:(CGFloat)rowHeight users:(NSArray<NSString *> *)userIDs {
    _pickForm = [[SNAddPeopleForm alloc] initWithFrame:NSMakeRect(0, 0, kInner, 44)];
    _picker = [[SNPeoplePicker alloc] initWithSource:_source placeholder:placeholder rowHeight:rowHeight];
    _picker.frame = NSMakeRect(0, 0, kInner, 44);
    __weak SNAddPeopleDialog *weakSelf = self;
    _picker.unavailableReason = ^NSString *(SNUser *user) {
        SNAddPeopleDialog *add = weakSelf;
        return add && [add->_members containsObject:user.userID] ? SNLocalized(@"composer.addPeople.group.already") : nil;
    };
    _picker.changed = ^{ [weakSelf updateButton]; };
    _picker.heightChanged = ^{ [weakSelf layoutPickForm]; };
    _picker.userIDs = userIDs;
    [_pickForm addSubview:_picker];
    if (_group) {
        SNLabel *subtext = [SNLabel labelWithText:SNLocalizedFormat(@"composer.addPeople.group.limit", @(kGroupLimit)) font:SNFont(SNFontSizeCaption, SNFontWeightRegular)
                                            color:SNColorContentSec];
        subtext.lineHeight = 18;
        _subtext = subtext;
        [_pickForm addSubview:subtext];
    }
    [self layoutPickForm];
}

- (void)layoutPickForm {
    CGFloat height = _picker.preferredHeight;
    _picker.frame = NSMakeRect(0, 0, kInner, height);
    _subtext.frame = NSMakeRect(0, height + kNoteGap, kInner, 18);
    [_pickForm setFrameSize:NSMakeSize(kInner, _subtext ? NSMaxY(_subtext.frame) : height)];
    [_dialog accessoryHeightChanged];
}

- (void)buildHistoryForm {
    _historyForm = [[SNAddPeopleForm alloc] initWithFrame:NSZeroRect];
    NSArray *keys = @[ @"composer.addPeople.history.none", @"composer.addPeople.history.today", @"composer.addPeople.history.all", @"composer.addPeople.history.custom" ];
    NSMutableArray<SNFormRadio *> *radios = [NSMutableArray new];
    __weak SNAddPeopleDialog *weakSelf = self;
    CGFloat y = 0;
    for (NSUInteger i = 0; i < keys.count; i++) {
        SNFormRadio *radio = [[SNFormRadio alloc] initWithTitle:SNLocalized(keys[i])];
        radio.frame = NSMakeRect(0, y, kInner, kRadioLine);
        radio.action = ^(SNFormRadio *chosen) { weakSelf.history = (SNGroupHistory)i; };
        [radios addObject:radio];
        [_historyForm addSubview:radio];
        y += kRadioLine + kRadioGap;
        if (i == SNGroupHistoryCustom) {
            _day = [[SNFormDatePicker alloc] initWithFrame:NSMakeRect(22, y - kRadioGap + 8, kInner - 22, SNFormControlHeight)];
            _day.date = _historyDay;
            _day.maximumDate = NSDate.date;
            _day.changed = ^(NSDate *day) { weakSelf.historyDay = day; };
            [_historyForm addSubview:_day];
            y = NSMaxY(_day.frame) + 16;
        }
    }
    _radios = radios;
    SNLabel *note = [SNLabel labelWithText:SNLocalized(@"composer.addPeople.history.note") font:SNFont(SNFontSizeCaption, SNFontWeightRegular) color:SNColorContentSec];
    note.lineHeight = 18;
    note.frame = NSMakeRect(0, y, kInner, 18);
    [_historyForm addSubview:note];
    _historyForm.frame = NSMakeRect(0, 0, kInner, NSMaxY(note.frame));
    [self setHistory:_history];
}

- (void)setHistory:(SNGroupHistory)history {
    _history = history;
    for (NSUInteger i = 0; i < _radios.count; i++) _radios[i].checked = (NSInteger)i == history;
    _day.enabled = history == SNGroupHistoryCustom;
    _day.alphaValue = _day.enabled ? 1 : 0.5;
}

#pragma mark Steps

- (NSString *)channelLabel { return _conversation.kind == SNConversationPrivateChannel ? _conversation.name : [@"#" stringByAppendingString:_conversation.name]; }

- (void)showStep:(SNAddPeopleStep)step {
    _step = step;
    switch (step) {
    case SNAddPeopleStepPrompt:
        [_dialog showStepTitled:SNLocalized(@"composer.addPeople.prompt.title") text:SNLocalizedFormat(@"composer.addPeople.prompt.text", _conversation.name) accessory:nil
                   confirmTitle:SNLocalized(@"composer.addPeople.prompt.confirm")
                    cancelTitle:nil];
        _dialog.confirmEnabled = YES;
        return;
    case SNAddPeopleStepPick:
        [_dialog showStepTitled:_group ? SNLocalized(@"composer.addPeople.group.title") : SNLocalizedFormat(@"composer.addPeople.title", self.channelLabel) text:nil accessory:_pickForm
                   confirmTitle:SNLocalized(_group ? @"composer.addPeople.group.next" : @"composer.addPeople.add")
                    cancelTitle:nil];
        [self layoutPickForm];
        [self updateButton];
        [_picker focus];
        return;
    case SNAddPeopleStepHistory: {
        if (!_historyForm) [self buildHistoryForm];
        NSMutableArray<NSString *> *names = [NSMutableArray new];
        for (NSString *userID in _picker.userIDs) [names addObject:[_source userWithID:userID].visibleName ?: userID];
        [names sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
        [_dialog showStepTitled:SNLocalized(@"composer.addPeople.history.title") text:SNLocalizedFormat(@"composer.addPeople.history.text", SNListOfNames(names)) accessory:_historyForm
                   confirmTitle:SNLocalized(@"composer.addPeople.history.done")
                    cancelTitle:SNLocalized(@"composer.addPeople.history.back")];
        _dialog.confirmEnabled = YES;
        return;
    }
    case SNAddPeopleStepConfirmAll:
        [_dialog showStepTitled:SNLocalized(@"composer.addPeople.all.title") text:SNLocalized(@"composer.addPeople.all.text") accessory:nil
                   confirmTitle:SNLocalized(@"composer.addPeople.all.confirm")
                    cancelTitle:SNLocalized(@"composer.addPeople.all.back")];
        _dialog.confirmEnabled = YES;
        return;
    }
}

- (void)updateButton {
    if (_step == SNAddPeopleStepPick) _dialog.confirmEnabled = _picker.userIDs.count > 0;
}

- (void)back {
    if (_step == SNAddPeopleStepHistory) return [self showStep:SNAddPeopleStepPick];
    if (_step == SNAddPeopleStepConfirmAll) return [self showStep:SNAddPeopleStepHistory];
    [_dialog cancel];
}

- (void)confirm {
    switch (_step) {
    case SNAddPeopleStepPrompt: return [self showStep:SNAddPeopleStepPick];
    case SNAddPeopleStepPick:
        if (!_picker.userIDs.count) return;
        return _group ? [self showStep:SNAddPeopleStepHistory] : [self addToChannel];
    case SNAddPeopleStepHistory:
        if (_history == SNGroupHistoryAll) return [self showStep:SNAddPeopleStepConfirmAll];
        return [self createGroup];
    case SNAddPeopleStepConfirmAll: return [self createGroup];
    }
}

#pragma mark Requests

- (void)addToChannel {
    NSArray<NSString *> *userIDs = _picker.userIDs;
    _dialog.waiting = YES;
    __weak SNAddPeopleDialog *weakSelf = self;
    [_source addUsers:userIDs toChannel:_conversation.conversationID completion:^(NSDictionary<NSString *, NSString *> *refused, NSString *error) {
        SNAddPeopleDialog *add = weakSelf;
        if (!add) return;
        add->_dialog.waiting = NO;
        if (!refused.count) return [add->_dialog close];
        // The ones added leave the field; the refused stay with why.
        NSMutableArray<NSString *> *left = [NSMutableArray new];
        for (NSString *userID in userIDs)
            if (refused[userID]) [left addObject:userID];
        add->_picker.userIDs = left;
        NSSet *reasons = [NSSet setWithArray:refused.allValues];
        NSString *text = reasons.count == 1 ? InviteErrorText(reasons.anyObject, refused.count) : nil;
        if (!text && error.length && !reasons.count) text = SNLocalized(@"composer.command.failed");
        [add->_dialog showError:text ?: SNLocalizedFormat(refused.count == 1 ? @"composer.addPeople.error.some.one" : @"composer.addPeople.error.some.other", @(refused.count))];
    }];
}

- (NSString *)historyStart {
    NSCalendar *calendar = NSCalendar.currentCalendar;
    switch (_history) {
    case SNGroupHistoryNone: return nil;
    case SNGroupHistoryToday: return @((long long)[calendar startOfDayForDate:NSDate.date].timeIntervalSince1970).stringValue;
    case SNGroupHistoryAll: return kHistoryAll;
    case SNGroupHistoryCustom: return @((long long)[calendar startOfDayForDate:_historyDay].timeIntervalSince1970).stringValue;
    }
    return nil;
}

- (void)createGroup {
    _dialog.waiting = YES;
    __weak SNAddPeopleDialog *weakSelf = self;
    [_source createGroupFromConversation:_conversation.conversationID addingUsers:_picker.userIDs historyFrom:self.historyStart completion:^(NSString *conversationID, NSString *error) {
        SNAddPeopleDialog *add = weakSelf;
        if (!add) return;
        add->_dialog.waiting = NO;
        if (!conversationID) {
            BOOL tooMany = [error isEqualToString:@"too_many_messages"];
            return [add->_dialog showError:SNLocalized(tooMany ? @"composer.addPeople.error.tooManyMessages" : @"composer.addPeople.error.group")];
        }
        [add->_dialog close];
        [add->_navigator openConversation:conversationID];
    }];
}

@end
