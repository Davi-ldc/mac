// Owns reading a root search query: a hand-written recursive descent parser that evaluates
// as it reads, Raycast's rules for which queries show a calculator, and the card's words.
#import "calculator.h"
#import "calcnumber.h"
#import "calctime.h"
#import "calcunits.h"
#import "currencies.h"

typedef NS_ENUM(int, DKKind) { DKKindNumber, DKKindPercent, DKKindBool, DKKindUnit, DKKindMoney, DKKindDate };

typedef struct {
    DKKind kind;
    /// A percentage holds its fraction (0.1 for 10%), a boolean 0 or 1.
    DKNumber number;
    DKCalcUnit *unit;
    NSString *currency;
    DKMoment *moment;
    /// 16, 2 or 8 for a number written in that base, which the answer keeps; 0 otherwise.
    int base;
    /// Durations added up from several units ("2h 30m"), written as a timespan.
    BOOL compound;
    /// A length to be written in feet and inches.
    BOOL feetAndInches;
} DKValue;

static DKValue Number(DKNumber number) { return (DKValue){.kind = DKKindNumber, .number = number}; }

static BOOL IsDigit(unichar c) { return c >= '0' && c <= '9'; }
static BOOL IsLetter(unichar c) { return [NSCharacterSet.letterCharacterSet characterIsMember:c]; }

/// What Raycast's card calls an expression by its function (sqrt is "Square Root").
static NSDictionary<NSString *, NSString *> *FunctionLabels(void) {
    static NSDictionary *labels;
    return labels = labels ?: @{@"sqrt" : @"Square Root", @"√" : @"Square Root", @"round" : @"Rounding", @"ceil" : @"Ceiling",
             @"floor" : @"Floor", @"sin" : @"Sine", @"cos" : @"Cosine", @"tan" : @"Tangent", @"log" : @"Logarithmic"};
}

/// What it calls an expression by its one operator.
static NSDictionary<NSString *, NSString *> *OperatorLabels(void) {
    static NSDictionary *labels;
    return labels = labels ?: @{@"+" : @"Sum", @"plus" : @"Sum", @"-" : @"Difference", @"−" : @"Difference", @"*" : @"Product",
             @"x" : @"Product", @"X" : @"Product", @"×" : @"Product", @"·" : @"Product", @"/" : @"Divide",
             @"per" : @"Divide", @"÷" : @"Divide", @"%" : @"Remainder", @"mod" : @"Remainder", @"^" : @"Power",
             @"**" : @"Power", @"==" : @"Equality", @">" : @"Greater than", @"<" : @"Lesser than",
             @">=" : @"Greater than or equal to", @"=>" : @"Greater than or equal to", @"≥" : @"Greater than or equal to",
             @"<=" : @"Lesser than or equal to", @"=<" : @"Lesser than or equal to", @"≤" : @"Lesser than or equal to"};
}

static NSSet<NSString *> *Functions(void) {
    static NSSet *functions;
    if (!functions)
        functions = [NSSet setWithArray:@[ @"sqrt", @"cbrt", @"sin", @"cos", @"tan", @"asin", @"acos", @"atan", @"arcsin",
                                           @"arccos", @"arctan", @"sinh", @"cosh", @"tanh", @"log", @"ln", @"log2",
                                           @"log10", @"exp", @"abs", @"round", @"floor", @"ceil", @"fact", @"gcd",
                                           @"lcm", @"max", @"min" ]];
    return functions;
}

static NSDictionary<NSString *, NSNumber *> *Constants(void) {
    static NSDictionary *constants;
    return constants = constants ?: @{@"pi" : @(M_PI), @"π" : @(M_PI), @"e" : @(M_E), @"tau" : @(2 * M_PI), @"τ" : @(2 * M_PI),
             @"phi" : @((1 + sqrt(5)) / 2), @"φ" : @((1 + sqrt(5)) / 2)};
}

@interface DKCalculation ()
@property(readwrite) NSString *query, *expression, *answer, *expressionLabel, *answerLabel;
@property(readwrite) NSArray<NSValue *> *highlights;
@property(readwrite, nullable) NSString *unformattedAnswer, *swappedQuery;
@property(readwrite) BOOL usesCurrency;
@end

@implementation DKCalculation

- (DKCalculation *)calculationForQuery:(NSString *)query {
    DKCalculation *calculation = [DKCalculation new];
    calculation.query = calculation.expression = query;
    calculation.highlights = @[];
    calculation.answer = _answer;
    calculation.unformattedAnswer = _unformattedAnswer;
    calculation.expressionLabel = _expressionLabel;
    calculation.answerLabel = _answerLabel;
    calculation.swappedQuery = _swappedQuery;
    calculation.usesCurrency = _usesCurrency;
    return calculation;
}

@end

/// Reads one query. Each rule consumes what it understands and evaluates it; the first thing
/// it cannot read fails the whole query, as nothing partial is shown.
@interface DKCalcParser : NSObject
@end

@implementation DKCalcParser {
  @public
    NSString *_text;
    NSUInteger _length, _pos;
    unichar _decimal, _grouping;
    NSDictionary<NSString *, NSDecimalNumber *> *_rates;
    DKCalendarContext *_calendar;
    BOOL _failed;
    NSMutableArray<NSValue *> *_highlights;
    /// Characters the card writes differently, by index.
    NSMutableDictionary<NSNumber *, NSString *> *_replacements;
    /// What labels the expression, in order: binary operators as typed, "(" for a bracket,
    /// "%%" for a percent sign, "f:" and a name for a function.
    NSMutableArray<NSString *> *_labelTokens;
    /// The query is more than one quantity (Raycast's "other").
    BOOL _complex;
    NSUInteger _conversions;
    /// The quantity a lone-quantity query starts with, where its number ends, and what it
    /// was converted to.
    DKValue _quantity, _target;
    BOOL _hasQuantity;
    NSUInteger _quantityEnd;
    /// What the card writes under each side of "days until christmas".
    NSArray<NSString *> *_untilLabels;
}

#pragma mark Reading

- (unichar)peek { return _pos < _length ? [_text characterAtIndex:_pos] : 0; }
- (unichar)peekAt:(NSUInteger)index { return index < _length ? [_text characterAtIndex:index] : 0; }

- (void)skipSpaces {
    while (_pos < _length && [NSCharacterSet.whitespaceCharacterSet characterIsMember:[self peek]]) _pos++;
}

- (BOOL)restIsBlank {
    for (NSUInteger i = _pos; i < _length; i++)
        if (![NSCharacterSet.whitespaceCharacterSet characterIsMember:[_text characterAtIndex:i]]) return NO;
    return YES;
}

- (void)highlight:(NSUInteger)start { [self highlightRange:NSMakeRange(start, _pos - start)]; }
- (void)highlightRange:(NSRange)range {
    if (range.length) [_highlights addObject:[NSValue valueWithRange:range]];
}

