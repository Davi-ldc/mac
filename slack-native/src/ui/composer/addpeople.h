// Slack's add-people dialogs, as /invite opens them where it does not invite at once:
// - a private channel: first "Anyone you add will be able to see all of the channel's contents"
//   (the version without "Create a new channel"), then "Add people to <channel>", whose Add
//   invites everyone chosen at once (conversations.invite, force) and keeps the ones Slack
//   refused, saying why;
// - a DM or group DM: "Add people to this conversation" (9 people at most, the user included),
//   then "Include conversation history?", whose Done makes a new group DM
//   (conversations.createChild) and opens it.
#import <AppKit/AppKit.h>

#import "source/source.h"
#import "ui/shell/pane.h"

NS_ASSUME_NONNULL_BEGIN

@class SNConfirmDialog, SNPeoplePicker;

/// conversations.createChild's history choices.
typedef NS_ENUM(NSInteger, SNGroupHistory) {
    SNGroupHistoryNone,
    SNGroupHistoryToday,
    SNGroupHistoryAll,
    SNGroupHistoryCustom,
};

@interface SNAddPeopleDialog : NSObject
+ (nullable instancetype)showForChannel:(SNConversation *)channel users:(NSArray<NSString *> *)userIDs inWindow:(NSWindow *)window source:(id<SNSource>)source;
+ (nullable instancetype)showForConversation:(SNConversation *)conversation
                                       users:(NSArray<NSString *> *)userIDs
                                    inWindow:(NSWindow *)window
                                      source:(id<SNSource>)source
                                   navigator:(nullable id<SNNavigator>)navigator;
+ (nullable SNAddPeopleDialog *)current;
@property (nonatomic, readonly) SNConfirmDialog *dialog;
@property (nonatomic, readonly) SNPeoplePicker *picker;
/// The group DM's history choice and its custom day.
@property (nonatomic) SNGroupHistory history;
@property (nonatomic) NSDate *historyDay;
/// The step's confirm button: Continue (the channel prompt), Add, Next, Done.
- (void)confirm;
@end

/// What the group DM dialogs say "Ana and Bia" or "Ana, Bia, and 2 others" with.
NSString *SNListOfNames(NSArray<NSString *> *names);

NS_ASSUME_NONNULL_END
