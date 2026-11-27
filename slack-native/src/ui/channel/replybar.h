// The thread reply bar under a parent message (components.json thread_reply_bar, effects.txt
// [B6], measured live): up to five 24 pt avatars and "17 respostas" in 13 pt bold #2ba5ce. At
// rest that is all; hovering the bar itself fades in a #1a1d21 fill, a 1 pt #35373b border, a
// #818385 caret and "Última resposta há 2 dias", 160 ms ease-out both ways. Hovering the row
// leaves it alone.
#import "source/source.h"
#import "ui/kit/hoverview.h"

NS_ASSUME_NONNULL_BEGIN

@interface SNReplyBar : SNHoverView
- (instancetype)initWithMessage:(SNMessage *)message source:(id<SNSource>)source now:(NSDate *)now;
@end

NS_ASSUME_NONNULL_END
