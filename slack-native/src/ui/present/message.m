// Owns the rules for what may be done with a message.
#import "ui/present/message.h"

BOOL SNMessageIsEditable(SNMessage *message, id<SNSource> source) {
    BOOL plain = !message.subtype || [message.subtype isEqualToString:@"thread_broadcast"];
    return plain && message.sendState == SNMessageSent && message.userID && [message.userID isEqualToString:source.me.userID];
}
