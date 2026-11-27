// The calculator's numbers: exact decimals where they fit and doubles beyond, and the ways
// Raycast writes them out.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef struct {
    /// The value, always set: the decimal's value when there is one.
    double value;
    /// NSDecimal keeps 38 digits, so that 0.1 + 0.2 is 0.3 and 1234567.89 × 3.7 is
    /// 4567901.193, as Raycast's decimal arithmetic has them.
    NSDecimal decimal;
    /// NO beyond the decimal's range (about 10^±127), and for infinities and NaN.
    BOOL exact;
} DKNumber;

DKNumber DKNumberFromDouble(double value);
DKNumber DKNumberFromDecimal(NSDecimal decimal);
/// `digits` as written in C: "12.5", "1e-3".
DKNumber DKNumberFromString(NSString *digits);
DKNumber DKNumberAdd(DKNumber a, DKNumber b);
DKNumber DKNumberSubtract(DKNumber a, DKNumber b);
DKNumber DKNumberMultiply(DKNumber a, DKNumber b);
/// The caller rules out a zero divisor.
DKNumber DKNumberDivide(DKNumber a, DKNumber b);
DKNumber DKNumberPower(DKNumber base, DKNumber exponent);
DKNumber DKNumberNegate(DKNumber a);
/// Rounded to `places` decimals, halves away from zero.
DKNumber DKNumberRound(DKNumber a, NSInteger places);

/// Raycast's way of writing a result: at most ten decimals, digits grouped, "T" and "P"
/// from 10^12, scientific below 10^-6 and past 10^17, "∞" past the doubles.
NSString *DKFormatNumber(DKNumber number, NSString *decimalSeparator, NSString *groupingSeparator);
/// Money: the currency's symbol and its usual decimals, with the given separators.
NSString *DKFormatMoney(DKNumber amount, NSString *currencyCode, NSString *decimalSeparator, NSString *groupingSeparator);
/// The number in English words, each capitalised ("Minus Two Point Five"), nil when its
/// written form is not a plain number.
NSString *_Nullable DKSpellNumber(DKNumber number);
/// JavaScript's String(number): what Raycast copies as the unformatted answer.
NSString *DKJavaScriptNumber(double value);

NS_ASSUME_NONNULL_END
