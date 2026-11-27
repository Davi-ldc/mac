// The workspace and Slack itself: feedback and invitations.
#import <Foundation/Foundation.h>

#import "model/workspace.h"

NS_ASSUME_NONNULL_BEGIN

@protocol SNSlackSource <NSObject>
@property (nonatomic, readonly) SNWorkspace *workspace;
/// The Feedback panel's Send (feedback.submitFeedback, without attachments). `completion` gets nil
/// or the error.
- (void)submitFeedback:(NSString *)text completion:(nullable void (^)(NSString *_Nullable error))completion;
/// The invite dialog's Send (users.admin.inviteBulk): workspace members by email, with the
/// channels to add them to and the message. `completion` gets each email's error (nil for an
/// invitation sent), or the request's own error.
- (void)invitePeopleByEmail:(NSArray<NSString *> *)emails
                   channels:(NSArray<NSString *> *)channelIDs
                    message:(nullable NSString *)message
                 completion:(void (^)(NSDictionary<NSString *, id> *_Nullable results, NSString *_Nullable error))completion;
@end

NS_ASSUME_NONNULL_END
