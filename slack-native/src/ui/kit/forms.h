// The form controls of Slack's dialogs (client-boot-styles: c-input_text, c-input_textarea,
// c-select_button, c-label), for dialogs drawn over the window (ui/kit/dialog.h): a 36 pt
// field or a select on base-pry with a 1 pt otl-pry border and radius 8, which while focused
// trades the border for Slack's focus ring (1 pt otl-hgl-1 and a 5 pt halo of it at 30%).
#import <AppKit/AppKit.h>

#import "ui/kit/hoverview.h"

NS_ASSUME_NONNULL_BEGIN

/// c-input_text and c-input_textarea (medium).
static const CGFloat SNFormControlHeight = 36;
/// The space c-label__text leaves under a label and the 15 pt bold label's line.
static const CGFloat SNFormLabelGap = 8, SNFormLabelLine = 22;

/// c-label: 15 pt bold on a 22 pt line.
NSView *SNFormLabel(NSString *text);

@interface SNFormInput : NSView
/// One line (c-input_text) with an optional icon 12 pt in (c-input_text--with_icon, the text at
/// 28 + 12), or several (c-input_textarea, `height` tall, 8/12 padding, scrolling).
- (instancetype)initWithPlaceholder:(nullable NSString *)placeholder icon:(nullable NSString *)icon;
- (instancetype)initMultilineWithPlaceholder:(nullable NSString *)placeholder height:(CGFloat)height;
@property (nonatomic, copy) NSString *text;
/// What the empty field says (a page's search field changes with the page).
@property (nonatomic, copy, nullable) NSString *placeholder;
/// After every edit.
@property (nonatomic, copy, nullable) void (^changed)(NSString *text);
/// Up, Down and Return while typing (a list under the field follows them); YES when handled.
@property (nonatomic, copy, nullable) BOOL (^keyCommand)(SEL command);
/// Takes the keyboard.
- (void)focus;
@property (nonatomic, readonly) NSView *editor;
@end

@interface SNFormChoice : NSObject
+ (instancetype)choiceWithTitle:(NSString *)title value:(NSString *)value;
@property (nonatomic, readonly, copy) NSString *title, *value;
@end

/// c-select_button (medium): the choice 12 pt in and a 16 pt caret-down at the right; a click
/// opens the choices under it (SNMenu rows, the chosen one checked), scrolling past 240 pt.
@interface SNFormSelect : SNHoverView
@property (nonatomic, copy) NSArray<SNFormChoice *> *choices;
@property (nonatomic, copy, nullable) NSString *value;
/// Shown instead of the chosen choice's title (a custom time described in words), or in
/// content-ter while nothing is chosen.
@property (nonatomic, copy, nullable) NSString *shownTitle, *placeholder;
@property (nonatomic, copy, nullable) void (^changed)(NSString *value);
/// Opens the choices (the click).
- (void)open;
@end

/// c-date_picker_input (medium): the day in a 36 pt field after a calendar icon ("Today",
/// "Tomorrow", else the long date), a caret at the right; a click opens the calendar under it
/// (c-date_picker__dropdown: 16 pt in, radius 6, the c-mini_calendar month 300 pt wide with
/// Slack's year and month buttons around the title, days before `minimumDate` disabled).
@interface SNFormDatePicker : SNHoverView
/// Midnight of the chosen day in NSCalendar.currentCalendar (the user's time zone).
@property (nonatomic) NSDate *date;
@property (nonatomic, nullable) NSDate *minimumDate, *maximumDate;
@property (nonatomic, copy, nullable) void (^changed)(NSDate *day);
/// Opens the calendar (the click); the open one, for tests.
- (void)open;
@property (nonatomic, readonly, nullable) NSView *calendar;
/// What the field shows for `day`.
+ (NSString *)titleForDay:(NSDate *)day now:(NSDate *)now;
@end

/// c-input_radio beside its c-label: a 14 pt circle with a 1.5 pt otl-sec ring (otl-pry under the
/// pointer); chosen, base-inv-hgl-1 with a white dot; the 15 pt label 8 pt after it.
@interface SNFormRadio : SNHoverView
- (instancetype)initWithTitle:(NSString *)title;
@property (nonatomic, readonly, copy) NSString *title;
@property (nonatomic, getter=isChecked) BOOL checked;
@end

NS_ASSUME_NONNULL_END
