// The calculator's row in the launcher: the card for a query and what it can do.
#import "picker.h"

NS_ASSUME_NONNULL_BEGIN

/// The calculator card for a root search query, or nil when the query is no calculation.
/// While typing on past a valid query with what does not read yet ("2+3*("), the card keeps
/// the last answer, as Raycast's does.
DKItem *_Nullable DKCalculatorItem(DKPicker *picker, NSString *query);
/// Sets up what the first calculation would, so that it costs no more than the next.
void DKWarmCalculator(void);

NS_ASSUME_NONNULL_END