/// Consumes `word` (any case) after spaces when a word ends there.
- (BOOL)matchWord:(NSString *)word {
    NSUInteger save = _pos;
    [self skipSpaces];
    // Most words are ruled out by their first letter, without making a string to compare.
    if (tolower([self peek]) == [word characterAtIndex:0] && _pos + word.length <= _length &&
        [[_text substringWithRange:NSMakeRange(_pos, word.length)] caseInsensitiveCompare:word] == NSOrderedSame &&
        !IsLetter([self peekAt:_pos + word.length])) {
        _pos += word.length;
        return YES;
    }
    _pos = save;
    return NO;
}

/// Consumes `symbol` after spaces.
- (BOOL)matchSymbol:(NSString *)symbol {
    NSUInteger save = _pos;
    [self skipSpaces];
    if (_pos + symbol.length <= _length && [[_text substringWithRange:NSMakeRange(_pos, symbol.length)] isEqualToString:symbol]) {
        _pos += symbol.length;
        return YES;
    }
    _pos = save;
    return NO;
}

/// A function name with its digits, "log2" or "log10", where one is written.
- (NSString *)functionAt:(NSUInteger)index {
    NSUInteger end = index;
    while (end < _length && IsLetter([_text characterAtIndex:end])) end++;
    while (end < _length && IsDigit([_text characterAtIndex:end])) end++;
    NSString *word = [_text substringWithRange:NSMakeRange(index, end - index)];
    return [Functions() containsObject:word.lowercaseString] ? word : nil;
}

- (NSString *)wordAt:(NSUInteger)index {
    NSUInteger end = index;
    while (end < _length && IsLetter([_text characterAtIndex:end])) end++;
    return [_text substringWithRange:NSMakeRange(index, end - index)];
}

- (DKValue)fail {
    _failed = YES;
    return (DKValue){0};
}

#pragma mark Grammar

- (DKValue)parse {
    DKValue value = [self parseConversions];
    [self skipSpaces];
    if (_pos < _length) return [self fail];
    return value;
}

- (BOOL)matchConversionWord {
    for (NSString *word in @[ @"to", @"into", @"in", @"as" ])
        if ([self matchWord:word]) return YES;
    return [self matchSymbol:@"→"] || [self matchSymbol:@"->"];
}

- (DKValue)parseConversions {
    DKValue value = [self parseStatement];
    while (!_failed) {
        NSUInteger save = _pos;
        if (![self matchConversionWord]) {
            _pos = save;
            break;
        }
        _conversions++;
        value = [self convert:value];
    }
    return value;
}

- (DKValue)parseStatement {
    DKValue left = [self parseSum];
    if (_failed) return left;
    NSUInteger save = _pos;
    // "5 as % of 20" and "5 is what % of 20" give 25%.
    if (([self matchWord:@"as"] && [self matchPercentOf]) || ([self matchWord:@"is"] && [self matchWord:@"what"] && [self matchPercentOf])) {
        _complex = YES;
        DKValue whole = [self parseSum];
        if (_failed || whole.kind != DKKindNumber || whole.number.value == 0 || left.kind != DKKindNumber) return [self fail];
        return (DKValue){.kind = DKKindPercent, .number = DKNumberDivide(left.number, whole.number)};
    }
    _pos = save;
    for (NSString *comparison in @[ @">=", @"=>", @"≥", @"<=", @"=<", @"≤", @"==", @">", @"<" ]) {
        if (![self matchSymbol:comparison]) continue;
        _complex = YES;
        [_labelTokens addObject:comparison];
        DKValue right = [self parseSum];
        if (_failed) return right;
        return [self compare:left with:right operator:comparison];
    }
    return left;
}

- (BOOL)matchPercentOf {
    [self skipSpaces];
    NSUInteger start = _pos;
    if (![self matchSymbol:@"%"]) return NO;
    [self highlightRange:NSMakeRange(start, 1)];
    [_labelTokens addObject:@"%%"];
    return [self matchWord:@"of"];
}

- (DKValue)parseSum {
    DKValue value = [self parseProduct];
    while (!_failed) {
        NSUInteger save = _pos;
        [self skipSpaces];
        NSUInteger start = _pos;
        BOOL minus;
        if ([self matchSymbol:@"+"] || [self matchWord:@"plus"]) minus = NO;
        else if ([self matchSymbol:@"->"]) {
            _pos = save;
            break;
        } else if ([self matchSymbol:@"-"] || [self matchSymbol:@"−"] || [self matchWord:@"minus"]) minus = YES;
        else {
            _pos = save;
            break;
        }
        _complex = YES;
        [_labelTokens addObject:[_text substringWithRange:NSMakeRange(start, _pos - start)]];
        if ([_text characterAtIndex:start] == '-') _replacements[@(start)] = @"−";
        // A trailing operator is ignored while the next term is being typed: "3-" is 3.
        if ([self restIsBlank]) break;
        DKValue right = [self parseProduct];
        if (_failed) break;
        value = [self add:value to:right subtracting:minus];
    }
    return value;
}

/// The start of something that multiplies what comes before it without an operator: "2pi",
/// "3(4)", "2 sqrt(9)".
- (BOOL)startsImplicitProduct {
    unichar c = [self peek];
    if (c == '(' || c == L'√') return YES;
    if (!IsLetter(c)) return NO;
    NSString *word = [self wordAt:_pos].lowercaseString;
    return [Functions() containsObject:word] || Constants()[word] != nil;
}

- (DKValue)parseProduct {
    DKValue value = [self parseUnary];
    while (!_failed) {
        NSUInteger save = _pos;
        [self skipSpaces];
        NSUInteger start = _pos;
        unichar c = [self peek];
        unichar operator = 0;
        BOOL written = YES;
        if ([self matchSymbol:@"*"] || [self matchSymbol:@"×"] || [self matchSymbol:@"·"] || [self matchSymbol:@"⋅"]) {
            operator = '*';
            if (c == '*') _replacements[@(start)] = @"×";
        } else if ((c == 'x' || c == 'X') && !IsLetter([self peekAt:_pos + 1])) {
            _pos++;
            operator = '*';
            _replacements[@(start)] = @"×";
        } else if ([self matchWord:@"times"] || ([self matchWord:@"multiplied"] && [self matchWord:@"by"])) {
            operator = '*';
        } else if ([self matchSymbol:@"/"] || [self matchSymbol:@"÷"]) {
            operator = '/';
            if (c == '/') _replacements[@(start)] = @"÷";
        } else if (([self matchWord:@"divided"] && [self matchWord:@"by"]) || [self matchWord:@"per"]) {
            operator = '/';
        } else if ([self matchWord:@"mod"] || [self matchSymbol:@"%"]) {
            operator = '%';
        } else if ([self matchWord:@"choose"]) {
            operator = 'C';
        } else if ([self startsImplicitProduct]) {
            operator = '*';
            written = NO;
        } else {
            _pos = save;
            break;
        }
        _complex = YES;
        if (written) [_labelTokens addObject:[_text substringWithRange:NSMakeRange(start, _pos - start)]];
        if ([self restIsBlank]) break;
        DKValue right = [self parseUnary];
        if (_failed) break;
        if (operator == '*') value = [self multiply:value by:right];
        else if (operator == '/') value = [self divide:value by:right];
        else if (operator == '%') value = [self remainder:value by:right];
        else value = [self choose:value from:right];
    }
    return value;
}

