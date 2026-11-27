// Reaction pills (components.json reactions, effects.txt [B5], measured live): 24 pt tall,
// fully rounded, a 16 pt emoji and the count in 12 pt on #f8f8f8 at 6%; the user's own reaction
// filled #0a77a7 with a bold count. Hover: no fill and a 1 pt #797c81 ring, at once; press:
// scale 0.94. After ~300 ms a tooltip shows the emoji on a white tile and who reacted. The
// add-reaction pill has the same shape with a smiley that turns #f8f8f8 under the pointer.
#import "source/source.h"
#import "ui/kit/hoverview.h"

NS_ASSUME_NONNULL_BEGIN

@interface SNReactionPill : SNHoverView
/// A reaction pill; nil `reaction` makes the add-reaction pill.
- (instancetype)initWithReaction:(nullable SNReaction *)reaction source:(id<SNSource>)source;
@property (nonatomic, readonly, nullable) SNReaction *reaction;
/// The user is among those who reacted.
@property (nonatomic, readonly) BOOL mine;
@end

/// The reaction tooltip's text: "Ana, Bruno e você reagiram com :tada:".
NSString *SNReactionTooltipText(SNReaction *reaction, id<SNSource> source);

NS_ASSUME_NONNULL_END
