// Owns dates and time zones for the calculator: date words, times of day, places (from the
// system's zone.tab and the region names), and Raycast's ways of writing them.
#import "calctime.h"
#import "calcunits.h"

@interface DKMoment ()
@property(readwrite) NSDate *date;
@property(readwrite) BOOL hasTime;
@property(readwrite) DKMomentShape shape;
@property(readwrite, nullable) NSTimeZone *timeZone;
/// Where a seeking or converted moment started, and whether it moved by days or more.
@property(nullable) NSDate *start;
@property BOOL movedByDays;
@property(nullable) NSString *place;
/// The year was written ("2026-01-01"), and so is written back.
@property BOOL writtenYear;
@end

@implementation DKMoment
@end

@implementation DKMomentDescription
@end

/// Places by folded lowercase name ("sao paulo", "japan", "pst"): a zone identifier and an
/// ISO country code (empty for abbreviations).
static NSDictionary<NSString *, NSArray<NSString *> *> *Places(void) {
    static NSDictionary *places;
    if (places) return places;
    NSMutableDictionary *all = [NSMutableDictionary new];
    NSMutableDictionary<NSString *, NSString *> *firstZone = [NSMutableDictionary new];
    NSString *table = [NSString stringWithContentsOfFile:@"/usr/share/zoneinfo/zone.tab" encoding:NSUTF8StringEncoding error:nil];
    NSMutableDictionary<NSString *, NSString *> *countryOfZone = [NSMutableDictionary new];
    for (NSString *line in [table componentsSeparatedByString:@"\n"]) {
        NSArray *fields = [line componentsSeparatedByString:@"\t"];
        if ([line hasPrefix:@"#"] || fields.count < 3) continue;
        NSString *country = fields[0], *zone = fields[2];
        countryOfZone[zone] = country;
        if (!firstZone[country]) firstZone[country] = zone;
        NSString *city = [[zone.lastPathComponent stringByReplacingOccurrencesOfString:@"_" withString:@" "] lowercaseString];
        all[city] = @[ zone, country ];
    }
    // Countries spanning zones go by their largest city, as Raycast's "time in brazil" does.
    NSDictionary *main = @{@"US" : @"America/New_York", @"BR" : @"America/Sao_Paulo", @"CA" : @"America/Toronto",
                           @"AU" : @"Australia/Sydney", @"RU" : @"Europe/Moscow", @"MX" : @"America/Mexico_City",
                           @"CN" : @"Asia/Shanghai", @"ID" : @"Asia/Jakarta", @"AR" : @"America/Argentina/Buenos_Aires",
                           @"KZ" : @"Asia/Almaty", @"ES" : @"Europe/Madrid", @"PT" : @"Europe/Lisbon", @"DE" : @"Europe/Berlin",
                           @"CL" : @"America/Santiago", @"NZ" : @"Pacific/Auckland", @"UA" : @"Europe/Kyiv"};
    NSLocale *english = [NSLocale localeWithLocaleIdentifier:@"en"];
    for (NSString *country in firstZone) {
        NSString *name = [english localizedStringForCountryCode:country].lowercaseString;
        if (name) all[name] = @[ main[country] ?: firstZone[country], country ];
    }
    NSDictionary *aliases = @{@"sf" : @"America/Los_Angeles", @"san francisco" : @"America/Los_Angeles", @"la" : @"America/Los_Angeles",
                              @"seattle" : @"America/Los_Angeles", @"nyc" : @"America/New_York", @"washington" : @"America/New_York",
                              @"boston" : @"America/New_York", @"miami" : @"America/New_York", @"usa" : @"America/New_York",
                              @"uk" : @"Europe/London", @"england" : @"Europe/London", @"beijing" : @"Asia/Shanghai",
                              @"mumbai" : @"Asia/Kolkata", @"delhi" : @"Asia/Kolkata", @"new delhi" : @"Asia/Kolkata",
                              @"bangalore" : @"Asia/Kolkata", @"rio" : @"America/Sao_Paulo", @"rio de janeiro" : @"America/Sao_Paulo",
                              @"brasilia" : @"America/Sao_Paulo", @"uae" : @"Asia/Dubai", @"kyiv" : @"Europe/Kyiv"};
    for (NSString *alias in aliases) all[alias] = @[ aliases[alias], countryOfZone[aliases[alias]] ?: @"" ];
    for (NSString *abbreviation in NSTimeZone.abbreviationDictionary)
        all[abbreviation.lowercaseString] = all[abbreviation.lowercaseString] ?: @[ NSTimeZone.abbreviationDictionary[abbreviation], @"" ];
    all[@"utc"] = @[ @"UTC", @"" ];
    all[@"gmt"] = @[ @"GMT", @"" ];
    places = all;
    return places;
}

