// Owns the date, time and size wording, with formats from the strings tables.
#import "render/format.h"
#import "render/strings.h"

/// One formatter per format and time zone (nil: the Mac's), kept until the language changes.
static NSDateFormatter *ZonedFormatter(NSString *key, NSTimeZone *zone) {
    static NSMutableDictionary<NSString *, NSDateFormatter *> *formatters;
    static NSString *language;
    // The language is set once the user is known; formatters made before then are dropped.
    if (!formatters || ![language isEqualToString:SNLanguage()]) {
        formatters = [NSMutableDictionary new];
        language = SNLanguage();
    }
    NSString *cacheKey = zone ? [NSString stringWithFormat:@"%@ %@", key, zone.name] : key;
    NSDateFormatter *formatter = formatters[cacheKey];
    if (!formatter) {
        formatter = [NSDateFormatter new];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:[language stringByReplacingOccurrencesOfString:@"-" withString:@"_"]];
        formatter.dateFormat = SNLocalized(key);
        if (zone) formatter.timeZone = zone;
        formatters[cacheKey] = formatter;
    }
    return formatter;
}

static NSDateFormatter *Formatter(NSString *key) { return ZonedFormatter(key, nil); }

/// English days take ordinals ("November 20th"); the format marks the day with "{th}".
static NSString *Ordinals(NSString *text, NSDate *date) {
    if (![text containsString:@"{th}"]) return text;
    NSInteger day = [NSCalendar.currentCalendar component:NSCalendarUnitDay fromDate:date];
    NSString *suffix = day % 100 >= 11 && day % 100 <= 13 ? @"th" : day % 10 == 1 ? @"st" : day % 10 == 2 ? @"nd" : day % 10 == 3 ? @"rd" : @"th";
    return [text stringByReplacingOccurrencesOfString:@"{th}" withString:suffix];
}

static NSString *Format(NSString *key, NSDate *date) { return Ordinals([Formatter(key) stringFromDate:date], date); }

/// Abbreviated months come with a period in pt-BR ("nov."); Slack shows them without.
static NSString *WithoutAbbreviationPeriods(NSString *text) { return [text stringByReplacingOccurrencesOfString:@". " withString:@" "]; }

static NSString *Capitalized(NSString *text) {
    return text.length ? [[text substringToIndex:1].uppercaseString stringByAppendingString:[text substringFromIndex:1]] : text;
}

NSString *SNFormatTime(NSDate *date) { return Format(@"render.time", date); }

NSString *SNFormatShortDate(NSDate *date, NSDate *now) {
    NSCalendar *calendar = NSCalendar.currentCalendar;
    BOOL thisYear = [calendar component:NSCalendarUnitYear fromDate:date] == [calendar component:NSCalendarUnitYear fromDate:now];
    NSString *text = WithoutAbbreviationPeriods(Format(thisYear ? @"render.short" : @"render.short.year", date));
    return [text hasSuffix:@"."] ? [text substringToIndex:text.length - 1] : text;
}

NSString *SNFormatTimeTooltip(NSDate *date) { return WithoutAbbreviationPeriods(Format(@"render.time.tooltip", date)); }

BOOL SNSameDay(NSDate *a, NSDate *b) { return [NSCalendar.currentCalendar isDate:a inSameDayAsDate:b]; }

NSString *SNFormatDay(NSDate *date, NSDate *now) {
    NSCalendar *calendar = NSCalendar.currentCalendar;
    if ([calendar isDate:date inSameDayAsDate:now]) return SNLocalized(@"render.day.today");
    NSDate *yesterday = [calendar dateByAddingUnit:NSCalendarUnitDay value:-1 toDate:now options:0];
    if ([calendar isDate:date inSameDayAsDate:yesterday]) return SNLocalized(@"render.day.yesterday");
    BOOL thisYear = [calendar component:NSCalendarUnitYear fromDate:date] == [calendar component:NSCalendarUnitYear fromDate:now];
    return Capitalized(Format(thisYear ? @"render.day" : @"render.day.year", date));
}

NSString *SNFormatDayAndTime(NSDate *date, NSDate *now) {
    NSCalendar *calendar = NSCalendar.currentCalendar;
    NSDate *startOfToday = [calendar startOfDayForDate:now];
    NSInteger days = [calendar components:NSCalendarUnitDay fromDate:[calendar startOfDayForDate:date] toDate:startOfToday options:0].day;
    BOOL thisYear = [calendar component:NSCalendarUnitYear fromDate:date] == [calendar component:NSCalendarUnitYear fromDate:now];
    NSString *day = days == 0   ? SNLocalized(@"render.day.today")
                    : days == 1 ? SNLocalized(@"render.day.yesterday")
                    : days > 1 && days < 7 ? Capitalized(Format(@"render.weekday", date))
                                           : Format(thisYear ? @"render.monthday" : @"render.monthday.year", date);
    return SNLocalizedFormat(@"render.daytime", day, SNFormatTime(date));
}

