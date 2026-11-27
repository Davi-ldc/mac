// Owns the date picker: its field and the month calendar it opens (sk_calendar's ViewHeader and
// Month, DatePickerCalendar's day states).
#import "render/format.h"
#import "render/icon.h"
#import "render/strings.h"
#import "ui/kit/button.h"
#import "ui/kit/forms.h"
#import "ui/kit/label.h"
#import "ui/kit/popover.h"

/// c-date_picker__dropdown's 16 pt padding around the 300 pt c-calendar_month; the 32 pt header
/// 16 pt above the weekdays (13 pt, 4/6 padding); days 42 pt tall.
static const CGFloat kDropdownPadding = 16, kMonthWidth = 300, kHeader = 32, kHeaderGap = 16, kWeekdays = 26, kDay = 42;
static const CGFloat kHeaderButton = 32, kRing = 32;
/// c-date_picker__select_btn: the caret's 36 pt square at the field's right; the calendar icon
/// 12 pt in, the text at 32 (c-date_picker_input--medium).
static const CGFloat kFieldText = 32, kFieldIcon = 16;
static const SNColorToken kHoverFill = 0x1d9bd133;

static NSCalendar *Calendar(void) { return NSCalendar.currentCalendar; }
static NSDate *Day(NSDate *date) { return [Calendar() startOfDayForDate:date]; }

/// One month of days in weeks starting on Sunday (dayjs' default week), days of other months
/// left blank.
@interface SNFormCalendarView : NSView <SNCursorProvider>
@property (nonatomic) NSDate *month, *selected;
@property (nonatomic, nullable) NSDate *minimum, *maximum;
@property (nonatomic, copy) void (^chose)(NSDate *day);
@end

@implementation SNFormCalendarView {
    NSArray<SNButton *> *_buttons;
    NSTrackingArea *_tracking;
    NSDate *_hovered;
}

- (instancetype)initWithSelected:(NSDate *)selected minimum:(NSDate *)minimum {
    if (!(self = [super initWithFrame:NSZeroRect])) return nil;
    _selected = Day(selected);
    _minimum = minimum ? Day(minimum) : nil;
    _month = [self firstOfMonth:_selected];
    // ViewHeader: previous year, previous month, the title, next month, next year.
    NSArray *specs = @[ @[ @"caret-left-double-full", @"forms.calendar.previousYear", @(-12) ], @[ @"caret-left-full", @"forms.calendar.previousMonth", @(-1) ],
                        @[ @"caret-right-full", @"forms.calendar.nextMonth", @1 ], @[ @"caret-right-double-full", @"forms.calendar.nextYear", @12 ] ];
    NSMutableArray *buttons = [NSMutableArray new];
    __weak SNFormCalendarView *weakSelf = self;
    for (NSArray *spec in specs) {
        SNButton *button = [SNButton iconButtonNamed:spec[0] size:kHeaderButton iconSize:20];
        button.cornerRadius = SNRadiusBase;
        button.overlayRadius = SNRadiusBase;
        button.contentColor = SNColorContentPry;
        button.tooltip = SNLocalized(spec[1]);
        NSInteger months = [spec[2] integerValue];
        button.action = ^(SNButton *sender) { [weakSelf moveBy:months]; };
        [buttons addObject:button];
        [self addSubview:button];
    }
    _buttons = buttons;
    [self updateButtons];
    self.frame = NSMakeRect(0, 0, kMonthWidth + 2 * kDropdownPadding, [self heightForMonth]);
    return self;
}

- (BOOL)isFlipped { return YES; }

- (NSDate *)firstOfMonth:(NSDate *)date {
    NSDateComponents *parts = [Calendar() components:NSCalendarUnitYear | NSCalendarUnitMonth fromDate:date];
    parts.day = 1;
    return [Calendar() dateFromComponents:parts];
}

- (NSInteger)leadingBlanks { return [Calendar() component:NSCalendarUnitWeekday fromDate:_month] - 1; }
- (NSInteger)dayCount { return (NSInteger)[Calendar() rangeOfUnit:NSCalendarUnitDay inUnit:NSCalendarUnitMonth forDate:_month].length; }
- (NSInteger)weekCount { return (self.leadingBlanks + self.dayCount + 6) / 7; }
- (CGFloat)gridTop { return kDropdownPadding + kHeader + kHeaderGap + kWeekdays; }
- (CGFloat)heightForMonth { return self.gridTop + self.weekCount * kDay + kDropdownPadding; }

- (void)moveBy:(NSInteger)months {
    NSDate *month = [Calendar() dateByAddingUnit:NSCalendarUnitMonth value:months toDate:_month options:0];
    if (_minimum && [month compare:[self firstOfMonth:_minimum]] == NSOrderedAscending) month = [self firstOfMonth:_minimum];
    _month = month;
    [self updateButtons];
    NSRect frame = self.frame;
    frame.size.height = [self heightForMonth];
    self.frame = frame;
    self.superview.superview.frame = (NSRect){self.superview.superview.frame.origin, frame.size};
    self.needsDisplay = YES;
}

