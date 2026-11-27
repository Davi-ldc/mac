// Slack's "Invite people to <workspace>" dialog (/invite_people), its smallest form: "To:" with the
// addresses (those typed after the command already in it; commas or spaces between them), then
// Send, which invites them as members (users.admin.inviteBulk) and shows how it went: "You've
// invited N people", or the addresses Slack refused, each with why. Slack's guest choices, channels
// and message are not offered here.
#import <AppKit/AppKit.h>

#import "source/source.h"

NS_ASSUME_NONNULL_BEGIN

@class SNConfirmDialog;

@interface SNInvitePeopleDialog : NSObject
+ (nullable instancetype)showInWindow:(NSWindow *)window source:(id<SNSource>)source emails:(NSArray<NSString *> *)emails;
+ (nullable SNInvitePeopleDialog *)current;
@property (nonatomic, readonly) SNConfirmDialog *dialog;
/// The addresses as typed in To (tests).
@property (nonatomic, copy) NSString *emailText;
- (void)send;
@end

/// The addresses in what was typed: split at commas and white space, as F6WW splits them.
NSArray<NSString *> *SNInviteEmails(NSString *text);

NS_ASSUME_NONNULL_END
