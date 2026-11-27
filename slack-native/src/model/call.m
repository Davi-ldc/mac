// Owns the call snapshot.
#import "model/call.h"

@implementation SNCall

- (instancetype)initWithConversationID:(NSString *)conversationID
                              huddleID:(NSString *)huddleID
                                 state:(SNCallState)state
                                 muted:(BOOL)muted
                              speaking:(NSSet<NSString *> *)speaking
                            mutedUsers:(NSSet<NSString *> *)mutedUsers {
    if (!(self = [super init])) return nil;
    _conversationID = [conversationID copy];
    _huddleID = [huddleID copy];
    _state = state;
    _muted = muted;
    _speakingUserIDs = [speaking copy];
    _mutedUserIDs = [mutedUsers copy];
    return self;
}

@end
