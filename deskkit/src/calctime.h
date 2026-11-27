// Dates, times and time zones in the calculator: the words that name them, moving them by
// durations or to other zones, and how Raycast's card writes them.
#import <Foundation/Foundation.h>

@class DKCalcUnit;

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, DKMomentShape) {
    /// A date or time on its own: "now", "tomorrow", "christmas", "3pm london".
    DKMomentSingle,
    /// Reached by moving another by a duration: "today + 30 days", "2 hours ago".
    DKMomentSeeking,
    /// The time somewhere now: "time in tokyo".
    DKMomentAtPlace,
    /// A time shown in another zone: "3pm london in tokyo".
    DKMomentConverted,
};

@interface DKMoment : NSObject
@property(readonly) NSDate *date;
/// A time of day was asked for, not only a day.
@property(readonly) BOOL hasTime;
@property(readonly) DKMomentShape shape;
/// The zone it is shown in; nil for the local one.
@property(readonly, nullable) NSTimeZone *timeZone;
@end

/// A time zone written in a query, and the country it names for the card.
typedef struct {
    NSUInteger length;
    NSTimeZone *zone;
    NSString *place;
} DKTimeZoneMatch;

@interface DKMomentDescription : NSObject
@property(copy) NSString *answer, *answerLabel;
@property(copy, nullable) NSString *expressionLabel;
@end

/// The locale, local time zone and present moment a query is read against.
@interface DKCalendarContext : NSObject
- (instancetype)initWithLocale:(NSLocale *)locale timeZone:(NSTimeZone *)timeZone now:(NSDate *)now;
/// A date or time written at `index`: "now", "today", "christmas", "dec 25", "3pm",
/// "9am sf", "time in tokyo", "tokyo time"; its length in `length`.
- (nullable DKMoment *)momentAt:(NSString *)text index:(NSUInteger)index length:(NSUInteger *)length
                     highlights:(NSMutableArray<NSValue *> *)highlights;
/// `moment` moved by a duration; nil past the calendar's range.
- (nullable DKMoment *)moment:(DKMoment *)moment adding:(double)amount unit:(DKCalcUnit *)unit;
/// "2 days ago".
- (DKMoment *)momentAgo:(double)amount unit:(DKCalcUnit *)unit;
/// The time zone written at `index`, a zero length when there is none.
- (DKTimeZoneMatch)timeZoneAt:(NSString *)text index:(NSUInteger)index highlights:(NSMutableArray<NSValue *> *)highlights;
- (DKMoment *)moment:(DKMoment *)moment inTimeZone:(DKTimeZoneMatch)zone;
/// The time from now until `moment` in `unit`, in whole days for days and longer ("days
/// until christmas"), and what the card writes under each side: now and then.
- (double)amountUntil:(DKMoment *)moment unit:(DKCalcUnit *)unit labels:(NSArray<NSString *> *_Nullable *_Nonnull)labels;
- (DKMomentDescription *)describe:(DKMoment *)moment;
@end

NS_ASSUME_NONNULL_END
