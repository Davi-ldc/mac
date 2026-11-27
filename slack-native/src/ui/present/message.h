// What the UI offers to do with a message, the same in every column and command.
#import <Foundation/Foundation.h>

#import "source/source.h"

NS_ASSUME_NONNULL_BEGIN

/// Whether the user may edit or delete `message`: their own, on Slack, not a join or leave.
BOOL SNMessageIsEditable(SNMessage *message, id<SNSource> source);

NS_ASSUME_NONNULL_END