- (DKValue)parseUnary {
    [self skipSpaces];
    unichar c = [self peek];
    if (c != '-' && c != L'−' && c != '+') return [self parsePower];
    NSUInteger start = _pos++;
    // A minus sign written against its number is part of it, as Raycast highlights it.
    if (IsDigit([self peek])) [self highlightRange:NSMakeRange(start, 1)];
    else _complex = YES;
    DKValue value = [self parseUnary];
    if (_failed || c == '+') return value;
    if (value.kind == DKKindBool || value.kind == DKKindDate) return [self fail];
    value.number = DKNumberNegate(value.number);
    return value;
}

- (DKValue)parsePower {
    DKValue base = [self parsePostfix];
    if (_failed) return base;
    NSUInteger save = _pos;
    [self skipSpaces];
    NSUInteger start = _pos;
    BOOL written = [self matchSymbol:@"**"] || [self matchSymbol:@"^"];
    if (!written && !([self matchWord:@"to"] && [self matchWord:@"the"] && [self matchWord:@"power"] && [self matchWord:@"of"])) {
        _pos = save;
        return base;
    }
    _complex = YES;
    if (written) [_labelTokens addObject:[_text substringWithRange:NSMakeRange(start, _pos - start)]];
    if ([self restIsBlank]) return base;
    DKValue exponent = [self parseUnary];
    if (_failed) return exponent;
    if (base.kind != DKKindNumber || exponent.kind != DKKindNumber) return [self fail];
    return Number(DKNumberPower(base.number, exponent.number));
}

/// After a number: is the "%" a percent sign? Not when an operand follows ("50 % 3").
- (BOOL)atPercentSign {
    NSUInteger save = _pos;
    [self skipSpaces];
    BOOL percent = [self peek] == '%';
    if (percent) {
        NSUInteger after = _pos + 1;
        while (after < _length && [NSCharacterSet.whitespaceCharacterSet characterIsMember:[_text characterAtIndex:after]]) after++;
        unichar next = [self peekAt:after];
        percent = !(IsDigit(next) || next == '(' || next == '.');
    }
    if (!percent) _pos = save;
    return percent;
}

- (DKValue)parsePostfix {
    DKValue value = [self parsePrimary];
    while (!_failed) {
        if ([self peek] == '!' && [self peekAt:_pos + 1] != '=') {
            _pos++;
            _complex = YES;
            value = [self factorial:value];
            continue;
        }
        if (value.kind == DKKindNumber && [self atPercentSign]) {
            [self highlightRange:NSMakeRange(_pos++, 1)];
            [_labelTokens addObject:@"%%"];
            _complex = YES;
            value.kind = DKKindPercent;
            value.number = DKNumberDivide(value.number, DKNumberFromString(@"100"));
            if ([self matchWord:@"of"]) {
                DKValue whole = [self parsePower];
                if (_failed) return whole;
                whole.number = DKNumberMultiply(whole.number, value.number);
                if (whole.kind == DKKindPercent) whole.kind = DKKindNumber;
                value = whole;
            } else if ([self matchWord:@"off"]) {
                DKValue whole = [self parsePower];
                if (_failed) return whole;
                value = [self add:whole to:value subtracting:YES];
            }
            continue;
        }
        if (value.kind == DKKindNumber && [self readUnitInto:&value]) continue;
        if (value.kind == DKKindUnit && value.unit.isDuration && [self matchWord:@"ago"]) {
            [self highlightRange:NSMakeRange(_pos - 3, 3)];
            _complex = YES;
            value = (DKValue){.kind = DKKindDate, .moment = [_calendar momentAgo:value.number.value unit:value.unit]};
            continue;
        }
        break;
    }
    return value;
}

/// "in" names inches only before a conversion ("12 in to cm"); elsewhere it converts.
- (DKCalcUnit *)unitAt:(NSUInteger)index length:(NSUInteger *)length {
    DKCalcUnit *unit = DKUnitAt(_text, index, length);
    if (!unit || ![[_text substringWithRange:NSMakeRange(index, *length)].lowercaseString isEqualToString:@"in"]) return unit;
    NSUInteger save = _pos;
    _pos = index + *length;
    BOOL converting = [self matchWord:@"to"] || [self matchWord:@"into"] || [self matchWord:@"in"] || [self matchWord:@"as"];
    _pos = save;
    return converting ? unit : nil;
}

/// A unit or currency after the number `value`, and any further quantities of the same
/// kind with no operator between them ("6'2\"", "2 hours 30 minutes").
- (BOOL)readUnitInto:(DKValue *)value {
    NSUInteger save = _pos;
    [self skipSpaces];
    NSUInteger start = _pos, length = 0;
    DKCalcUnit *unit = [self unitAt:_pos length:&length];
    if (unit) {
        _pos += length;
        [self highlight:start];
        value->kind = DKKindUnit;
        value->unit = unit;
        if (save == _quantityEnd) _quantity.unit = unit;
        while ([self readAnotherQuantityOf:value]) {}
        return YES;
    }
    NSString *currency = DKCurrencyAt(_text, _pos, &length);
    if (currency) {
        _pos += length;
        if (!_rates[currency]) return [self fail], YES;
        [self highlight:start];
        value->kind = DKKindMoney;
        value->currency = currency;
        if (save == _quantityEnd) _quantity.currency = currency;
        return YES;
    }
    _pos = save;
    return NO;
}

- (BOOL)readAnotherQuantityOf:(DKValue *)value {
    NSUInteger save = _pos;
    [self skipSpaces];
    if (!IsDigit([self peek])) return _pos = save, NO;
    NSUInteger highlights = _highlights.count;
    DKValue part = [self readNumber];
    NSUInteger length = 0;
    [self skipSpaces];
    NSUInteger unitStart = _pos;
    // Inside "2h 30m", "m" is minutes.
    DKCalcUnit *unit = value->unit.isDuration && [[self wordAt:_pos] isEqualToString:@"m"] ? DKUnitWithIdentifier(@"minutes")
                                                                                           : [self unitAt:_pos length:&length];
    if (unit && !length) length = 1;
    if (_failed || !unit || !DKUnitsConvertible(unit, value->unit)) {
        _failed = NO;
        _pos = save;
        [_highlights removeObjectsInRange:NSMakeRange(highlights, _highlights.count - highlights)];
        return NO;
    }
    _pos = unitStart + length;
    [self highlight:unitStart];
    _complex = YES;
    value->compound = YES;
    value->number = DKNumberAdd(value->number, DKNumberFromDouble(DKConvertUnit(part.number.value, unit, value->unit)));
    return YES;
}

