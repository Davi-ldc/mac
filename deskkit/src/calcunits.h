// The units the calculator knows, under Raycast's names and symbols, converted through
// Foundation's NSMeasurement.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface DKCalcUnit : NSObject
@property(readonly) NSDimension *dimension;
/// Raycast's identifier ("kilometers", "squareFeet"), which also names the unit on the card.
@property(readonly) NSString *identifier;
/// What Swap Units writes ("km", "ft", "hr").
@property(readonly) NSString *symbol;
/// "Kilometers", "Square Feet".
@property(readonly) NSString *label;
/// What the unit converts to when written on its own (km to mi, °C to °F); nil when Raycast
/// leaves it as it is.
@property(readonly, nullable) DKCalcUnit *counterpart;
- (BOOL)isDuration;
/// A quantity of the unit as Raycast writes it: "212 °F", "5 feet", "1 hour", "90°".
- (NSString *)write:(NSString *)number value:(double)value;
@end

/// The longest unit name written in `text` at `index` that ends where a word ends, with its
/// length in `length`.
DKCalcUnit *_Nullable DKUnitAt(NSString *text, NSUInteger index, NSUInteger *length);
DKCalcUnit *DKUnitWithIdentifier(NSString *identifier);
BOOL DKUnitsConvertible(DKCalcUnit *from, DKCalcUnit *to);
double DKConvertUnit(double value, DKCalcUnit *from, DKCalcUnit *to);

NS_ASSUME_NONNULL_END