static BOOL IsLetter(unichar c) { return [NSCharacterSet.letterCharacterSet characterIsMember:c]; }
static BOOL IsDigit(unichar c) { return c >= '0' && c <= '9'; }

@implementation DKCalendarContext {
    NSLocale *_locale;
    NSTimeZone *_zone;
    NSDate *_now;
    NSCalendar *_calendar;
}

- (instancetype)initWithLocale:(NSLocale *)locale timeZone:(NSTimeZone *)timeZone now:(NSDate *)now {
    if (!(self = [super init])) return nil;
    _locale = locale;
    _zone = timeZone;
    _now = now;
    _calendar = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
    _calendar.timeZone = timeZone;
    return self;
}

- (DKMoment *)momentWithDate:(NSDate *)date time:(BOOL)time {
    DKMoment *moment = [DKMoment new];
    moment.date = date;
    moment.hasTime = time;
    return moment;
}

- (NSDate *)today { return [_calendar startOfDayForDate:_now]; }

#pragma mark Reading

/// The words of `text` from `index`, as a folded lowercase string of up to `count` words.
static NSString *Words(NSString *text, NSUInteger index, NSUInteger count, NSUInteger *length) {
    NSUInteger end = index, words = 0;
    while (end < text.length && words < count) {
        NSUInteger start = end;
        while (end < text.length && (IsLetter([text characterAtIndex:end]) || [text characterAtIndex:end] == '.')) end++;
        if (end == start) break;
        words++;
        *length = end - index;
        if (end < text.length && [text characterAtIndex:end] == ' ' && end + 1 < text.length && IsLetter([text characterAtIndex:end + 1])) end++;
        else break;
    }
    NSString *found = [text substringWithRange:NSMakeRange(index, *length)];
    return [found stringByFoldingWithOptions:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch locale:nil];
}

- (DKTimeZoneMatch)timeZoneAt:(NSString *)text index:(NSUInteger)index highlights:(NSMutableArray<NSValue *> *)highlights {
    for (NSUInteger count = 4; count > 0; count--) {
        NSUInteger length = 0;
        NSString *name = Words(text, index, count, &length);
        if (!length) break;
        NSArray<NSString *> *place = Places()[name];
        // Fewer words than asked means the text ran out of them; try those once.
        if (!place) continue;
        NSTimeZone *zone = [NSTimeZone timeZoneWithName:place[0]];
        if (!zone) continue;
        [highlights addObject:[NSValue valueWithRange:NSMakeRange(index, length)]];
        NSString *country = place[1].length ? [[NSLocale localeWithLocaleIdentifier:@"en"] localizedStringForCountryCode:place[1]] : nil;
        return (DKTimeZoneMatch){.length = length, .zone = zone, .place = country};
    }
    return (DKTimeZoneMatch){0};
}