- (DKValue)readNumber {
    NSUInteger start = _pos;
    unichar c = [self peek], next = [self peekAt:_pos + 1];
    if (c == '0' && (next == 'x' || next == 'X' || next == 'b' || next == 'B' || next == 'o' || next == 'O')) {
        int base = next == 'x' || next == 'X' ? 16 : next == 'b' || next == 'B' ? 2 : 8;
        _pos += 2;
        unsigned long long integer = 0;
        NSUInteger digits = 0;
        for (;; _pos++, digits++) {
            unichar d = [self peek];
            int digit = IsDigit(d) ? d - '0' : (d >= 'a' && d <= 'f') ? d - 'a' + 10 : (d >= 'A' && d <= 'F') ? d - 'A' + 10 : 99;
            if (digit >= base) break;
            if (integer > (ULLONG_MAX - (unsigned)digit) / (unsigned)base) return [self fail];
            integer = integer * (unsigned)base + (unsigned)digit;
        }
        if (!digits) return [self fail];
        [self highlight:start];
        DKValue value = Number(DKNumberFromString([NSString stringWithFormat:@"%llu", integer]));
        value.base = base;
        return value;
    }
    NSMutableString *digits = [NSMutableString new];
    BOOL point = NO;
    while (_pos < _length) {
        c = [self peek];
        next = [self peekAt:_pos + 1];
        if (IsDigit(c)) {
            [digits appendFormat:@"%C", c];
            _pos++;
        } else if (c == '_' && digits.length && IsDigit(next)) {
            _pos++;
        } else if (c == _grouping && digits.length && !point && IsDigit(next) && IsDigit([self peekAt:_pos + 2]) &&
                   IsDigit([self peekAt:_pos + 3]) && !IsDigit([self peekAt:_pos + 4])) {
            // Thousands are grouped by threes: "1.005" is a thousand and five here, "1.5" one and a half.
            _pos++;
        } else if ((c == _decimal || c == '.' || c == ',') && !point && IsDigit(next)) {
            [digits appendString:@"."];
            point = YES;
            _pos++;
        } else {
            break;
        }
    }
    if (!digits.length) return [self fail];
    c = [self peek];
    next = [self peekAt:_pos + 1];
    if ((c == 'e' || c == 'E') && (IsDigit(next) || ((next == '+' || next == '-') && IsDigit([self peekAt:_pos + 2])))) {
        [digits appendString:@"e"];
        _pos++;
        if (!IsDigit([self peek])) [digits appendFormat:@"%C", [_text characterAtIndex:_pos++]];
        while (IsDigit([self peek])) [digits appendFormat:@"%C", [_text characterAtIndex:_pos++]];
    }
    [self highlight:start];
    return Number(DKNumberFromString(digits));
}

/// Reads "(a, b)" into `arguments`, at most `capacity` of them, and returns their number.
- (NSUInteger)parseArguments:(DKValue *)arguments capacity:(NSUInteger)capacity {
    [_labelTokens addObject:@"("];
    _pos++;
    for (NSUInteger count = 0; count < capacity && !_failed; count++) {
        arguments[count] = [self parseStatement];
        if (_failed) break;
        if ([self matchSymbol:@")"]) return count + 1;
        if (!([self matchSymbol:@","] || [self matchSymbol:@";"])) break;
    }
    _failed = YES;
    return 0;
}

- (DKValue)parsePrimary {
    [self skipSpaces];
    NSUInteger start = _pos;
    unichar c = [self peek];
    NSUInteger length = 0;
    // Times and days start with digits too: "3pm", "25 december".
    DKMoment *moment = IsDigit(c) ? [_calendar momentAt:_text index:_pos length:&length highlights:_highlights] : nil;
    if (moment) {
        _pos += length;
        _complex = YES;
        return (DKValue){.kind = DKKindDate, .moment = moment};
    }
    if (IsDigit(c) || ((c == '.' || c == ',') && IsDigit([self peekAt:_pos + 1]))) {
        DKValue value = [self readNumber];
        [self noteQuantity:value];
        return value;
    }
    if (c == '(') {
        _pos++;
        _complex = YES;
        [_labelTokens addObject:@"("];
        DKValue value = [self parseStatement];
        if (_failed || ![self matchSymbol:@")"]) return [self fail];
        return value;
    }
    if (c == L'√') {
        _pos++;
        _complex = YES;
        [_labelTokens addObject:@"f:√"];
        DKValue value = [self parsePostfix];
        return _failed ? value : [self apply:@"sqrt" to:&value count:1];
    }
    // A currency written before its amount: "$100", "R$100", "€50".
    NSString *currency = !IsLetter(c) || [self peekAt:_pos + 1] == '$' ? DKCurrencyAt(_text, _pos, &length) : nil;
    if (currency) {
        _pos += length;
        [self skipSpaces];
        if (!IsDigit([self peek]) || !_rates[currency]) return [self fail];
        DKValue value = [self readNumber];
        [self highlight:start];
        value.kind = DKKindMoney;
        value.currency = currency;
        [self noteQuantity:value];
        return value;
    }
    if (!IsLetter(c)) return [self fail];

    NSString *word = [self functionAt:_pos] ?: [self wordAt:_pos], *name = word.lowercaseString;
    if ([Functions() containsObject:name] && !(([name isEqualToString:@"min"]) && [self peekAt:_pos + 3] != '(')) {
        _pos += word.length;
        _complex = YES;
        [_labelTokens addObject:[@"f:" stringByAppendingString:name]];
        [self skipSpaces];
        if ([self peek] == '(') {
            DKValue arguments[4];
            NSUInteger count = [self parseArguments:arguments capacity:4];
            return _failed ? [self fail] : [self apply:name to:arguments count:count];
        }
        DKValue argument = [self parsePower];
        return _failed ? argument : [self apply:name to:&argument count:1];
    }
    NSNumber *constant = Constants()[name];
    if (constant) {
        _pos += word.length;
        _complex = YES;
        return Number(DKNumberFromDouble(constant.doubleValue));
    }
    if ([name isEqualToString:@"half"] && [self matchWord:@"half"] && [self matchWord:@"of"]) {
        _complex = YES;
        DKValue value = [self parsePower];
        if (!_failed) value.number = DKNumberDivide(value.number, DKNumberFromString(@"2"));
        return value;
    }
    moment = [_calendar momentAt:_text index:_pos length:&length highlights:_highlights];
    if (moment) {
        _pos += length;
        _complex = YES;
        return (DKValue){.kind = DKKindDate, .moment = moment};
    }
    // "days until christmas".
    DKCalcUnit *duration = DKUnitAt(_text, _pos, &length);
    if (duration.isDuration) {
        NSUInteger save = _pos;
        _pos += length;
        [self highlight:save];
        if ([self matchWord:@"until"] || [self matchWord:@"till"]) {
            DKValue then = [self parsePrimary];
            if (_failed || then.kind != DKKindDate) return [self fail];
            _complex = YES;
            NSArray *labels;
            double amount = [_calendar amountUntil:then.moment unit:duration labels:&labels];
            _untilLabels = labels;
            return (DKValue){.kind = DKKindUnit, .number = DKNumberFromDouble(amount), .unit = duration};
        }
        _pos = save;
        [_highlights removeLastObject];
    }
    // A unit or currency on its own is one of it: "km to mi".
    DKValue one = Number(DKNumberFromString(@"1"));
    if ([self readUnitInto:&one]) {
        if (_failed) return one;
        [self noteQuantity:one];
        return one;
    }
    return [self fail];
}

