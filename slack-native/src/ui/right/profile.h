// Slack's member profile flexpane ("Perfil"), in the right column instead of a thread
// (SNPanelProfile()): the large picture, name, title, presence and local time, the buttons
// (message, huddle, VIP, more), then the contact information, recent DMs, About me and the
// workspace's own profile fields, scrolling as one column.
#import <AppKit/AppKit.h>

#import "source/source.h"
#import "ui/right/panels.h"

NS_ASSUME_NONNULL_BEGIN

@interface SNProfilePanel : NSView <SNPanelView>
- (instancetype)initWithUserID:(NSString *)userID source:(id<SNSource>)source close:(void (^)(void))close;
@property (nonatomic, readonly) NSString *userID;
/// The time shown as the user's local time; now unless set (snapshots fix it).
@property (nonatomic, copy, nullable) NSDate *date;
@end

NS_ASSUME_NONNULL_END
