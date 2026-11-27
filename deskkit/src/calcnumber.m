// Owns the calculator's number type: decimal arithmetic with a double fallback, Raycast's
// written forms, English words and JavaScript's number strings.
#import "calcnumber.h"

/// NSDecimal reaches 10^127; past this a double carries the value on its own.
static const double kDecimalLimit = 1e120;

static NSDictionary *PointLocale(void) { return @{NSLocaleDecimalSeparator : @"."}; }

/// The fewest significant digits (1 to 17) that read back as `value`, as "d.ddde±x".
static void ShortestDigits(double value, char *buffer, size_t size) {
    for (int precision = 0; precision < 17; precision++) {
        snprintf(buffer, size, "%.*e", precision, value);
        if (strtod(buffer, NULL) == value) return;
    }
    snprintf(buffer, size, "%.16e", value);
}

DKNumber DKNumberFromDecimal(NSDecimal decimal) {
    NSDecimalCompact(&decimal);
    DKNumber number = {.decimal = decimal, .exact = YES};
    // NSDecimalNumber's doubleValue is off by an ulp at times (0.000001 comes out as
    // 1.0000000000000002e-6); reading the digits rounds correctly.
    number.value = strtod(NSDecimalString(&decimal, PointLocale()).UTF8String, NULL);
    return number;
}

DKNumber DKNumberFromString(NSString *digits) {
    NSDecimalNumber *parsed = [NSDecimalNumber decimalNumberWithString:digits locale:PointLocale()];
    if ([parsed isEqualToNumber:NSDecimalNumber.notANumber]) return DKNumberFromDouble(strtod(digits.UTF8String, NULL));
    // Beyond NSDecimal's range the string still reads as a double.
    double value = strtod(digits.UTF8String, NULL);
    if (fabs(value) > kDecimalLimit) return DKNumberFromDouble(value);
    return DKNumberFromDecimal(parsed.decimalValue);
}

DKNumber DKNumberFromDouble(double value) {
    DKNumber number = {.value = value};
    if (!isfinite(value) || fabs(value) > kDecimalLimit || (value != 0 && fabs(value) < 1 / kDecimalLimit)) return number;
    char buffer[40];
    ShortestDigits(value, buffer, sizeof buffer);
    NSDecimalNumber *parsed = [NSDecimalNumber decimalNumberWithString:@(buffer) locale:PointLocale()];
    number.decimal = parsed.decimalValue;
    number.exact = YES;
    return number;
}

typedef NSCalculationError (*DecimalOperation)(NSDecimal *, const NSDecimal *, const NSDecimal *, NSRoundingMode);

/// The decimal result when both sides have one and it stays in range, else the doubles'.
static DKNumber Combine(DKNumber a, DKNumber b, DecimalOperation operation, double fallback) {
    if (a.exact && b.exact) {
        NSDecimal result;
        NSCalculationError error = operation(&result, &a.decimal, &b.decimal, NSRoundPlain);
        if (error == NSCalculationNoError || error == NSCalculationLossOfPrecision) {
            DKNumber number = DKNumberFromDecimal(result);
            if (fabs(number.value) <= kDecimalLimit) return number;
        }
    }
    return DKNumberFromDouble(fallback);
}

DKNumber DKNumberAdd(DKNumber a, DKNumber b) { return Combine(a, b, NSDecimalAdd, a.value + b.value); }
DKNumber DKNumberSubtract(DKNumber a, DKNumber b) { return Combine(a, b, NSDecimalSubtract, a.value - b.value); }
DKNumber DKNumberMultiply(DKNumber a, DKNumber b) { return Combine(a, b, NSDecimalMultiply, a.value * b.value); }
DKNumber DKNumberDivide(DKNumber a, DKNumber b) { return Combine(a, b, NSDecimalDivide, a.value / b.value); }

DKNumber DKNumberNegate(DKNumber a) {
    if (!a.exact) return DKNumberFromDouble(-a.value);
    NSDecimal zero = {0};
    NSDecimal result;
    NSDecimalSubtract(&result, &zero, &a.decimal, NSRoundPlain);
    return DKNumberFromDecimal(result);
}

DKNumber DKNumberRound(DKNumber a, NSInteger places) {
    if (!a.exact) {
        double scale = pow(10, (double)places);
        return DKNumberFromDouble(round(a.value * scale) / scale);
    }
    NSDecimal result;
    NSDecimalRound(&result, &a.decimal, places, NSRoundPlain);
    return DKNumberFromDecimal(result);
}

static BOOL IsInteger(DKNumber a) {
    if (!a.exact) return isfinite(a.value) && a.value == floor(a.value);
    NSDecimal rounded;
    NSDecimalRound(&rounded, &a.decimal, 0, NSRoundPlain);
    return NSDecimalCompare(&rounded, &a.decimal) == NSOrderedSame;
}