/// The first quantity of the query, which a lone-quantity query converts; its unit is read
/// after it.
- (void)noteQuantity:(DKValue)value {
    if (_hasQuantity) {
        _complex = YES;
        return;
    }
    _hasQuantity = YES;
    _quantity = value;
    _quantityEnd = _pos;
}

#pragma mark Evaluation

- (DKValue)add:(DKValue)a to:(DKValue)b subtracting:(BOOL)subtract {
    DKNumber (*combine)(DKNumber, DKNumber) = subtract ? DKNumberSubtract : DKNumberAdd;
    if (a.kind == DKKindDate && (b.kind == DKKindUnit && b.unit.isDuration)) {
        DKMoment *moment = [_calendar moment:a.moment adding:subtract ? -b.number.value : b.number.value unit:b.unit];
        return moment ? (DKValue){.kind = DKKindDate, .moment = moment} : [self fail];
    }
    if (a.kind == DKKindDate || b.kind == DKKindDate || a.kind == DKKindBool || b.kind == DKKindBool) return [self fail];
    if (a.kind == DKKindPercent && b.kind == DKKindPercent) {
        a.number = combine(a.number, b.number);
        return a;
    }
    if (b.kind == DKKindPercent) {
        // 200 + 10% is 220.
        a.number = DKNumberMultiply(a.number, combine(DKNumberFromString(@"1"), b.number));
        return a;
    }
    if (a.kind == DKKindPercent) a.kind = DKKindNumber;
    if (a.kind == DKKindMoney && b.kind == DKKindMoney) {
        // Raycast gives the sum in the last currency: 5 usd + 3 eur is €7,56.
        b.number = combine([self money:a.number from:a.currency to:b.currency], b.number);
        return b;
    }
    if (a.kind == DKKindUnit && b.kind == DKKindUnit) {
        if (!DKUnitsConvertible(a.unit, b.unit)) return [self fail];
        a.number = combine(a.number, DKNumberFromDouble(DKConvertUnit(b.number.value, b.unit, a.unit)));
        return a;
    }
    if ((a.kind == DKKindUnit && b.kind == DKKindMoney) || (a.kind == DKKindMoney && b.kind == DKKindUnit)) return [self fail];
    DKValue result = a.kind == DKKindNumber ? b : a;
    result.number = combine(a.number, b.number);
    result.base = a.base ?: b.base;
    return result;
}

/// The square of a length is an area: 2 m × 3 m is 6 m².
- (DKCalcUnit *)areaOf:(DKCalcUnit *)length {
    NSDictionary *areas = @{@"millimeters" : @"squareMillimeters", @"centimeters" : @"squareCentimeters", @"meters" : @"squareMeters",
                            @"kilometers" : @"squareKilometers", @"inches" : @"squareInches", @"feet" : @"squareFeet",
                            @"yards" : @"squareYards", @"miles" : @"squareMiles"};
    NSString *area = areas[length.identifier];
    return area ? DKUnitWithIdentifier(area) : nil;
}

- (DKValue)multiply:(DKValue)a by:(DKValue)b {
    if (a.kind == DKKindBool || b.kind == DKKindBool || a.kind == DKKindDate || b.kind == DKKindDate) return [self fail];
    if (a.kind == DKKindPercent && b.kind != DKKindPercent) {
        DKValue swap = a;
        a = b;
        b = swap;
    }
    if (b.kind == DKKindPercent) {
        // 200 * 10% is 20; 10% * 10% is 1%.
        a.number = DKNumberMultiply(a.number, b.number);
        return a;
    }
    if (a.kind == DKKindUnit && b.kind == DKKindUnit) {
        DKCalcUnit *area = [self areaOf:a.unit];
        if (!area || !DKUnitsConvertible(a.unit, b.unit)) return [self fail];
        a.number = DKNumberMultiply(a.number, DKNumberFromDouble(DKConvertUnit(b.number.value, b.unit, a.unit)));
        a.unit = area;
        return a;
    }
    if (a.kind != DKKindNumber && b.kind != DKKindNumber) return [self fail];
    DKValue result = a.kind == DKKindNumber ? b : a;
    result.number = DKNumberMultiply(a.number, b.number);
    result.base = a.base ?: b.base;
    return result;
}

- (DKValue)divide:(DKValue)a by:(DKValue)b {
    if (a.kind == DKKindBool || b.kind == DKKindBool || a.kind == DKKindDate || b.kind == DKKindDate) return [self fail];
    if (b.number.value == 0) return [self fail];
    if (b.kind == DKKindPercent) {
        a.number = DKNumberDivide(a.number, b.number);
        return a;
    }
    if (a.kind == DKKindUnit && b.kind == DKKindUnit) {
        if (!DKUnitsConvertible(a.unit, b.unit)) return [self fail];
        return Number(DKNumberDivide(a.number, DKNumberFromDouble(DKConvertUnit(b.number.value, b.unit, a.unit))));
    }
    if (a.kind == DKKindMoney && b.kind == DKKindMoney)
        return Number(DKNumberDivide(a.number, [self money:b.number from:b.currency to:a.currency]));
    if (b.kind != DKKindNumber) return [self fail];
    if (a.kind == DKKindPercent) a.kind = DKKindNumber;
    a.number = DKNumberDivide(a.number, b.number);
    a.base = a.base ?: b.base;
    return a;
}

- (DKValue)remainder:(DKValue)a by:(DKValue)b {
    if (a.kind != DKKindNumber || b.kind != DKKindNumber || b.number.value == 0) return [self fail];
    // Truncated, like JavaScript's %: -7 % 3 is -1.
    DKNumber quotient = DKNumberDivide(a.number, b.number);
    DKNumber whole = DKNumberFromDouble(trunc(quotient.value));
    if (quotient.exact) {
        NSDecimal truncated;
        NSDecimalRound(&truncated, &quotient.decimal, 0, quotient.value < 0 ? NSRoundUp : NSRoundDown);
        whole = DKNumberFromDecimal(truncated);
    }
    a.number = DKNumberSubtract(a.number, DKNumberMultiply(whole, b.number));
    a.base = a.base ?: b.base;
    return a;
}

