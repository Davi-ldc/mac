// Owns the source's side of the user's call: it hands requests to the call controller and
// announces its changes.
#import "store/internal.h"

// Implements part of SNSource, which the primary class adopts (see internal.h).
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

@implementation SNStore (Calls)

- (BOOL)canJoinHuddles { return self.callController.makeMedia != nil; }
- (SNCall *)call { return self.callController.call; }

- (void)joinHuddleInConversation:(NSString *)conversationID {
    if (!self.canJoinHuddles) return;
    SNHuddle *huddle = [self huddleInConversation:conversationID];
    if (huddle.isActive) [self.callController joinHuddle:huddle inConversation:conversationID];
    // Slack's client starts a huddle with the microphone on unless huddles_mute_by_default.
    else if ([self conversationWithID:conversationID]) [self.callController startHuddleInConversation:conversationID muted:SNPreferenceBool(self.preferences, @"huddles_mute_by_default", NO)];
}

- (void)setCallMuted:(BOOL)muted { [self.callController setMuted:muted]; }
- (void)leaveCall { [self.callController leave]; }

- (void)callChanged {
    [self performChanges:^{ [self changed:SNChangeCall value:nil]; }];
}

@end
