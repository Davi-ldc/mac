// The Preferences' VIP list (Slack's VipListPref): the search that adds people, apps and workflows,
// "Added to your VIP list" with each VIP by name and its Remove, and up to six "Recommended" people
// (users.priority.getRecommendations) with Add. Every change goes through the VIP toggle and its
// toasts (ui/profile/vip.h).
#import <AppKit/AppKit.h>

#import "source/source.h"

NS_ASSUME_NONNULL_BEGIN

@interface SNPrefsVIPList : NSView
- (instancetype)initWithSource:(id<SNSource>)source;
- (CGFloat)heightForWidth:(CGFloat)width;
/// After the rows changed and with them the height.
@property (nonatomic, copy, nullable) void (^heightChanged)(void);
/// The headers and rows as shown, a row as "name: button" (tests).
@property (nonatomic, readonly) NSArray<NSString *> *texts;
/// Clicks the button of the row of `userID` (tests).
- (void)clickButtonOfUser:(NSString *)userID;
/// Chooses `userID` in the search as a click on its suggestion would (tests).
- (void)choose:(NSString *)userID;
@end

NS_ASSUME_NONNULL_END
