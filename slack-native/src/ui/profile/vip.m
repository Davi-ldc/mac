// Owns who can be a VIP and the toggle's answers.
#import "model/json.h"
#import "render/strings.h"
#import "ui/profile/toast.h"
#import "ui/profile/vip.h"

/// PriorityToast shows 3 s; PriorityErrorToast takes the toast's default 6 s.
static const NSTimeInterval kToastDuration = 3, kErrorToastDuration = 6;

BOOL SNCanToggleVIP(id<SNSource> source, SNUser *user) {
    return source.offersVIPs && ![user.userID isEqualToString:source.me.userID] && !user.deleted && !SNJSONBool(user.json, @"is_agentforce_bot");
}

BOOL SNIsVIP(id<SNSource> source, NSString *userID) { return [source.vipUserIDs containsObject:userID]; }

void SNToggleVIP(id<SNSource> source, SNUser *user, NSWindow *window) {
    BOOL was = SNIsVIP(source, user.userID);
    NSString *name = user.visibleName;
    __weak NSWindow *weakWindow = window;
    [source setUser:user.userID VIP:!was completion:^(NSString *error, NSInteger limit) {
        NSWindow *shown = weakWindow;
        if (!shown) return;
        if (!error) {
            [SNToast showText:SNLocalizedFormat(was ? @"profile.vip.removed" : @"profile.vip.added", name) icon:@"check-circle" duration:kToastDuration inWindow:shown];
            return;
        }
        // Slack explains only an addition it refused; a removal failing or no answer show nothing.
        if (was || !error.length) return;
        NSString *text = [error isEqualToString:@"user_not_found"] ? SNLocalized(@"profile.vip.ineligible")
                         : [error isEqualToString:@"too_many_vips"] ? [SNLocalizedFormat(@"profile.vip.tooMany", name) stringByReplacingOccurrencesOfString:@"{max}" withString:@(limit).stringValue]
                                                                     : SNLocalized(@"profile.vip.failed");
        [SNToast showText:text icon:@"warning" duration:kErrorToastDuration inWindow:shown];
    }];
}