DKNumber DKNumberPower(DKNumber base, DKNumber exponent) {
    if (base.exact && IsInteger(exponent) && fabs(exponent.value) <= 1000) {
        NSDecimal result;
        NSCalculationError error = NSDecimalPower(&result, &base.decimal, (NSUInteger)fabs(exponent.value), NSRoundPlain);
        if ((error == NSCalculationNoError || error == NSCalculationLossOfPrecision) && !NSDecimalIsNotANumber(&result)) {
            DKNumber power = DKNumberFromDecimal(result);
            if (fabs(power.value) <= kDecimalLimit && power.value != 0) {
                if (exponent.value >= 0) return power;
                NSDecimal one = [NSDecimalNumber one].decimalValue;
                return Combine(DKNumberFromDecimal(one), power, NSDecimalDivide, 1 / power.value);
            }
        }
    }
    double b = base.value, e = exponent.value;
    // An odd root of a negative number is real: (-8)^(1/3) is -2.
    if (b < 0 && e != floor(e)) {
        double root = round(1 / e);
        if (fabs(1 / e - root) < 1e-9 && fmod(fabs(root), 2) == 1) return DKNumberFromDouble(-pow(-b, e));
    }
    return DKNumberFromDouble(pow(b, e));
}

#pragma mark Writing

/// `digits` ("-1234.5", as NSDecimalString writes) with the locale's separators, the
/// integer part grouped by thousands from four digits.
static NSString *Localize(NSString *digits, NSString *decimalSeparator, NSString *groupingSeparator) {
    BOOL negative = [digits hasPrefix:@"-"];
    if (negative) digits = [digits substringFromIndex:1];
    NSRange point = [digits rangeOfString:@"."];
    NSString *integer = point.location == NSNotFound ? digits : [digits substringToIndex:point.location];
    NSString *fraction = point.location == NSNotFound ? @"" : [digits substringFromIndex:NSMaxRange(point)];
    while ([fraction hasSuffix:@"0"]) fraction = [fraction substringToIndex:fraction.length - 1];
    NSMutableString *out = [NSMutableString stringWithString:negative ? @"-" : @""];
    for (NSUInteger i = 0; i < integer.length; i++) {
        if (i && (integer.length - i) % 3 == 0 && integer.length >= 4) [out appendString:groupingSeparator];
        [out appendFormat:@"%C", [integer characterAtIndex:i]];
    }
    if (fraction.length) [out appendFormat:@"%@%@", decimalSeparator, fraction];
    return out;
}

static NSString *DecimalDigits(NSDecimal decimal) {
    NSDecimalCompact(&decimal);
    return NSDecimalString(&decimal, PointLocale());
}

static DKNumber Scale(DKNumber a, short power) {
    if (!a.exact) return DKNumberFromDouble(a.value * pow(10, power));
    NSDecimal result;
    NSDecimalMultiplyByPowerOf10(&result, &a.decimal, power, NSRoundPlain);
    return DKNumberFromDecimal(result);
}

static NSString *Scientific(DKNumber number, NSString *decimalSeparator) {
    int exponent = (int)floor(log10(fabs(number.value)));
    DKNumber mantissa = DKNumberRound(Scale(number, (short)-exponent), 10);
    // log10 can land one off, and rounding can carry the mantissa to 10.
    if (fabs(mantissa.value) >= 10 || fabs(mantissa.value) < 1) {
        exponent += fabs(mantissa.value) >= 10 ? 1 : -1;
        mantissa = DKNumberRound(Scale(number, (short)-exponent), 10);
    }
    return [NSString stringWithFormat:@"%@e%d", Localize(DecimalDigits(mantissa.decimal), decimalSeparator, @""), exponent];
}

NSString *DKFormatNumber(DKNumber number, NSString *decimalSeparator, NSString *groupingSeparator) {
    double magnitude = fabs(number.value);
    if (isinf(number.value)) return number.value < 0 ? @"-∞" : @"∞";
    if (number.value == 0) return @"0";
    // Raycast's limits: "100P" is 10^17, and anything past it is scientific.
    if (magnitude < 1e-6 || magnitude > 1e17) return Scientific(number, decimalSeparator);
    if (magnitude >= 1e12) {
        DKNumber scaled = DKNumberRound(Scale(number, -12), 10);
        NSString *suffix = @"T";
        if (fabs(scaled.value) >= 1000) {
            scaled = DKNumberRound(Scale(number, -15), 10);
            suffix = @"P";
        }
        if (fabs(scaled.value) >= 1000) return Scientific(number, decimalSeparator);
        return [Localize(DecimalDigits(scaled.decimal), decimalSeparator, groupingSeparator) stringByAppendingString:suffix];
    }
    return Localize(DecimalDigits(DKNumberRound(number, 10).decimal), decimalSeparator, groupingSeparator);
}