/// "3pm", "3 pm", "15:30", "9:30am", "noon", "midnight": that time of day, as hour and minute.
- (NSDateComponents *)timeAt:(NSString *)text index:(NSUInteger)index length:(NSUInteger *)length {
    NSUInteger wordLength = 0;
    NSString *word = Words(text, index, 1, &wordLength);
    if ([word isEqualToString:@"noon"] || [word isEqualToString:@"midnight"]) {
        *length = wordLength;
        NSDateComponents *parts = [NSDateComponents new];
        // Midnight is the one ahead, as in "hours until midnight".
        parts.hour = [word isEqualToString:@"noon"] ? 12 : 24;
        parts.minute = 0;
        return parts;
    }
    NSScanner *scanner = [NSScanner scannerWithString:text];
    scanner.scanLocation = index;
    scanner.charactersToBeSkipped = nil;
    int hour = 0, minute = 0;
    if (![scanner scanInt:&hour] || hour > 24) return nil;
    BOOL colon = [scanner scanString:@":" intoString:NULL];
    if (colon && (![scanner scanInt:&minute] || minute > 59)) return nil;
    NSUInteger beforeMeridiem = scanner.scanLocation;
    [scanner scanString:@" " intoString:NULL];
    NSString *meridiem = nil;
    for (NSString *candidate in @[ @"am", @"pm", @"a.m.", @"p.m." ])
        if ([scanner scanString:candidate intoString:NULL] || [scanner scanString:candidate.uppercaseString intoString:NULL]) meridiem = candidate;
    if (meridiem && scanner.scanLocation < text.length && IsLetter([text characterAtIndex:scanner.scanLocation])) meridiem = nil;
    if (!meridiem) scanner.scanLocation = beforeMeridiem;
    if (!meridiem && !colon) return nil;
    if (meridiem && (hour < 1 || hour > 12)) return nil;
    if (meridiem) hour = hour % 12 + ([meridiem hasPrefix:@"p"] ? 12 : 0);
    *length = scanner.scanLocation - index;
    NSDateComponents *parts = [NSDateComponents new];
    parts.hour = hour;
    parts.minute = minute;
    return parts;
}

/// Today, as it is in `zone`, at the time of day `time`.
- (NSDate *)today:(NSDateComponents *)time in:(NSTimeZone *)zone {
    NSCalendar *there = [_calendar copy];
    there.timeZone = zone;
    NSDateComponents *parts = [there components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay fromDate:_now];
    parts.hour = time.hour;
    parts.minute = time.minute;
    return [there dateFromComponents:parts];
}

/// "dec 25", "december 25", "25 december": that day this year; "2026-01-01".
- (NSDate *)dayAt:(NSString *)text index:(NSUInteger)index length:(NSUInteger *)length {
    if (index + 10 <= text.length) {
        NSString *iso = [text substringWithRange:NSMakeRange(index, 10)];
        NSDateComponents *parts = [NSDateComponents new];
        int year = 0, month = 0, day = 0;
        if (sscanf(iso.UTF8String, "%4d-%2d-%2d", &year, &month, &day) == 3 && [iso characterAtIndex:4] == '-' && [iso characterAtIndex:7] == '-' &&
            month >= 1 && month <= 12 && day >= 1 && day <= 31 && (index + 10 == text.length || !IsLetter([text characterAtIndex:index + 10]))) {
            parts.year = year;
            parts.month = month;
            parts.day = day;
            *length = 10;
            return [_calendar dateFromComponents:parts];
        }
    }
    NSDateFormatter *names = [NSDateFormatter new];
    names.locale = [NSLocale localeWithLocaleIdentifier:@"en"];
    NSScanner *scanner = [NSScanner scannerWithString:text];
    scanner.scanLocation = index;
    scanner.charactersToBeSkipped = nil;
    int day = 0;
    BOOL dayFirst = [scanner scanInt:&day];
    if (dayFirst && ![scanner scanString:@" " intoString:NULL]) return nil;
    NSInteger month = 0;
    for (NSArray *list in @[ names.monthSymbols, names.shortMonthSymbols ])
        for (NSUInteger i = 0; i < 12 && !month; i++)
            if ([scanner scanString:list[i] intoString:NULL] || [scanner scanString:[list[i] lowercaseString] intoString:NULL]) month = (NSInteger)i + 1;
    if (!month || (scanner.scanLocation < text.length && IsLetter([text characterAtIndex:scanner.scanLocation]))) return nil;
    if (!dayFirst && !([scanner scanString:@" " intoString:NULL] && [scanner scanInt:&day])) return nil;
    if (day < 1 || day > 31) return nil;
    *length = scanner.scanLocation - index;
    NSDateComponents *parts = [_calendar components:NSCalendarUnitYear fromDate:_now];
    parts.month = month;
    parts.day = day;
    return [_calendar dateFromComponents:parts];
}

