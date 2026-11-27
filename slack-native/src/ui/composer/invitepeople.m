// Owns the invite dialog: its addresses, their checks, the request and the summary after it.
#import "render/strings.h"
#import "ui/composer/invitepeople.h"
#import "ui/kit/dialog.h"
#import "ui/kit/forms.h"

/// c-sk-modal--fixed: 520 wide; the addresses' box 80 tall (c-input_textarea).
static const CGFloat kWidth = 520, kInner = kWidth - 2 * 28, kBox = 80;
static const unsigned short kReturn = 36;

NSArray<NSString *> *SNInviteEmails(NSString *text) {
    NSMutableArray<NSString *> *emails = [NSMutableArray new];
    NSRegularExpression *separators = [NSRegularExpression regularExpressionWithPattern:@"\\s*,\\s*|\\s+" options:0 error:nil];
    NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *split = [separators stringByReplacingMatchesInString:trimmed options:0 range:NSMakeRange(0, trimmed.length) withTemplate:@"\n"];
    for (NSString *email in [split componentsSeparatedByString:@"\n"])
        if (email.length) [emails addObject:email];
    return emails;
}

static BOOL LooksLikeEmail(NSString *text) { return [text rangeOfString:@"^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$" options:NSRegularExpressionSearch].location != NSNotFound; }

/// xzuI's words for an invitation Slack refused.
static NSString *RefusalText(NSString *error) {
    if ([error isEqualToString:@"invalid_email"]) return SNLocalized(@"composer.invite.error.invalid");
    if ([error isEqualToString:@"already_in_team"]) return SNLocalized(@"composer.invite.error.member");
    if ([error isEqualToString:@"url_in_message"]) return SNLocalized(@"composer.invite.error.url");
    return SNLocalized(@"composer.invite.error.fatal");
}

@interface SNInviteForm : NSView
@end

@implementation SNInviteForm
- (BOOL)isFlipped { return YES; }
@end

@implementation SNInvitePeopleDialog {
    id<SNSource> _source;
    SNInviteForm *_form;
    SNFormInput *_emails;
    BOOL _done;
}

static SNInvitePeopleDialog *current;

+ (SNInvitePeopleDialog *)current { return current && current->_dialog == SNConfirmDialog.current ? current : nil; }

+ (instancetype)showInWindow:(NSWindow *)window source:(id<SNSource>)source emails:(NSArray<NSString *> *)emails {
    SNInvitePeopleDialog *invite = [self new];
    invite->_source = source;
    [invite buildWithEmails:emails];
    __weak SNInvitePeopleDialog *weakInvite = invite;
    NSString *title = SNLocalizedFormat(@"composer.invite.title", source.workspace.name ?: @"");
    invite->_dialog = [SNConfirmDialog showFormInWindow:window title:title accessory:invite->_form width:kWidth confirmTitle:SNLocalized(@"composer.invite.send") confirmed:^{}];
    if (!invite->_dialog) return nil;
    invite->_dialog.confirmAction = ^{ [weakInvite send]; };
    // Return in the addresses' box is a line of its own; Send is the button.
    invite->_dialog.passesKey = ^BOOL(NSEvent *event) {
        SNInvitePeopleDialog *dialog = weakInvite;
        return event.keyCode == kReturn && dialog && !dialog->_done && dialog->_emails.window.firstResponder == dialog->_emails.editor;
    };
    [invite update];
    [invite->_emails focus];
    current = invite;
    return invite;
}

/// The placeholder names the user's own domain, as Slack's does.
- (NSString *)placeholder {
    NSString *email = [_source.me.json[@"profile"] isKindOfClass:NSDictionary.class] ? _source.me.json[@"profile"][@"email"] : nil;
    NSRange at = [email isKindOfClass:NSString.class] ? [email rangeOfString:@"@"] : NSMakeRange(NSNotFound, 0);
    return SNLocalizedFormat(@"composer.invite.placeholder", at.location != NSNotFound ? [email substringFromIndex:NSMaxRange(at)] : @"example.com");
}

- (void)buildWithEmails:(NSArray<NSString *> *)emails {
    _form = [[SNInviteForm alloc] initWithFrame:NSMakeRect(0, 0, kInner, SNFormLabelLine + SNFormLabelGap + kBox)];
    NSView *label = SNFormLabel(SNLocalized(@"composer.invite.to"));
    label.frame = NSMakeRect(0, 0, kInner, SNFormLabelLine);
    _emails = [[SNFormInput alloc] initMultilineWithPlaceholder:self.placeholder height:kBox];
    _emails.frame = NSMakeRect(0, SNFormLabelLine + SNFormLabelGap, kInner, kBox);
    _emails.text = [emails componentsJoinedByString:@", "];
    __weak SNInvitePeopleDialog *weakSelf = self;
    _emails.changed = ^(NSString *text) { [weakSelf update]; };
    [_form addSubview:label];
    [_form addSubview:_emails];
}

- (NSString *)emailText { return _emails.text; }

- (void)setEmailText:(NSString *)emailText {
    _emails.text = emailText;
    [self update];
}

- (void)update {
    if (_done) return;
    _dialog.confirmEnabled = SNInviteEmails(_emails.text).count > 0;
}

- (void)send {
    if (_done) return [_dialog close];
    NSMutableArray<NSString *> *emails = [NSMutableArray new];
    for (NSString *email in SNInviteEmails(_emails.text)) {
        // The token field's own checks: each address once, and only addresses.
        if (!LooksLikeEmail(email)) return [_dialog showError:SNLocalizedFormat(@"composer.invite.error.token", email)];
        if (![emails containsObject:email.lowercaseString]) [emails addObject:email.lowercaseString];
    }
    if (!emails.count) return;
    _dialog.waiting = YES;
    __weak SNInvitePeopleDialog *weakSelf = self;
    [_source invitePeopleByEmail:emails channels:@[] message:nil completion:^(NSDictionary<NSString *, id> *results, NSString *error) {
        SNInvitePeopleDialog *invite = weakSelf;
        if (!invite) return;
        invite->_dialog.waiting = NO;
        if (!results) return [invite->_dialog showError:RefusalText(error)];
        [invite showSummary:results emails:emails];
    }];
}

/// The SUMMARY view: who was invited, and the addresses that were not with why.
- (void)showSummary:(NSDictionary<NSString *, id> *)results emails:(NSArray<NSString *> *)emails {
    _done = YES;
    NSMutableArray<NSString *> *refused = [NSMutableArray new];
    NSUInteger sent = 0;
    for (NSString *email in emails) {
        id outcome = results[email] ?: NSNull.null;
        if (outcome == NSNull.null) sent++;
        else [refused addObject:[NSString stringWithFormat:@"%@ — %@", email, RefusalText(outcome)]];
    }
    NSString *title = refused.count ? SNLocalized(@"composer.invite.someFailed")
                                    : SNLocalizedFormat(sent == 1 ? @"composer.invite.sent.one" : @"composer.invite.sent.other", @(sent));
    NSString *text = refused.count ? [[@[ SNLocalized(@"composer.invite.errors") ] arrayByAddingObjectsFromArray:refused] componentsJoinedByString:@"\n"] : nil;
    [_dialog showStepTitled:title text:text accessory:nil confirmTitle:SNLocalized(@"composer.invite.done") cancelTitle:nil];
    _dialog.confirmEnabled = YES;
}

@end