- (DKValue)factorial:(DKValue)value {
    if (value.kind != DKKindNumber || value.number.value < 0) return [self fail];
    double n = value.number.value;
    if (n != floor(n)) return Number(DKNumberFromDouble(tgamma(n + 1)));
    if (n > 170) return Number(DKNumberFromDouble(INFINITY));
    DKNumber product = DKNumberFromString(@"1");
    for (int i = 2; i <= (int)n; i++) product = DKNumberMultiply(product, DKNumberFromDouble(i));
    return Number(product);
}

/// "5 choose 2": the ways to pick 2 of 5.
- (DKValue)choose:(DKValue)n from:(DKValue)k {
    double total = n.number.value, picked = k.number.value;
    if (n.kind != DKKindNumber || k.kind != DKKindNumber || picked < 0 || picked > total || picked != floor(picked) || total != floor(total))
        return [self fail];
    DKNumber ways = DKNumberFromString(@"1");
    for (int i = 1; i <= (int)picked; i++)
        ways = DKNumberDivide(DKNumberMultiply(ways, DKNumberFromDouble(total - picked + i)), DKNumberFromDouble(i));
    return Number(ways);
}

- (DKValue)compare:(DKValue)a with:(DKValue)b operator:(NSString *)operator {
    double left = a.number.value, right = b.number.value;
    if (a.kind == DKKindUnit && b.kind == DKKindUnit && DKUnitsConvertible(a.unit, b.unit))
        right = DKConvertUnit(right, b.unit, a.unit);
    else if (a.kind != b.kind || a.kind == DKKindDate)
        return [self fail];
    BOOL result;
    if ([operator isEqualToString:@"=="]) result = left == right;
    else if ([@[ @">=", @"=>", @"≥" ] containsObject:operator]) result = left >= right;
    else if ([@[ @"<=", @"=<", @"≤" ] containsObject:operator]) result = left <= right;
    else if ([operator isEqualToString:@">"]) result = left > right;
    else result = left < right;
    return (DKValue){.kind = DKKindBool, .number = DKNumberFromDouble(result)};
}

- (DKNumber)money:(DKNumber)amount from:(NSString *)from to:(NSString *)to {
    NSDecimal fromRate = _rates[from].decimalValue, toRate = _rates[to].decimalValue;
    return DKNumberMultiply(DKNumberDivide(amount, DKNumberFromDecimal(fromRate)), DKNumberFromDecimal(toRate));
}

- (DKValue)apply:(NSString *)name to:(DKValue *)values count:(NSUInteger)count {
    DKValue x = values[0];
    if ([@[ @"sin", @"cos", @"tan" ] containsObject:name]) {
        // Plain numbers are radians; degrees are written "90°" or "90 deg".
        double radians = x.number.value;
        if (x.kind == DKKindUnit && [x.unit.dimension isKindOfClass:NSUnitAngle.class])
            radians = DKConvertUnit(radians, x.unit, DKUnitWithIdentifier(@"radians"));
        else if (x.kind != DKKindNumber || count != 1)
            return [self fail];
        double result = [name isEqualToString:@"sin"] ? sin(radians) : [name isEqualToString:@"cos"] ? cos(radians) : tan(radians);
        // sin(pi) is 0, not 1.2e-16: the error of pi itself, below what Raycast writes.
        if (fabs(result) < 1e-15) result = 0;
        return Number(DKNumberFromDouble(result));
    }
    if (count == 2 && [@[ @"round", @"gcd", @"lcm", @"max", @"min" ] containsObject:name]) {
        DKValue y = values[1];
        if (x.kind != DKKindNumber || y.kind != DKKindNumber) return [self fail];
        if ([name isEqualToString:@"round"]) return Number(DKNumberRound(x.number, (NSInteger)y.number.value));
        if ([name isEqualToString:@"max"]) return x.number.value >= y.number.value ? x : y;
        if ([name isEqualToString:@"min"]) return x.number.value <= y.number.value ? x : y;
        long long a = llabs((long long)x.number.value), b = llabs((long long)y.number.value), product = a * b;
        while (b) {
            long long t = a % b;
            a = b;
            b = t;
        }
        return Number(DKNumberFromDouble([name isEqualToString:@"gcd"] ? a : (a ? product / a : 0)));
    }
    // Raycast reads "max(1,2)" as the maximum of 1,2 alone where "," is the decimal point.
    if (count == 1 && ([name isEqualToString:@"max"] || [name isEqualToString:@"min"])) return x;
    if (count != 1 || x.kind != DKKindNumber) {
        // abs keeps a quantity's unit.
        if (count == 1 && [name isEqualToString:@"abs"] && x.kind != DKKindBool && x.kind != DKKindDate) {
            if (x.number.value < 0) x.number = DKNumberNegate(x.number);
            return x;
        }
        return [self fail];
    }
    double v = x.number.value, result;
    if ([name isEqualToString:@"round"]) return Number(DKNumberRound(x.number, 0));
    if ([name isEqualToString:@"floor"]) return Number(DKNumberFromDouble(floor(v)));
    if ([name isEqualToString:@"ceil"]) return Number(DKNumberFromDouble(ceil(v)));
    if ([name isEqualToString:@"abs"]) return Number(v < 0 ? DKNumberNegate(x.number) : x.number);
    if ([name isEqualToString:@"fact"]) return [self factorial:x];
    if ([@[ @"asin", @"acos", @"atan", @"arcsin", @"arccos", @"arctan" ] containsObject:name]) {
        // Raycast gives inverse functions as angles in radians.
        result = [name hasSuffix:@"sin"] ? asin(v) : [name hasSuffix:@"cos"] ? acos(v) : atan(v);
        if (isnan(result)) return [self fail];
        return (DKValue){.kind = DKKindUnit, .number = DKNumberFromDouble(result), .unit = DKUnitWithIdentifier(@"radians")};
    }
    if ([name isEqualToString:@"sqrt"]) result = sqrt(v);
    else if ([name isEqualToString:@"cbrt"]) result = cbrt(v);
    else if ([name isEqualToString:@"sinh"]) result = sinh(v);
    else if ([name isEqualToString:@"cosh"]) result = cosh(v);
    else if ([name isEqualToString:@"tanh"]) result = tanh(v);
    else if ([name isEqualToString:@"log"] || [name isEqualToString:@"log10"]) result = log10(v);
    else if ([name isEqualToString:@"ln"]) result = log(v);
    else if ([name isEqualToString:@"log2"]) result = log2(v);
    else if ([name isEqualToString:@"exp"]) result = exp(v);
    else return [self fail];
    // Out of range, as sqrt(-1) or ln(0), shows no calculator.
    if (!isfinite(result)) return [self fail];
    return Number(DKNumberFromDouble(result));
}

