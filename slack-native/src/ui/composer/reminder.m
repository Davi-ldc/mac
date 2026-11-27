// Owns the Reminder dialog: its fields, the times it allows and the request Save makes.
#import "model/json.h"
#import "render/format.h"
#import "render/strings.h"
#import "ui/composer/autocomplete.h"
#import "ui/composer/composer.h"
#import "ui/composer/reminder.h"
#import "ui/composer/textview.h"
#import "ui/kit/dialog.h"
#import "ui/kit/forms.h"

/// .p-later_custom_modal: 500 wide (its inline maxWidth wins over the 540 of its class).
static const CGFloat kWidth = 500, kInner = kWidth - 2 * 28;
/// The space under a field before the next label, and the <br> between the picker and the
/// description.
static const CGFloat kFieldGap = 16, kSectionGap = 24;
/// The description's editor: 5 lines at least, 50 at most (numMinLines, numMaxLines).
static const NSUInteger kMinLines = 5, kMaxLines = 50;
static const unsigned short kReturn = 36, kEscape = 53;

static NSCalendar *Calendar(void) { return NSCalendar.currentCalendar; }

/// now + 5 minutes to the minute (getMinimumTime).
static NSDate *MinimumTime(NSDate *now) {
    NSDate *ahead = [now dateByAddingTimeInterval:5 * 60];
    return [Calendar() dateBySettingHour:[Calendar() component:NSCalendarUnitHour fromDate:ahead] minute:[Calendar() component:NSCalendarUnitMinute fromDate:ahead]
                                  second:0
                                  ofDate:ahead
                                 options:0];
}

NSDate *SNReminderDefaultTime(NSDate *now) {
    NSDate *minimum = MinimumTime(now);
    NSInteger minute = [Calendar() component:NSCalendarUnitMinute fromDate:minimum];
    NSInteger up = minute % 15 ? 15 - minute % 15 : 0;
    return [minimum dateByAddingTimeInterval:up * 60];
}

static NSString *ClockValue(NSDate *date) {
    NSDateComponents *parts = [Calendar() components:NSCalendarUnitHour | NSCalendarUnitMinute fromDate:date];
    return [NSString stringWithFormat:@"%02ld:%02ld", (long)parts.hour, (long)parts.minute];
}

static NSDate *OnDay(NSDate *day, NSString *time) {
    NSArray<NSString *> *parts = [time componentsSeparatedByString:@":"];
    return [Calendar() dateBySettingHour:parts.firstObject.integerValue minute:parts.lastObject.integerValue second:0 ofDate:day options:0];
}

/// The description's box: the composer's frame around its editor, which grows with the text.
@interface SNReminderEditorBox : NSView
@property (nonatomic) SNComposerTextView *textView;
@end

@implementation SNReminderEditorBox
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)dirtyRect { SNDrawComposerBox(self.bounds, self.textView.isFocused); }
@end

/// The dialog's fields, top-down.
@interface SNReminderForm : NSView
@end

@implementation SNReminderForm
- (BOOL)isFlipped { return YES; }
@end

@interface SNReminderDialog () <SNComposerTextViewDelegate>
@end

@implementation SNReminderDialog {
    id<SNSource> _source;
    NSString *_conversationID;
    SNConfirmDialog *_dialog;
    NSView *_form;
    NSView *_whenLabel, *_timeLabel, *_descriptionLabel;
    SNFormDatePicker *_datePicker;
    SNFormSelect *_timeSelect;
    SNReminderEditorBox *_editor;
    SNComposerTextView *_textView;
    SNComposerAutocomplete *_autocomplete;
    NSDate *_minimum;
}

static SNReminderDialog *current;

/// The open one: its dialog is the one showing.
+ (SNReminderDialog *)current { return current && current->_dialog == SNConfirmDialog.current ? current : nil; }