- (DKMoment *)momentAt:(NSString *)text index:(NSUInteger)index length:(NSUInteger *)length
            highlights:(NSMutableArray<NSValue *> *)highlights {
    NSUInteger used = 0;
    NSDateComponents *time = [self timeAt:text index:index length:&used];
    if (time) {
        DKMoment *moment = [self momentWithDate:[self today:time in:_zone] time:YES];
        [highlights addObject:[NSValue valueWithRange:NSMakeRange(index, used)]];
        // The zone the time is in, on that zone's today: "3pm london", "3pm in tokyo", "9am sf".
        NSUInteger at = index + used;
        while (at < text.length && [text characterAtIndex:at] == ' ') at++;
        NSUInteger zoneAt = at;
        if ([[text substringFromIndex:at].lowercaseString hasPrefix:@"in "]) zoneAt = at + 3;
        DKTimeZoneMatch zone = zoneAt < text.length ? [self timeZoneAt:text index:zoneAt highlights:highlights] : (DKTimeZoneMatch){0};
        if (zone.length) {
            moment.date = [self today:time in:zone.zone];
            // Raycast then names the local zone on the card ("Your time").
            moment.timeZone = _zone;
            used = zoneAt + zone.length - index;
        }
        *length = used;
        return moment;
    }
    NSDate *day = [self dayAt:text index:index length:&used];
    if (day) {
        [highlights addObject:[NSValue valueWithRange:NSMakeRange(index, used)]];
        *length = used;
        DKMoment *moment = [self momentWithDate:day time:NO];
        moment.writtenYear = used == 10 && IsDigit([text characterAtIndex:index]);
        return moment;
    }
    NSUInteger wordLength = 0;
    NSString *word = Words(text, index, 1, &wordLength);
    if (!wordLength) return nil;
    NSDateComponents *year = [_calendar components:NSCalendarUnitYear fromDate:_now];
    for (NSString *newYear in @[ @"new year's", @"new years", @"new year" ]) {
        if (![[text substringFromIndex:index].lowercaseString hasPrefix:newYear]) continue;
        [highlights addObject:[NSValue valueWithRange:NSMakeRange(index, newYear.length)]];
        *length = newYear.length;
        year.year += 1;
        year.month = 1;
        year.day = 1;
        return [self momentWithDate:[_calendar dateFromComponents:year] time:NO];
    }
    if ([@[ @"now", @"today", @"tomorrow", @"yesterday", @"christmas" ] containsObject:word]) {
        [highlights addObject:[NSValue valueWithRange:NSMakeRange(index, wordLength)]];
        *length = wordLength;
        if ([word isEqualToString:@"now"]) return [self momentWithDate:_now time:YES];
        if ([word isEqualToString:@"christmas"]) {
            year.month = 12;
            year.day = 25;
            return [self momentWithDate:[_calendar dateFromComponents:year] time:NO];
        }
        NSInteger offset = [word isEqualToString:@"tomorrow"] ? 1 : [word isEqualToString:@"yesterday"] ? -1 : 0;
        return [self momentWithDate:[_calendar dateByAddingUnit:NSCalendarUnitDay value:offset toDate:self.today options:0] time:NO];
    }
    // "time in tokyo" and "tokyo time".
    if ([word isEqualToString:@"time"]) {
        NSUInteger at = index + wordLength;
        NSString *rest = [text substringFromIndex:at].lowercaseString;
        NSUInteger skip = [rest hasPrefix:@" in "] ? 4 : [rest hasPrefix:@" at "] ? 4 : 0;
        if (!skip) return nil;
        [highlights addObject:[NSValue valueWithRange:NSMakeRange(index, wordLength)]];
        DKTimeZoneMatch zone = [self timeZoneAt:text index:at + skip highlights:highlights];
        if (!zone.length) return nil;
        *length = at + skip + zone.length - index;
        return [self momentAtPlace:zone];
    }
    DKTimeZoneMatch zone = [self timeZoneAt:text index:index highlights:highlights];
    if (zone.length && [[text substringFromIndex:index + zone.length].lowercaseString hasPrefix:@" time"]) {
        NSUInteger end = index + zone.length + 5;
        if (end < text.length && IsLetter([text characterAtIndex:end])) return nil;
        [highlights addObject:[NSValue valueWithRange:NSMakeRange(end - 4, 4)]];
        *length = end - index;
        return [self momentAtPlace:zone];
    }
    if (zone.length) [highlights removeLastObject];
    return nil;
}

- (DKMoment *)momentAtPlace:(DKTimeZoneMatch)zone {
    DKMoment *moment = [self momentWithDate:_now time:NO];
    moment.shape = DKMomentAtPlace;
    moment.timeZone = zone.zone;
    moment.place = zone.place;
    return moment;
}

#pragma mark Moving

