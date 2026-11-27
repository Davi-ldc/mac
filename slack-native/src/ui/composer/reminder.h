// Slack's Later "Reminder" dialog (BaseLaterCustomModal, opened by /remind with nothing after it):
// a 500 pt modal with "When" (a date, today on, in the user's time zone), "Time" (every quarter
// hour, from five minutes ahead on today) and "Description" (the composer's editor with its
// mentions and emoji; Return saves, Shift+Return starts a line), then Cancel and Save, which waits
// for a description. Save asks for the reminder (saved.add item_type=reminder) and closes at once,
// as Slack's does.
#import <AppKit/AppKit.h>

#import "source/source.h"

NS_ASSUME_NONNULL_BEGIN

@interface SNReminderDialog : NSObject
/// Opens over `window` at `now`; `threadTS` is where /remind was typed (a saved thread's due time
/// is the starting one, as in Slack).
+ (nullable instancetype)showInWindow:(NSWindow *)window
                               source:(id<SNSource>)source
                         conversation:(NSString *)conversationID
                             threadTS:(nullable NSString *)threadTS
                                  now:(NSDate *)now;
+ (nullable SNReminderDialog *)current;
/// The time Save would ask for, and the day and "HH:mm" chosen (tests).
@property (nonatomic, readonly) NSDate *due;
@property (nonatomic) NSDate *day;
@property (nonatomic, copy) NSString *time;
/// The times offered for the chosen day, as "HH:mm".
@property (nonatomic, readonly) NSArray<NSString *> *timeValues;
/// The description as typed (tests).
@property (nonatomic, copy) NSString *descriptionText;
@property (nonatomic, readonly) BOOL canSave;
- (void)save;
- (void)cancel;
@end

/// Slack's starting time for a new reminder (getDefaultCustomTime): five minutes from `now`, to the
/// minute, rounded up to the next quarter hour.
NSDate *SNReminderDefaultTime(NSDate *now);

NS_ASSUME_NONNULL_END