+ (instancetype)showInWindow:(NSWindow *)window source:(id<SNSource>)source conversation:(NSString *)conversationID threadTS:(NSString *)threadTS now:(NSDate *)now {
    SNReminderDialog *reminder = [self new];
    reminder->_source = source;
    reminder->_conversationID = [conversationID copy];
    NSDate *start = SNReminderDefaultTime(now);
    reminder->_minimum = MinimumTime(now);
    // A thread whose parent is in Later already starts (and may stay) at that time.
    SNMessage *parent = threadTS ? [source cachedMessageWithTS:threadTS inConversation:conversationID threadTS:nil] : nil;
    double saved = SNJSONDouble(SNJSONObject(parent.json, @"saved"), @"date_due");
    if (saved > 1) {
        start = [NSDate dateWithTimeIntervalSince1970:saved];
        reminder->_minimum = [reminder->_minimum earlierDate:start];
    }
    [reminder buildWithStart:start];
    __weak SNReminderDialog *weakReminder = reminder;
    reminder->_dialog = [SNConfirmDialog showFormInWindow:window
                                                    title:SNLocalized(@"composer.reminder.title")
                                                accessory:reminder->_form
                                                    width:kWidth
                                             confirmTitle:SNLocalized(@"composer.reminder.save")
                                                confirmed:^{ [weakReminder submit]; }];
    if (!reminder->_dialog) return nil;
    reminder->_dialog.passesKey = ^BOOL(NSEvent *event) {
        SNReminderDialog *dialog = weakReminder;
        if (!dialog || !dialog->_textView.isFocused) return NO;
        return event.keyCode == kReturn || (event.keyCode == kEscape && dialog->_autocomplete.isOpen);
    };
    [reminder textChanged];
    [window makeFirstResponder:reminder->_textView];
    current = reminder;
    return reminder;
}

- (void)buildWithStart:(NSDate *)start {
    _form = [[SNReminderForm alloc] initWithFrame:NSMakeRect(0, 0, kInner, 0)];
    __weak SNReminderDialog *weakSelf = self;
    _whenLabel = SNFormLabel(SNLocalized(@"composer.reminder.when"));
    _datePicker = [[SNFormDatePicker alloc] initWithFrame:NSMakeRect(0, 0, kInner, SNFormControlHeight)];
    _datePicker.date = start;
    _datePicker.minimumDate = _minimum;
    _datePicker.changed = ^(NSDate *day) { [weakSelf dayChanged]; };
    _timeLabel = SNFormLabel(SNLocalized(@"composer.reminder.time"));
    _timeSelect = [[SNFormSelect alloc] initWithFrame:NSMakeRect(0, 0, kInner, SNFormControlHeight)];
    _timeSelect.value = ClockValue(start);
    _timeSelect.changed = ^(NSString *value) { [weakSelf update]; };
    _descriptionLabel = SNFormLabel(SNLocalized(@"composer.reminder.description"));
    _editor = [[SNReminderEditorBox alloc] initWithFrame:NSZeroRect];
    _textView = [[SNComposerTextView alloc] initWithFrame:NSZeroRect];
    _textView.placeholder = SNLocalized(@"composer.reminder.placeholder");
    _textView.composerDelegate = self;
    _editor.textView = _textView;
    [_editor addSubview:_textView];
    _autocomplete = [[SNComposerAutocomplete alloc] initWithSource:_source];
    _autocomplete.conversationID = _conversationID;
    _autocomplete.choose = ^(SNRichEntity *entity, NSString *text, NSRange range) {
        SNReminderDialog *dialog = weakSelf;
        if (entity) [dialog->_textView insertEntity:entity text:text replacingRange:range];
    };
    for (NSView *view in @[ _whenLabel, _datePicker, _timeLabel, _timeSelect, _descriptionLabel, _editor ]) [_form addSubview:view];
    [self layoutForm];
}

/// Stacks the fields; the editor is as tall as its text, from 5 lines to 50 or what the window
/// leaves the dialog.
- (void)layoutForm {
    CGFloat y = 0;
    for (NSArray *pair in @[ @[ _whenLabel, _datePicker ], @[ _timeLabel, _timeSelect ], @[ _descriptionLabel, _editor ] ]) {
        NSView *label = pair[0], *control = pair[1];
        if (label == _descriptionLabel) y += kSectionGap - kFieldGap;
        label.frame = NSMakeRect(0, y, kInner, SNFormLabelLine);
        y += SNFormLabelLine + SNFormLabelGap;
        CGFloat height = SNFormControlHeight;
        if (control == _editor) {
            CGFloat chrome = SNComposerTextTop + SNComposerTextBottom;
            CGFloat room = NSHeight(self->_dialog.panel.superview.bounds) - 2 * 28 - 70 - 84 - y - chrome;
            CGFloat lines = MIN(MAX(_textView.contentHeight, kMinLines * SNComposerLineHeight), kMaxLines * SNComposerLineHeight);
            height = ceil((room > kMinLines * SNComposerLineHeight ? MIN(lines, room) : lines) + chrome);
            _textView.frame = NSMakeRect(SNComposerTextInset, SNComposerTextTop, kInner - 2 * SNComposerTextInset, height - chrome);
        }
        control.frame = NSMakeRect(0, y, kInner, height);
        y += height + kFieldGap;
    }
    [_form setFrameSize:NSMakeSize(kInner, y - kFieldGap)];
}