- (DKValue)convert:(DKValue)value {
    [self skipSpaces];
    NSUInteger start = _pos, length = 0;
    NSDictionary<NSString *, NSNumber *> *bases = @{@"hexadecimal" : @16, @"hex" : @16, @"binary" : @2, @"bin" : @2,
                                                    @"octal" : @8, @"oct" : @8, @"decimal" : @10, @"dec" : @10};
    NSString *word = [self wordAt:_pos].lowercaseString;
    NSNumber *base = bases[word];
    if (base || [word isEqualToString:@"base"]) {
        _pos += word.length;
        if (!base) {
            [self skipSpaces];
            DKValue number = [self readNumber];
            if (_failed) return number;
            base = @((int)number.number.value);
        }
        int radix = base.intValue;
        if (value.kind != DKKindNumber || (radix != 2 && radix != 8 && radix != 10 && radix != 16)) return [self fail];
        if (radix != 10 && value.number.value != floor(value.number.value)) return [self fail];
        _complex = YES;
        value.base = radix == 10 ? 0 : radix;
        return value;
    }
    if ([self matchWord:@"feet"] || [self matchWord:@"ft"]) {
        if (!([self matchWord:@"and"] && ([self matchWord:@"inches"] || [self matchWord:@"in"]))) _pos = start;
        else {
            if (value.kind != DKKindUnit || !DKUnitsConvertible(value.unit, DKUnitWithIdentifier(@"feet"))) return [self fail];
            _complex = YES;
            DKCalcUnit *feet = DKUnitWithIdentifier(@"feet");
            value.number = DKNumberFromDouble(DKConvertUnit(value.number.value, value.unit, feet));
            value.unit = feet;
            value.feetAndInches = YES;
            return value;
        }
    }
    DKCalcUnit *unit = DKUnitAt(_text, _pos, &length);
    if (unit && value.kind == DKKindUnit) {
        if (!DKUnitsConvertible(value.unit, unit)) return [self fail];
        _pos += length;
        [self highlight:start];
        value.number = DKNumberFromDouble(DKConvertUnit(value.number.value, value.unit, unit));
        value.unit = unit;
        value.compound = NO;
        value.feetAndInches = NO;
        _target = value;
        return value;
    }
    NSString *currency = DKCurrencyAt(_text, _pos, &length);
    if (currency && value.kind == DKKindMoney && _rates[currency]) {
        _pos += length;
        [self highlight:start];
        value.number = [self money:value.number from:value.currency to:currency];
        value.currency = currency;
        _target = value;
        return value;
    }
    DKTimeZoneMatch zone = [_calendar timeZoneAt:_text index:_pos highlights:_highlights];
    if (zone.length && value.kind == DKKindDate) {
        _pos += zone.length;
        value.moment = [_calendar moment:value.moment inTimeZone:zone];
        return value;
    }
    return [self fail];
}

@end

#pragma mark Answers

/// "1 hour 30 min", "1 day 3 hours 46 min 40 s".
static NSString *Timespan(double seconds, NSString *decimal, NSString *grouping) {
    long long whole = (long long)round(seconds * 1000);
    NSMutableArray *parts = [NSMutableArray new];
    long long days = whole / 86400000, hours = whole / 3600000 % 24, minutes = whole / 60000 % 60;
    if (days) [parts addObject:[NSString stringWithFormat:@"%lld %@", days, days == 1 ? @"day" : @"days"]];
    if (hours) [parts addObject:[NSString stringWithFormat:@"%lld %@", hours, hours == 1 ? @"hour" : @"hours"]];
    if (minutes) [parts addObject:[NSString stringWithFormat:@"%lld min", minutes]];
    double rest = (whole % 60000) / 1000.0;
    if (rest || !parts.count) [parts addObject:[DKFormatNumber(DKNumberFromDouble(rest), decimal, grouping) stringByAppendingString:@" s"]];
    return [parts componentsJoinedByString:@" "];
}

/// "5 feet 10,8661417323 inches", "1 inch".
static NSString *FeetAndInches(double feet, NSString *decimal, NSString *grouping) {
    double whole = floor(feet);
    DKNumber inches = DKNumberRound(DKNumberFromDouble((feet - whole) * 12), 10);
    if (inches.value >= 12) {
        whole += 1;
        inches = DKNumberFromDouble(0);
    }
    DKCalcUnit *footUnit = DKUnitWithIdentifier(@"feet"), *inchUnit = DKUnitWithIdentifier(@"inches");
    NSMutableArray *parts = [NSMutableArray new];
    if (whole) [parts addObject:[footUnit write:DKFormatNumber(DKNumberFromDouble(whole), decimal, grouping) value:whole]];
    if (inches.value || !whole) [parts addObject:[inchUnit write:DKFormatNumber(inches, decimal, grouping) value:inches.value]];
    return [parts componentsJoinedByString:@" "];
}

static NSString *InBase(DKNumber number, int base) {
    unsigned long long value = (unsigned long long)llabs((long long)number.value);
    NSMutableString *digits = [NSMutableString new];
    do {
        [digits insertString:[NSString stringWithFormat:@"%C", (unichar)"0123456789ABCDEF"[value % (unsigned)base]] atIndex:0];
        value /= (unsigned)base;
    } while (value);
    NSString *prefix = base == 16 ? @"0x" : base == 2 ? @"0b" : @"0o";
    return [NSString stringWithFormat:@"%@%@%@", number.value < 0 ? @"-" : @"", prefix, digits];
}

