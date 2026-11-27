// Raycast's inline calculator: what a root search query computes to, and the words its card
// shows around the answer.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface DKCalculation : NSObject
/// The query as typed.
@property(readonly) NSString *query;
/// The query as the card writes it, with "×", "÷" and "−" for the operators typed as "*",
/// "/" and "-".
@property(readonly) NSString *expression;
/// Ranges of `expression` that the card draws brighter than the rest: numbers, units,
/// currencies, percent signs, dates and places.
@property(readonly) NSArray<NSValue *> *highlights;
@property(readonly) NSString *answer;
/// The answer's bare number ("6.2137119223733395" for "6,2137119224 mi"), nil when it is
/// the answer itself.
@property(readonly, nullable) NSString *unformattedAnswer;
/// Under the expression and under the answer: "Sum" and "Three", "Kilometers" and "Miles".
@property(readonly) NSString *expressionLabel, *answerLabel;
/// The query with its units the other way around, for Swap Units; nil without units.
@property(readonly, nullable) NSString *swappedQuery;
/// The answer came from exchange rates.
@property(readonly) BOOL usesCurrency;
/// The same answer for a query typed on past this one, written as typed, without
/// highlights.
- (DKCalculation *)calculationForQuery:(NSString *)query;
@end

/// The calculation for a root search query, or nil when the query is not one. Numbers are
/// read and written with `locale`'s separators, currencies converted with `rates` (units per
/// US dollar) and times given in `timeZone` as of `now`.
DKCalculation *_Nullable DKCalculate(NSString *query, NSLocale *locale, NSDictionary<NSString *, NSDecimalNumber *> *rates,
                                     NSTimeZone *timeZone, NSDate *now);

NS_ASSUME_NONNULL_END
