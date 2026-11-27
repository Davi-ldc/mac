// Dates, times, counts and sizes the way the web client words them in the user's language
// (pt-BR in the captures: "11h44", "Sexta-feira, 20 de novembro", "20 nov à(s) 11h44min29s").
// The strings live in src/render/<locale>.strings.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The clock time a message shows beside its sender: "11h44" / "11:44 AM".
NSString *SNFormatTime(NSDate *date);
/// The timestamp's tooltip: "20 nov à(s) 11h44min29s" / "Nov 20th at 11:44:29 AM".
NSString *SNFormatTimeTooltip(NSDate *date);
/// A date divider's label: "Hoje", "Ontem", "Sexta-feira, 20 de novembro", with the year when
/// it is not `now`'s.
NSString *SNFormatDay(NSDate *date, NSDate *now);
/// The day and time of a thread's parent atop the thread: "Hoje à(s) 11h44", "Sexta-feira à(s)
/// 11h44" within the past week, then "20 de novembro à(s) 11h44", with the year when it is not
/// `now`'s.
NSString *SNFormatDayAndTime(NSDate *date, NSDate *now);
/// A list's date for its newest item (DMs, Activity): the time today, "Ontem", the weekday
/// within the past week, "20 de nov." this year, "20 de nov. de 2025" before.
NSString *SNFormatListDate(NSDate *date, NSDate *now);
/// A file's short date ("Shared by Ana on 19 nov"): "19 nov" this year, "19 nov 2025" before.
NSString *SNFormatShortDate(NSDate *date, NSDate *now);
/// SNFormatTime's wording in another time zone (a person's local time).
NSString *SNFormatTimeInZone(NSDate *date, NSTimeZone *zone);
/// Whether two dates fall on the same calendar day here.
BOOL SNSameDay(NSDate *a, NSDate *b);
/// "há 2 dias", "há 5 minutos", "agora mesmo".
NSString *SNFormatAgo(NSDate *date, NSDate *now);
/// rich_text date elements and <!date^...> tokens: {date_num}, {date}, {date_short},
/// {date_long}, their _pretty forms, {time}, {time_secs} and {ago} inside `format`.
NSString *SNFormatSlackDate(NSTimeInterval timestamp, NSString *format, NSDate *now);
/// "482 KB", "1,2 MB".
NSString *SNFormatFileSize(long long bytes);
/// "17 respostas" / "1 resposta".
NSString *SNFormatReplyCount(NSInteger count);

NS_ASSUME_NONNULL_END