#pragma mark Time

- (NSDate *)day { return _datePicker.date; }

- (void)setDay:(NSDate *)day {
    _datePicker.date = day;
    [self dayChanged];
}

- (NSString *)time { return _timeSelect.value; }

- (void)setTime:(NSString *)time {
    _timeSelect.value = time;
    [self update];
}

/// Quarter hours of the day, from the first allowed minute on the minimum's day.
- (NSArray<NSString *> *)timeValues {
    BOOL first = [Calendar() isDate:_datePicker.date inSameDayAsDate:_minimum];
    NSString *floor = first ? ClockValue(_minimum) : @"00:00";
    NSMutableArray<NSString *> *values = [NSMutableArray new];
    for (NSInteger minutes = 0; minutes < 24 * 60; minutes += 15) {
        NSString *value = [NSString stringWithFormat:@"%02ld:%02ld", (long)(minutes / 60), (long)(minutes % 60)];
        if ([value compare:floor] != NSOrderedAscending) [values addObject:value];
    }
    return values;
}

/// DateTimePicker.handleChange: a time before the minimum becomes the minimum.
- (void)dayChanged {
    if ([OnDay(_datePicker.date, _timeSelect.value) compare:_minimum] == NSOrderedAscending) _timeSelect.value = ClockValue(_minimum);
    [self update];
}

- (NSDate *)due { return [OnDay(_datePicker.date, _timeSelect.value) laterDate:_minimum]; }

- (void)update {
    NSMutableArray<SNFormChoice *> *choices = [NSMutableArray new];
    for (NSString *value in self.timeValues) [choices addObject:[SNFormChoice choiceWithTitle:SNFormatTime(OnDay(_datePicker.date, value)) value:value]];
    _timeSelect.choices = choices;
    BOOL listed = [self.timeValues containsObject:_timeSelect.value];
    _timeSelect.shownTitle = listed ? nil : SNFormatTime(OnDay(_datePicker.date, _timeSelect.value));
    _dialog.confirmEnabled = self.canSave;
}

#pragma mark Description

- (NSString *)descriptionText { return _textView.string; }

- (void)setDescriptionText:(NSString *)descriptionText {
    _textView.document = [[NSAttributedString alloc] initWithString:descriptionText ?: @""];
    [self textChanged];
}

- (BOOL)canSave { return [_textView.string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length > 0; }

- (void)textChanged {
    CGFloat before = NSHeight(_form.frame);
    [self layoutForm];
    if (NSHeight(_form.frame) != before) [_dialog accessoryHeightChanged];
    _editor.needsDisplay = YES;
    [self update];
}

- (void)composerTextViewDidChange:(SNComposerTextView *)textView {
    [self textChanged];
    [self updateAutocomplete];
}

- (void)composerTextViewSelectionDidChange:(SNComposerTextView *)textView { [self updateAutocomplete]; }

- (void)updateAutocomplete {
    NSRange range;
    NSString *query = _textView.isFocused ? [_textView autocompleteQueryRange:&range] : nil;
    if (!query) return [_autocomplete close];
    [_autocomplete showQuery:query range:range aboveRect:_editor.bounds inView:_editor];
}

- (void)composerTextViewFocusDidChange:(SNComposerTextView *)textView {
    _editor.needsDisplay = YES;
    if (!textView.isFocused) [_autocomplete close];
}

- (void)composerTextViewSend:(SNComposerTextView *)textView { [self save]; }
- (void)composerTextViewEditLastMessage:(SNComposerTextView *)textView {}
- (BOOL)composerTextView:(SNComposerTextView *)textView autocompleteCommand:(SEL)command { return [_autocomplete performCommand:command]; }

#pragma mark Saving

- (void)save { [_dialog confirm]; }

- (void)cancel { [_dialog cancel]; }

- (void)submit {
    [_autocomplete close];
    SNRichMessage *message = SNRichMessageFromDocument(_textView.document);
    if (!message) return;
    [_source addReminderWithDescription:message.blocks due:self.due completion:nil];
}

@end