- (DKMoment *)moment:(DKMoment *)moment adding:(double)amount unit:(DKCalcUnit *)unit {
    NSDictionary *calendarUnits = @{@"days" : @(NSCalendarUnitDay), @"weeks" : @(NSCalendarUnitWeekOfYear),
                                    @"months" : @(NSCalendarUnitMonth), @"years" : @(NSCalendarUnitYear)};
    NSNumber *calendarUnit = calendarUnits[unit.identifier];
    NSDate *date;
    // Whole days, weeks, months and years follow the calendar (a month is not 30.4 days).
    if (calendarUnit && amount == floor(amount) && fabs(amount) < 1e6)
        date = [_calendar dateByAddingUnit:calendarUnit.unsignedIntegerValue value:(NSInteger)amount toDate:moment.date options:0];
    else
        date = [moment.date dateByAddingTimeInterval:DKConvertUnit(amount, unit, DKUnitWithIdentifier(@"seconds"))];
    if (!date) return nil;
    DKMoment *moved = [self momentWithDate:date time:moment.hasTime || !calendarUnit];
    moved.shape = DKMomentSeeking;
    moved.timeZone = moment.timeZone;
    moved.start = moment.date;
    moved.movedByDays = calendarUnit != nil;
    return moved;
}

- (DKMoment *)momentAgo:(double)amount unit:(DKCalcUnit *)unit {
    DKMoment *moment = [self moment:[self momentWithDate:_now time:NO] adding:-amount unit:unit];
    moment.hasTime = !moment.movedByDays;
    return moment;
}

- (DKMoment *)moment:(DKMoment *)moment inTimeZone:(DKTimeZoneMatch)zone {
    DKMoment *converted = [self momentWithDate:moment.date time:YES];
    converted.shape = DKMomentConverted;
    converted.timeZone = zone.zone;
    converted.start = moment.date;
    return converted;
}

- (double)amountUntil:(DKMoment *)moment unit:(DKCalcUnit *)unit labels:(NSArray<NSString *> **)labels {
    BOOL days = [@[ @"days", @"weeks", @"months", @"years" ] containsObject:unit.identifier];
    NSDate *then = days ? [_calendar startOfDayForDate:moment.date] : moment.date;
    *labels = days ? @[ [self write:_now template:@"EEEEdMMMM" zone:_zone], [self longDay:then zone:_zone] ]
                   : @[ [self time:_now zone:_zone], [self time:then zone:_zone] ];
    if (!days) return DKConvertUnit([then timeIntervalSinceDate:_now], DKUnitWithIdentifier(@"seconds"), unit);
    NSInteger count = [_calendar components:NSCalendarUnitDay fromDate:self.today toDate:then options:0].day;
    return DKConvertUnit(count, DKUnitWithIdentifier(@"days"), unit);
}

#pragma mark Writing

- (NSString *)write:(NSDate *)date template:(NSString *)template zone:(NSTimeZone *)zone {
    static NSMutableDictionary<NSString *, NSDateFormatter *> *formatters;
    if (!formatters) formatters = [NSMutableDictionary new];
    NSString *key = [NSString stringWithFormat:@"%@|%@|%@", template, zone.name, _locale.localeIdentifier];
    NSDateFormatter *formatter = formatters[key];
    if (!formatter) {
        formatter = [NSDateFormatter new];
        formatter.locale = _locale;
        formatter.timeZone = zone;
        formatter.dateFormat = [NSDateFormatter dateFormatFromTemplate:template options:0 locale:_locale];
        formatters[key] = formatter;
    }
    return [formatter stringFromDate:date];
}

- (NSString *)write:(NSDate *)date format:(NSString *)format zone:(NSTimeZone *)zone {
    static NSMutableDictionary<NSString *, NSDateFormatter *> *formatters;
    if (!formatters) formatters = [NSMutableDictionary new];
    NSString *key = [NSString stringWithFormat:@"%@|%@", format, zone.name];
    NSDateFormatter *formatter = formatters[key];
    if (!formatter) {
        formatter = [NSDateFormatter new];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US"];
        formatter.timeZone = zone;
        formatter.dateFormat = format;
        formatters[key] = formatter;
    }
    return [formatter stringFromDate:date];
}

- (NSString *)time:(NSDate *)date zone:(NSTimeZone *)zone { return [self write:date template:@"jmm" zone:zone]; }

