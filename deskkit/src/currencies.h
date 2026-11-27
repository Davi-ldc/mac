// Exchange rates for the calculator, and the ways a currency is written.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Posted on the main thread when new rates are in.
extern NSNotificationName const DKCurrenciesDidUpdateNotification;

@interface DKCurrencies : NSObject
@property(class, readonly) DKCurrencies *shared;
/// Units of each currency per US dollar, by ISO code; empty until the first fetch is in.
/// Reading never waits on the network.
@property(readonly) NSDictionary<NSString *, NSDecimalNumber *> *rates;
/// When the rates were fetched.
@property(readonly, nullable) NSDate *updated;
/// Fetches the rates in the background unless they are less than a day old, or always
/// with `force`. A fetch already under way is not started twice.
- (void)refresh:(BOOL)force;
@end

/// The currency written at `index` in `text` as a symbol ("R$", "€"), a name ("euros") or a
/// code ("BRL"), with its length in `length`.
NSString *_Nullable DKCurrencyAt(NSString *text, NSUInteger index, NSUInteger *length);
/// "US Dollar", "Brazilian Real".
NSString *DKCurrencyName(NSString *code);

NS_ASSUME_NONNULL_END
