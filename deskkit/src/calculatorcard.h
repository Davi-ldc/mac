// Raycast's calculator card: the expression and the answer side by side with an arrow
// between them, each over a small label.
#import <AppKit/AppKit.h>

#import "calculator.h"

NS_ASSUME_NONNULL_BEGIN

/// The card's height in the list.
static const CGFloat DKCalculatorCardHeight = 124;

@interface DKCalculatorCard : NSTableCellView
/// `note` goes under the arrow: when currency rates were updated.
- (void)showCalculation:(DKCalculation *)calculation note:(nullable NSString *)note;
/// The arrow and the divider brighten on the selected card.
@property(nonatomic) BOOL selected;
@end

NS_ASSUME_NONNULL_END
