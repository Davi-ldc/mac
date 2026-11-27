// Owns the user's collapse and expand choices for message items, kept per item on this device as
// Slack's client keeps its expandables store (persisted locally, never sent to Slack).
#import "store/internal.h"

// Implements part of SNSource, which the primary class adopts (see internal.h).
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

@implementation SNStore (Expandables)

- (NSNumber *)expandedStateOfItem:(NSString *)key { return self.expandables[key]; }

- (void)setItems:(NSArray<NSString *> *)keys expanded:(BOOL)expanded inMessages:(NSArray<SNMessage *> *)messages {
    if (!keys.count) return;
    [self performChanges:^{
        for (NSString *key in keys) {
            if ([self.expandables[key] isEqual:@(expanded)]) continue;
            self.expandables[key] = @(expanded);
            [self.database setJSON:@(expanded) forKey:[SNExpandablePrefix stringByAppendingString:key]];
        }
        for (SNMessage *message in messages) {
            if (!message.conversationID) continue;
            [self changed:SNChangeMessages value:message.conversationID];
            if (message.threadTS) [self changed:SNChangeThreads value:SNThreadKey(message.conversationID, message.threadTS)];
            [self changed:SNChangeMessageKeys value:SNMessageKey(message)];
        }
    }];
}

@end
