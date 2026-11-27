// The user's own call from this Mac: a snapshot of the huddle it is in (audio only), as the call
// controller (src/call) reports it through the source.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SNCallState) {
    /// Region lookup, rooms.join, signalling and media negotiation.
    SNCallJoining,
    /// Audio flows.
    SNCallConnected,
    /// The media or signalling connection dropped and is being restored.
    SNCallReconnecting,
    /// Signalling leave and rooms.leave are on their way.
    SNCallLeaving,
};

@interface SNCall : NSObject
@property (nonatomic, readonly) NSString *conversationID;
/// The room's ID; nil until rooms.join answers.
@property (nonatomic, readonly, nullable) NSString *huddleID;
@property (nonatomic, readonly) SNCallState state;
/// The user's microphone is muted (it starts so).
@property (nonatomic, readonly) BOOL muted;
/// People heard now, and people whose microphone is muted, by user ID (the user included).
@property (nonatomic, readonly) NSSet<NSString *> *speakingUserIDs, *mutedUserIDs;
- (instancetype)initWithConversationID:(NSString *)conversationID
                              huddleID:(nullable NSString *)huddleID
                                 state:(SNCallState)state
                                 muted:(BOOL)muted
                              speaking:(NSSet<NSString *> *)speaking
                            mutedUsers:(NSSet<NSString *> *)mutedUsers;
@end

NS_ASSUME_NONNULL_END