/// canMoveBackMonth / canMoveBackYear: never to a month wholly before the first allowed day (a
/// year back stops at that month).
- (void)updateButtons {
    NSDate *first = _minimum ? [self firstOfMonth:_minimum] : nil;
    NSDate *back = [Calendar() dateByAddingUnit:NSCalendarUnitMonth value:-1 toDate:_month options:0];
    BOOL enabled = !first || [back compare:first] != NSOrderedAscending;
    for (SNButton *button in @[ _buttons[0], _buttons[1] ]) {
        button.enabled = enabled;
        button.contentColor = enabled ? SNColorContentPry : SNColorContentTer;
    }
}

- (void)layout {
    [super layout];
    CGFloat right = kDropdownPadding + kMonthWidth;
    _buttons[0].frame = NSMakeRect(kDropdownPadding, kDropdownPadding, kHeaderButton, kHeaderButton);
    _buttons[1].frame = NSMakeRect(kDropdownPadding + kHeaderButton, kDropdownPadding, kHeaderButton, kHeaderButton);
    _buttons[2].frame = NSMakeRect(right - 2 * kHeaderButton, kDropdownPadding, kHeaderButton, kHeaderButton);
    _buttons[3].frame = NSMakeRect(right - kHeaderButton, kDropdownPadding, kHeaderButton, kHeaderButton);
}

- (NSRect)rectOfIndex:(NSInteger)index {
    CGFloat width = kMonthWidth / 7;
    return NSMakeRect(kDropdownPadding + (index % 7) * width, self.gridTop + (index / 7) * kDay, width, kDay);
}

- (NSDate *)dayAtPoint:(NSPoint)point {
    for (NSInteger day = 1; day <= self.dayCount; day++)
        if (NSPointInRect(point, [self rectOfIndex:self.leadingBlanks + day - 1]))
            return [Calendar() dateByAddingUnit:NSCalendarUnitDay value:day - 1 toDate:_month options:0];
    return nil;
}

- (BOOL)disabled:(NSDate *)day {
    return (_minimum && [day compare:_minimum] == NSOrderedAscending) || (_maximum && [day compare:_maximum] == NSOrderedDescending);
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_tracking) [self removeTrackingArea:_tracking];
    _tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect owner:self userInfo:nil];
    [self addTrackingArea:_tracking];
}