/// The calendar day of `date` against today's, both in `zone`: -1, 0, 1, or more.
- (NSInteger)dayOf:(NSDate *)date zone:(NSTimeZone *)zone {
    NSCalendar *calendar = [_calendar copy];
    calendar.timeZone = zone;
    return [calendar components:NSCalendarUnitDay fromDate:[calendar startOfDayForDate:_now] toDate:[calendar startOfDayForDate:date] options:0].day;
}

- (BOOL)isThisYear:(NSDate *)date {
    return [_calendar component:NSCalendarUnitYear fromDate:date] == [_calendar component:NSCalendarUnitYear fromDate:_now];
}

/// "Sunday, 22 November", with the year when it is not this one.
- (NSString *)longDay:(NSDate *)date zone:(NSTimeZone *)zone {
    return [self write:date template:[self isThisYear:date] ? @"EEEEdMMMM" : @"EEEEdMMMMy" zone:zone];
}

- (NSString *)abbreviationOf:(NSTimeZone *)zone at:(NSDate *)date {
    return [zone localizedName:zone.isDaylightSavingTime ? NSTimeZoneNameStyleShortDaylightSaving : NSTimeZoneNameStyleShortStandard
                        locale:[NSLocale localeWithLocaleIdentifier:@"en_US"]] ?: [zone abbreviationForDate:date];
}

- (DKMomentDescription *)describe:(DKMoment *)moment {
    NSTimeZone *zone = moment.timeZone ?: _zone;
    NSDate *date = moment.date;
    DKMomentDescription *description = [DKMomentDescription new];
    NSInteger day = [self dayOf:date zone:zone];
    NSString *time = [self time:date zone:zone];
    // Raycast's answers name the month first whatever the region ("November 23"); only
    // the clock follows the region's.
    NSString *dayAndMonth = [self write:date format:[self isThisYear:date] && !moment.writtenYear ? @"MMMM d" : @"MMMM d, y" zone:zone];
    // A time in or from another zone is written alone, whatever its day.
    if (moment.shape == DKMomentAtPlace || moment.shape == DKMomentConverted || (moment.hasTime && moment.timeZone)) description.answer = time;
    else if (!moment.hasTime) description.answer = dayAndMonth;
    else if (day == 0) description.answer = time;
    else if (day == 1 || day == -1) description.answer = [NSString stringWithFormat:@"%@ at %@", day == 1 ? @"Tomorrow" : @"Yesterday", time];
    else description.answer = [NSString stringWithFormat:@"%@ at %@", dayAndMonth, time];

    // Raycast's card (Hwn in its frontend): the result's zone when it is not the local one,
    // else its day.
    NSString *label = @"Result";
    if (moment.timeZone && moment.timeZone.secondsFromGMT == _zone.secondsFromGMT) label = @"Your time";
    else if (day == 0) label = [self longDay:date zone:zone];
    else label = [self write:date template:@"EEEE" zone:zone];
    switch (moment.shape) {
    case DKMomentSingle:
        description.expressionLabel = moment.timeZone ? [self abbreviationOf:moment.timeZone at:date]
                                      : [self dayOf:date zone:_zone] == 0 ? [self time:date zone:_zone]
                                                                           : [self longDay:date zone:_zone];
        break;
    case DKMomentSeeking:
        if ([self dayOf:moment.start zone:_zone] == 0)
            description.expressionLabel = moment.movedByDays ? [self longDay:moment.start zone:_zone]
                                                             : [@"Today, " stringByAppendingString:[self time:moment.start zone:_zone]];
        else
            description.expressionLabel = [self longDay:moment.start zone:_zone];
        if (day == 0) label = @"Today";
        else if ([description.answer caseInsensitiveCompare:label] == NSOrderedSame) label = [self write:date template:@"dMMMM" zone:zone];
        break;
    case DKMomentAtPlace:
        description.expressionLabel = moment.place;
        if (zone.secondsFromGMT) label = [self abbreviationOf:zone at:date];
        break;
    case DKMomentConverted:
        description.expressionLabel = [self write:moment.start template:@"MMMMdjmmz" zone:_zone];
        label = [self write:date template:@"MMMMdjmmz" zone:zone];
        break;
    }
    description.answerLabel = label;
    return description;
}

@end
