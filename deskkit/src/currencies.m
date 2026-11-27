// Owns the exchange rates (a daily fetch from a free source, kept on disk) and the currency
// names and symbols the calculator reads.
#import "currencies.h"
#import "support.h"

NSNotificationName const DKCurrenciesDidUpdateNotification = @"DKCurrenciesDidUpdate";

/// ExchangeRate-API's open endpoint: no key, rates against the dollar, updated daily.
static NSString *const kSource = @"https://open.er-api.com/v6/latest/USD";
static const NSTimeInterval kMaxAge = 24 * 60 * 60;

@implementation DKCurrencies {
    NSDictionary<NSString *, NSDecimalNumber *> *_rates;
    NSDate *_updated;
    BOOL _loaded, _fetching;
}

+ (DKCurrencies *)shared {
    static DKCurrencies *shared;
    if (!shared) shared = [DKCurrencies new];
    return shared;
}

static NSURL *StoreURL(void) { return [DKSupportDirectory() URLByAppendingPathComponent:@"currencies.json"]; }

/// The response's rates as decimals: written from their shortest form, so that 5.945309
/// stays 5.945309 rather than the double nearest to it.
static NSDictionary *DecimalRates(id rates) {
    if (![rates isKindOfClass:NSDictionary.class]) return nil;
    NSMutableDictionary *out = [NSMutableDictionary new];
    NSDictionary *point = @{NSLocaleDecimalSeparator : @"."};
    for (NSString *code in rates) {
        NSNumber *rate = rates[code];
        if (![rate isKindOfClass:NSNumber.class] || rate.doubleValue <= 0) continue;
        out[code.uppercaseString] = [NSDecimalNumber decimalNumberWithString:rate.stringValue locale:point];
    }
    return out.count ? out : nil;
}

- (void)load {
    if (_loaded) return;
    _loaded = YES;
    NSData *data = [NSData dataWithContentsOfURL:StoreURL()];
    NSDictionary *stored = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![stored isKindOfClass:NSDictionary.class]) return;
    _rates = DecimalRates(stored[@"rates"]);
    NSNumber *updated = stored[@"updated"];
    if (_rates && [updated isKindOfClass:NSNumber.class]) _updated = [NSDate dateWithTimeIntervalSince1970:updated.doubleValue];
}

- (NSDictionary<NSString *, NSDecimalNumber *> *)rates {
    [self load];
    return _rates ?: @{};
}

- (NSDate *)updated {
    [self load];
    return _updated;
}

- (void)refresh:(BOOL)force {
    [self load];
    if (_fetching || (!force && _updated && -_updated.timeIntervalSinceNow < kMaxAge)) return;
    _fetching = YES;
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.timeoutIntervalForResource = 20;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration delegate:nil delegateQueue:NSOperationQueue.mainQueue];
    [[session dataTaskWithURL:[NSURL URLWithString:kSource] completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        self->_fetching = NO;
        NSDictionary *body = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSDictionary *rates = [body isKindOfClass:NSDictionary.class] ? DecimalRates(body[@"rates"]) : nil;
        if (!rates) return;
        self->_rates = rates;
        self->_updated = NSDate.date;
        NSDictionary *stored = @{@"updated" : @(self->_updated.timeIntervalSince1970), @"rates" : body[@"rates"]};
        [[NSJSONSerialization dataWithJSONObject:stored options:0 error:nil] writeToURL:StoreURL() atomically:YES];
        [NSNotificationCenter.defaultCenter postNotificationName:DKCurrenciesDidUpdateNotification object:self];
    }] resume];
    [session finishTasksAndInvalidate];
}

@end

NSString *DKCurrencyAt(NSString *text, NSUInteger index, NSUInteger *length) {
    static NSDictionary<NSString *, NSString *> *symbols, *names;
    static NSSet<NSString *> *codes;
    if (!symbols) {
        symbols = @{@"R$" : @"BRL", @"US$" : @"USD", @"CA$" : @"CAD", @"A$" : @"AUD", @"NZ$" : @"NZD", @"HK$" : @"HKD",
                    @"MX$" : @"MXN", @"$" : @"USD", @"€" : @"EUR", @"£" : @"GBP", @"¥" : @"JPY", @"₹" : @"INR", @"₩" : @"KRW",
                    @"₽" : @"RUB", @"₺" : @"TRY", @"₪" : @"ILS", @"฿" : @"THB", @"₫" : @"VND", @"₱" : @"PHP", @"₴" : @"UAH"};
        names = @{@"dollar" : @"USD", @"dollars" : @"USD", @"euro" : @"EUR", @"euros" : @"EUR", @"real" : @"BRL",
                  @"reais" : @"BRL", @"yen" : @"JPY", @"yuan" : @"CNY", @"rupee" : @"INR", @"rupees" : @"INR",
                  @"peso" : @"MXN", @"pesos" : @"MXN", @"franc" : @"CHF", @"francs" : @"CHF", @"ruble" : @"RUB", @"rubles" : @"RUB"};
        codes = [NSSet setWithArray:NSLocale.ISOCurrencyCodes];
    }
    for (NSUInteger count = MIN(3, text.length - index); count > 0; count--) {
        NSString *code = symbols[[text substringWithRange:NSMakeRange(index, count)]];
        if (code) {
            *length = count;
            return code;
        }
    }
    NSUInteger end = index;
    while (end < text.length && [NSCharacterSet.letterCharacterSet characterIsMember:[text characterAtIndex:end]]) end++;
    if (end == index) return nil;
    NSString *word = [text substringWithRange:NSMakeRange(index, end - index)];
    NSString *code = names[word.lowercaseString];
    if (!code && word.length == 3 && [codes containsObject:word.uppercaseString]) code = word.uppercaseString;
    if (code) *length = end - index;
    return code;
}

NSString *DKCurrencyName(NSString *code) {
    return [[NSLocale localeWithLocaleIdentifier:@"en"] localizedStringForCurrencyCode:code] ?: code;
}