static NSString *Plural(NSString *key, NSInteger count) {
    if (count == 1) return SNLocalized([key stringByAppendingString:@".one"]);
    return SNLocalizedFormat([key stringByAppendingString:@".other"], @(count).stringValue);
}

NSString *SNFormatAgo(NSDate *date, NSDate *now) {
    NSTimeInterval seconds = MAX(0, [now timeIntervalSinceDate:date]);
    if (seconds < 60) return SNLocalized(@"render.ago.now");
    if (seconds < 3600) return Plural(@"render.ago.minutes", (NSInteger)(seconds / 60));
    if (seconds < 86400) return Plural(@"render.ago.hours", (NSInteger)(seconds / 3600));
    if (seconds < 86400 * 30) return Plural(@"render.ago.days", (NSInteger)(seconds / 86400));
    if (seconds < 86400 * 365) return Plural(@"render.ago.months", (NSInteger)(seconds / (86400 * 30)));
    return Plural(@"render.ago.years", (NSInteger)(seconds / (86400 * 365)));
}

NSString *SNFormatSlackDate(NSTimeInterval timestamp, NSString *format, NSDate *now) {
    if (![format containsString:@"{"]) return format;
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:timestamp];
    NSCalendar *calendar = NSCalendar.currentCalendar;
    NSString * (^pretty)(NSString *) = ^NSString *(NSString *key) {
        if ([calendar isDate:date inSameDayAsDate:now]) return SNLocalized(@"render.date.today");
        if ([calendar isDate:date inSameDayAsDate:[calendar dateByAddingUnit:NSCalendarUnitDay value:-1 toDate:now options:0]])
            return SNLocalized(@"render.date.yesterday");
        if ([calendar isDate:date inSameDayAsDate:[calendar dateByAddingUnit:NSCalendarUnitDay value:1 toDate:now options:0]])
            return SNLocalized(@"render.date.tomorrow");
        return Format(key, date);
    };
    NSMutableString *text = [format mutableCopy];
    void (^replace)(NSString *, NSString * (^)(void)) = ^(NSString *token, NSString * (^value)(void)) {
        if ([text containsString:token]) [text replaceOccurrencesOfString:token withString:value() options:0 range:NSMakeRange(0, text.length)];
    };
    replace(@"{date_num}", ^{ return Format(@"render.date.num", date); });
    replace(@"{date}", ^{ return Format(@"render.date", date); });
    replace(@"{date_short}", ^{ return WithoutAbbreviationPeriods(Format(@"render.date.short", date)); });
    replace(@"{date_long}", ^{ return Format(@"render.date.long", date); });
    replace(@"{date_pretty}", ^{ return pretty(@"render.date"); });
    replace(@"{date_short_pretty}", ^{ return WithoutAbbreviationPeriods(pretty(@"render.date.short")); });
    replace(@"{date_long_pretty}", ^{ return pretty(@"render.date.long"); });
    replace(@"{time}", ^{ return SNFormatTime(date); });
    replace(@"{time_secs}", ^{ return Format(@"render.time.seconds", date); });
    replace(@"{ago}", ^{ return SNFormatAgo(date, now); });
    return text;
}

NSString *SNFormatFileSize(long long bytes) {
    static NSByteCountFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [NSByteCountFormatter new];
        formatter.countStyle = NSByteCountFormatterCountStyleFile;
    });
    return [formatter stringFromByteCount:bytes];
}

NSString *SNFormatReplyCount(NSInteger count) { return Plural(@"render.replies", count); }

NSString *SNFormatTimeInZone(NSDate *date, NSTimeZone *zone) { return [ZonedFormatter(@"render.time", zone) stringFromDate:date]; }

NSString *SNFormatListDate(NSDate *date, NSDate *now) {
    NSCalendar *calendar = NSCalendar.currentCalendar;
    if ([calendar isDate:date inSameDayAsDate:now]) return SNFormatTime(date);
    NSInteger days = [calendar components:NSCalendarUnitDay fromDate:[calendar startOfDayForDate:date] toDate:[calendar startOfDayForDate:now] options:0].day;
    if (days == 1) return SNLocalized(@"render.day.yesterday");
    BOOL sameYear = [calendar component:NSCalendarUnitYear fromDate:date] == [calendar component:NSCalendarUnitYear fromDate:now];
    return Capitalized(Format(days > 0 && days < 7 ? @"render.weekday" : sameYear ? @"render.list.short" : @"render.list.year", date));
}