- (void)mouseMoved:(NSEvent *)event {
    NSDate *day = [self dayAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
    if (day == _hovered || [day isEqual:_hovered]) return;
    _hovered = day;
    self.needsDisplay = YES;
}

- (void)mouseExited:(NSEvent *)event {
    _hovered = nil;
    self.needsDisplay = YES;
}

- (void)mouseDown:(NSEvent *)event {}

- (void)mouseUp:(NSEvent *)event {
    NSDate *day = [self dayAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
    if (day && ![self disabled:day]) self.chose(day);
}

- (NSCursor *)cursorAtPoint:(NSPoint)point {
    NSDate *day = [self dayAtPoint:point];
    return day && ![self disabled:day] ? NSCursor.pointingHandCursor : nil;
}

- (void)drawRect:(NSRect)dirtyRect {
    NSDateFormatter *title = [NSDateFormatter new];
    title.locale = [NSLocale localeWithLocaleIdentifier:SNLanguage()];
    title.timeZone = Calendar().timeZone;
    [title setLocalizedDateFormatFromTemplate:@"MMMMy"];
    SNDrawText([title stringFromDate:_month], SNFont(SNFontSizeBase, SNFontWeightBold), SNColorContentPry, kHeader, NSTextAlignmentCenter, 1,
               NSMakeRect(kDropdownPadding + 2 * kHeaderButton, kDropdownPadding, kMonthWidth - 4 * kHeaderButton, kHeader));
    NSArray<NSString *> *weekdays = [SNLocalized(@"forms.calendar.weekdays") componentsSeparatedByString:@","];
    CGFloat column = kMonthWidth / 7, top = kDropdownPadding + kHeader + kHeaderGap;
    for (NSUInteger i = 0; i < 7 && i < weekdays.count; i++)
        SNDrawText(weekdays[i], SNFont(SNFontSizeCaption, SNFontWeightRegular), SNColorContentSec, kWeekdays - 10, NSTextAlignmentCenter, 1,
                   NSMakeRect(kDropdownPadding + i * column, top + 4, column, kWeekdays - 10));
    NSDate *today = Day(NSDate.date);
    NSFont *font = SNFont(SNFontSizeBase, SNFontWeightRegular);
    for (NSInteger day = 1; day <= self.dayCount; day++) {
        NSDate *date = [Calendar() dateByAddingUnit:NSCalendarUnitDay value:day - 1 toDate:_month options:0];
        NSRect cell = [self rectOfIndex:self.leadingBlanks + day - 1];
        BOOL disabled = [self disabled:date], selected = [date isEqual:_selected], isToday = [date isEqual:today];
        BOOL hovered = !disabled && [date isEqual:_hovered];
        if (disabled) {
            [SNColor(SNColorBaseSec) setFill];
            NSRectFill(cell);
        }
        if (selected) {
            [SNColor(SNColorBaseInvHgl1) setFill];
            [[NSBezierPath bezierPathWithRoundedRect:cell xRadius:SNRadiusBase yRadius:SNRadiusBase] fill];
        } else if (hovered) {
            [SNColor(kHoverFill) setFill];
            NSRectFill(cell);
        }
        [SNColor(hovered ? SNColorOtlHgl1Sec : SNColorOtlTer) setStroke];
        [NSBezierPath strokeRect:NSInsetRect(cell, 0.5, 0.5)];
        if (isToday) {
            NSRect ring = NSMakeRect(NSMidX(cell) - kRing / 2 + 0.5, NSMidY(cell) - kRing / 2 + 0.5, kRing - 1, kRing - 1);
            [SNColor(selected ? 0xffffffff : SNColorOtlHgl1) setStroke];
            [[NSBezierPath bezierPathWithOvalInRect:ring] stroke];
        }
        SNColorToken color = selected ? 0xffffffff : disabled ? SNColorContentTer : isToday ? SNColorContentHgl1 : SNColorContentPry;
        SNDrawText(@(day).stringValue, font, color, kDay, NSTextAlignmentCenter, 1, cell);
    }
}

@end

@implementation SNFormDatePicker {
    __weak SNPopover *_popover;
    __weak SNFormCalendarView *_calendar;
}

+ (NSString *)titleForDay:(NSDate *)day now:(NSDate *)now {
    NSDate *today = Day(now), *tomorrow = [Calendar() dateByAddingUnit:NSCalendarUnitDay value:1 toDate:today options:0];
    if ([Day(day) isEqual:today]) return SNLocalized(@"forms.date.today");
    if ([Day(day) isEqual:tomorrow]) return SNLocalized(@"forms.date.tomorrow");
    return SNFormatSlackDate(day.timeIntervalSince1970, @"{date}", now);
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _date = Day(NSDate.date);
    self.hoverColor = 0;
    __weak SNFormDatePicker *weakSelf = self;
    self.action = ^(SNFormDatePicker *picker) { [weakSelf open]; };
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)setDate:(NSDate *)date {
    _date = Day(date);
    self.needsDisplay = YES;
}

- (NSView *)calendar { return _popover.content ? _calendar : nil; }

- (void)open {
    SNFormCalendarView *calendar = [[SNFormCalendarView alloc] initWithSelected:_date minimum:_minimumDate];
    calendar.maximum = _maximumDate ? Day(_maximumDate) : nil;
    __weak SNFormDatePicker *weakSelf = self;
    calendar.chose = ^(NSDate *day) {
        SNFormDatePicker *picker = weakSelf;
        [SNPopover.current close];
        picker.date = day;
        if (picker.changed) picker.changed(picker.date);
    };
    // c-date_picker__dropdown: base-pry, radius 6, the menu's ring with a 4/12 shadow.
    SNShadowStack shadow = {2, {{0, 0, 0, 1, 0xe8e8e821, NO}, {0, 4, 12, 0, 0x00000014, NO}}};
    SNPanelView *panel = [[SNPanelView alloc] initWithFill:SNColorBasePry radius:SNRadiusMenuLive shadow:shadow];
    panel.frame = calendar.bounds;
    [panel.contentView addSubview:calendar];
    _calendar = calendar;
    _popover = [SNPopover showContent:panel forRect:self.bounds inView:self placement:SNPlacementBelow gap:4];
}

- (void)drawRect:(NSRect)dirtyRect {
    NSRect bounds = self.bounds;
    NSBezierPath *box = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(bounds, 0.5, 0.5) xRadius:SNRadiusLarge - 0.5 yRadius:SNRadiusLarge - 0.5];
    [SNColor(SNColorBasePry) setFill];
    [box fill];
    [SNColor(SNColorOtlPry) setStroke];
    [box stroke];
    CGFloat height = NSHeight(bounds);
    SNDrawIcon(@"calendar", kFieldIcon, SNColorContentSec, NSMakeRect(12, (height - kFieldIcon) / 2, kFieldIcon, kFieldIcon));
    SNDrawText([SNFormDatePicker titleForDay:_date now:NSDate.date], SNFont(SNFontSizeBase, SNFontWeightRegular), SNColorContentPry, height, NSTextAlignmentLeft, 1,
               NSMakeRect(kFieldText + 4, 0, NSWidth(bounds) - kFieldText - 4 - height, height));
    SNDrawIcon(@"caret-down", kFieldIcon, SNColorContentSec, NSMakeRect(NSWidth(bounds) - height + (height - kFieldIcon) / 2, (height - kFieldIcon) / 2, kFieldIcon, kFieldIcon));
}

@end
