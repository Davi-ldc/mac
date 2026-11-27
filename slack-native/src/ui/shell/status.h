// Slack's "Set a status" dialog, opened from the user's menu: the emoji button and the status
// field, the team's suggested statuses (prefs.custom_status_presets, in the user's language when
// they are Slack's own; a click fills the field, the emoji and when it clears), "Clear after" and
// Save, which sets it with users.profile.set.
#import <AppKit/AppKit.h>

#import "source/source.h"

NS_ASSUME_NONNULL_BEGIN

@interface SNStatusDialog : NSObject
+ (nullable instancetype)showInWindow:(NSWindow *)window source:(id<SNSource>)source now:(NSDate *)now;
+ (nullable SNStatusDialog *)current;
/// The status as it will be saved (tests).
@property (nonatomic, copy) NSString *text, *emoji;
/// The "Clear after" choice: one of SNStatusDurations().
@property (nonatomic, copy) NSString *clearAfter;
/// The suggestions' texts, top to bottom; choosing one fills the dialog as a click does.
@property (nonatomic, readonly) NSArray<NSString *> *suggestionTitles;
- (void)chooseSuggestionAtIndex:(NSUInteger)index;
- (void)save;
- (void)cancel;
@end

/// Slack's durations, as its presets name them: 30_minutes, 1_hour, 4_hours, all_day (the
/// default), all_next_day, week, no_expiration.
NSArray<NSString *> *SNStatusDurations(void);
/// When a status set at `now` clears after `duration` (0: never), in the user's time zone.
NSTimeInterval SNStatusExpiration(NSString *duration, NSDate *now);

NS_ASSUME_NONNULL_END