NSString *DKFormatMoney(DKNumber amount, NSString *currencyCode, NSString *decimalSeparator, NSString *groupingSeparator) {
    static NSMutableDictionary<NSString *, NSNumberFormatter *> *formatters;
    if (!formatters) formatters = [NSMutableDictionary new];
    NSNumberFormatter *formatter = formatters[currencyCode];
    if (!formatter) {
        formatter = [NSNumberFormatter new];
        // English symbols, as Raycast writes them: "$" for dollars, "R$" for reais.
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en"];
        formatter.numberStyle = NSNumberFormatterCurrencyStyle;
        formatter.currencyCode = currencyCode;
        formatters[currencyCode] = formatter;
    }
    formatter.currencyDecimalSeparator = formatter.decimalSeparator = decimalSeparator;
    formatter.currencyGroupingSeparator = formatter.groupingSeparator = groupingSeparator;
    NSNumber *value = amount.exact ? [NSDecimalNumber decimalNumberWithDecimal:amount.decimal] : @(amount.value);
    return [formatter stringFromNumber:value] ?: DKFormatNumber(amount, decimalSeparator, groupingSeparator);
}

static NSString *Capitalized(NSString *words) {
    NSMutableString *out = [words mutableCopy];
    BOOL start = YES;
    for (NSUInteger i = 0; i < out.length; i++) {
        unichar c = [out characterAtIndex:i];
        if (start && c >= 'a' && c <= 'z') [out replaceCharactersInRange:NSMakeRange(i, 1) withString:[NSString stringWithFormat:@"%C", (unichar)(c - 32)]];
        start = c == ' ' || c == '-';
    }
    return out;
}

NSString *DKSpellNumber(DKNumber number) {
    double magnitude = fabs(number.value);
    if (!number.exact || magnitude >= 1e12 || (magnitude && magnitude < 1e-6)) return nil;
    static NSNumberFormatter *speller;
    if (!speller) {
        speller = [NSNumberFormatter new];
        speller.locale = [NSLocale localeWithLocaleIdentifier:@"en"];
        speller.numberStyle = NSNumberFormatterSpellOutStyle;
    }
    NSString *digits = DecimalDigits(DKNumberRound(number, 10).decimal);
    BOOL negative = [digits hasPrefix:@"-"];
    if (negative) digits = [digits substringFromIndex:1];
    NSArray<NSString *> *parts = [digits componentsSeparatedByString:@"."];
    NSMutableString *words = [NSMutableString stringWithString:negative ? @"minus " : @""];
    [words appendString:[speller stringFromNumber:[NSDecimalNumber decimalNumberWithString:parts[0] locale:PointLocale()]] ?: @""];
    if (parts.count > 1) {
        NSArray *names = @[ @"zero", @"one", @"two", @"three", @"four", @"five", @"six", @"seven", @"eight", @"nine" ];
        [words appendString:@" point"];
        for (NSUInteger i = 0; i < parts[1].length; i++) [words appendFormat:@" %@", names[[parts[1] characterAtIndex:i] - '0']];
    }
    return Capitalized(words);
}

NSString *DKJavaScriptNumber(double value) {
    if (isnan(value)) return @"NaN";
    if (isinf(value)) return value < 0 ? @"-Infinity" : @"Infinity";
    if (value == 0) return @"0";
    char buffer[40];
    ShortestDigits(fabs(value), buffer, sizeof buffer);
    // "d.ddde±x" into the digits and the position of the point, as ECMAScript lays them out.
    char *e = strchr(buffer, 'e');
    int exponent = atoi(e + 1);
    NSMutableString *digits = [NSMutableString new];
    for (char *c = buffer; c < e; c++)
        if (*c != '.') [digits appendFormat:@"%c", *c];
    NSInteger k = digits.length, n = exponent + 1;
    NSString *body;
    if (k <= n && n <= 21) body = [digits stringByPaddingToLength:n withString:@"0" startingAtIndex:0];
    else if (0 < n && n <= 21) body = [NSString stringWithFormat:@"%@.%@", [digits substringToIndex:n], [digits substringFromIndex:n]];
    else if (-6 < n && n <= 0) body = [NSString stringWithFormat:@"0.%@%@", [@"" stringByPaddingToLength:-n withString:@"0" startingAtIndex:0], digits];
    else {
        NSString *mantissa = k == 1 ? digits : [NSString stringWithFormat:@"%@.%@", [digits substringToIndex:1], [digits substringFromIndex:1]];
        body = [NSString stringWithFormat:@"%@e%@%ld", mantissa, n - 1 >= 0 ? @"+" : @"-", (long)labs(n - 1)];
    }
    return value < 0 ? [@"-" stringByAppendingString:body] : body;
}