/// Pwn in Raycast's frontend: the first bracket, percent sign or known function decides;
/// otherwise a lone operator names the expression, unless it ends the query.
static NSString *ExpressionLabel(NSArray<NSString *> *tokens, NSString *query) {
    NSString *operator = nil;
    for (NSString *token in tokens) {
        if ([token isEqualToString:@"("]) return @"Expression";
        if ([token isEqualToString:@"%%"]) return @"Percentage";
        if ([token hasPrefix:@"f:"]) {
            NSString *label = FunctionLabels()[[token substringFromIndex:2]];
            if (label) return label;
            continue;
        }
        if (operator) return @"Expression";
        operator = token;
    }
    NSString *trimmed = [query stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (!operator || [trimmed hasSuffix:operator]) return @"Expression";
    return OperatorLabels()[operator] ?: @"Expression";
}

/// Raycast keeps letters-only queries out of the calculator, but for a few date words.
static BOOL IsWordOnly(NSString *query) {
    for (NSUInteger i = 0; i < query.length; i++)
        if (!IsLetter([query characterAtIndex:i])) return NO;
    return YES;
}

DKCalculation *DKCalculate(NSString *query, NSLocale *locale, NSDictionary<NSString *, NSDecimalNumber *> *rates,
                           NSTimeZone *timeZone, NSDate *now) {
    NSString *trimmed = [query stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (!trimmed.length) return nil;
    NSString *text = query;
    // A short name that starts with a letter, like "m3" or "a1", is someone looking for an
    // app rather than one cubic metre.
    if (trimmed.length <= 3 && IsLetter([trimmed characterAtIndex:0]) &&
        [trimmed rangeOfCharacterFromSet:NSCharacterSet.alphanumericCharacterSet.invertedSet].location == NSNotFound)
        return nil;
    BOOL wordOnly = IsWordOnly(trimmed);
    if (wordOnly) {
        NSString *word = trimmed.lowercaseString;
        if ([word isEqualToString:@"time"]) text = @"now";
        else if (![@[ @"now", @"today", @"tomorrow", @"yesterday" ] containsObject:word]) return nil;
    }

    DKCalcParser *parser = [DKCalcParser new];
    parser->_text = text;
    parser->_length = text.length;
    NSString *decimal = locale.decimalSeparator ?: @".", *grouping = locale.groupingSeparator ?: @",";
    parser->_decimal = [decimal characterAtIndex:0];
    parser->_grouping = grouping.length ? [grouping characterAtIndex:0] : 0;
    parser->_rates = rates;
    parser->_calendar = [[DKCalendarContext alloc] initWithLocale:locale timeZone:timeZone now:now];
    parser->_highlights = [NSMutableArray new];
    parser->_replacements = [NSMutableDictionary new];
    parser->_labelTokens = [NSMutableArray new];
    DKValue value = [parser parse];
    if (parser->_failed) return nil;

    BOOL lone = !parser->_complex && parser->_conversions == 0;
    BOOL conversion = !parser->_complex && parser->_conversions == 1 && (parser->_target.unit || parser->_target.currency);
    DKValue quantity = parser->_quantity;
    // A number written in a base is read, not kept: "0xff" is 255, but "0xff + 1" is 0x100.
    if (lone) value.base = 0;
    // A lone quantity is converted to its usual counterpart: km to mi, °F to °C, dollars to
    // the local currency.
    if (lone && value.kind == DKKindUnit && value.unit.counterpart && !value.compound) {
        DKCalcUnit *to = value.unit.counterpart;
        // Raycast writes metres in feet and inches.
        BOOL meters = [value.unit.identifier isEqualToString:@"meters"];
        value.number = DKNumberFromDouble(DKConvertUnit(value.number.value, value.unit, to));
        value.unit = to;
        value.feetAndInches = meters;
    } else if (lone && value.kind == DKKindMoney) {
        NSString *local = locale.currencyCode ?: @"USD";
        NSString *to = [value.currency isEqualToString:local] ? @"USD" : local;
        if (!rates[to]) return nil;
        value.number = [parser money:value.number from:value.currency to:to];
        value.currency = to;
    }

    DKCalculation *calculation = [DKCalculation new];
    calculation.query = query;
    NSString *label = ExpressionLabel(parser->_labelTokens, query), *answerLabel = @"Result";
    NSString *answer;
    switch (value.kind) {
    case DKKindNumber:
        if (value.base) {
            answer = InBase(value.number, value.base);
            calculation.unformattedAnswer = DKJavaScriptNumber(value.number.value);
        } else {
            answer = DKFormatNumber(value.number, decimal, grouping);
            calculation.unformattedAnswer = DKJavaScriptNumber(value.number.value);
            NSString *words = [answer rangeOfCharacterFromSet:NSCharacterSet.letterCharacterSet].location == NSNotFound ? DKSpellNumber(value.number) : nil;
            answerLabel = words ?: answerLabel;
        }
        break;
    case DKKindPercent:
        answer = [DKFormatNumber(DKNumberMultiply(value.number, DKNumberFromString(@"100")), decimal, grouping) stringByAppendingString:@"%"];
        calculation.unformattedAnswer = DKJavaScriptNumber(value.number.value);
        break;
    case DKKindBool:
        answer = value.number.value ? @"true" : @"false";
        break;
    case DKKindUnit: {
        BOOL timespan = value.unit.isDuration && parser->_conversions == 0 &&
                        (value.compound || (lone && ([quantity.unit.identifier isEqualToString:@"minutes"] ||
                                                     [quantity.unit.identifier isEqualToString:@"seconds"])));
        if (timespan) {
            answer = Timespan(DKConvertUnit(value.number.value, value.unit, DKUnitWithIdentifier(@"seconds")), decimal, grouping);
            if (lone) label = quantity.unit.label;
            break;
        }
        answer = value.feetAndInches ? FeetAndInches(value.number.value, decimal, grouping)
                                     : [value.unit write:DKFormatNumber(value.number, decimal, grouping) value:DKNumberRound(value.number, 10).value];
        calculation.unformattedAnswer = DKJavaScriptNumber(value.number.value);
        answerLabel = value.unit.label;
        label = conversion || lone ? quantity.unit.label : @"Expression";
        if (parser->_untilLabels) {
            label = parser->_untilLabels[0];
            answerLabel = parser->_untilLabels[1];
        }
        break;
    }
    case DKKindMoney: {
        // Money is worked out in full and written, and copied, to the cent.
        DKNumber cents = DKNumberRound(value.number, [value.currency isEqualToString:@"JPY"] ? 0 : 2);
        answer = DKFormatMoney(cents, value.currency, decimal, grouping);
        calculation.unformattedAnswer = DKJavaScriptNumber(cents.value);
        calculation.usesCurrency = YES;
        answerLabel = DKCurrencyName(value.currency);
        label = conversion || lone ? DKCurrencyName(quantity.currency) : @"Expression";
        break;
    }
    case DKKindDate: {
        DKMomentDescription *description = [parser->_calendar describe:value.moment];
        answer = description.answer;
        label = description.expressionLabel ?: label;
        answerLabel = description.answerLabel;
        break;
    }
    }
    if ([calculation.unformattedAnswer isEqualToString:answer]) calculation.unformattedAnswer = nil;
    calculation.answer = answer;
    calculation.expressionLabel = label;
    calculation.answerLabel = answerLabel;

    // A query that is its own answer shows nothing: "5", "-2", "2 mm".
    if ([answer isEqualToString:query]) return nil;
    if (value.kind == DKKindNumber && !value.base && [trimmed isEqualToString:DKJavaScriptNumber(value.number.value)]) return nil;

    NSMutableString *expression = [query mutableCopy];
    if (text == query)
        for (NSNumber *index in parser->_replacements)
            [expression replaceCharactersInRange:NSMakeRange(index.unsignedIntegerValue, 1) withString:parser->_replacements[index]];
    calculation.expression = expression;
    calculation.highlights = text == query ? parser->_highlights : @[];

    if (conversion || (lone && (quantity.unit || quantity.currency) && (value.unit != quantity.unit || ![value.currency isEqual:quantity.currency]))) {
        NSString *from = quantity.unit ? quantity.unit.symbol : quantity.currency;
        NSString *to = value.unit ? value.unit.symbol : value.currency;
        NSString *word = [query containsString:@" in "] ? @"in" : @"to";
        // Raycast keeps the quantity and swaps the units: "10 km to mi" becomes "10 mi to km ".
        calculation.swappedQuery = [NSString stringWithFormat:@"%@ %@ %@ %@ ", DKJavaScriptNumber(quantity.number.value), to, word, from];
    }
    return calculation;
}
