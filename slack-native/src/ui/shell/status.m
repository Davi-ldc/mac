// Owns the "Set a status" dialog: its fields, the suggestions and the time a status clears.
#import "render/document.h"
#import "render/emoji.h"
#import "render/strings.h"
#import "ui/emoji/picker.h"
#import "ui/kit/dialog.h"
#import "ui/kit/forms.h"
#import "ui/kit/hoverview.h"
#import "ui/kit/label.h"
#import "ui/shell/status.h"

/// c-sk-modal's default 520 pt and its 28 pt padding; suggestion rows 36 tall with the emoji's
/// 22 pt box 4 pt in and the text from 34.
static const CGFloat kWidth = 520, kInner = kWidth - 2 * 28, kRow = 36, kEmojiBox = 22, kRowText = 34, kFieldGap = 16, kEmojiButton = 28;
/// Slack's status without an emoji of its own.
static NSString *const kDefaultEmoji = @"speech_balloon";

NSArray<NSString *> *SNStatusDurations(void) { return @[ @"30_minutes", @"1_hour", @"4_hours", @"all_day", @"all_next_day", @"week", @"no_expiration" ]; }

NSTimeInterval SNStatusExpiration(NSString *duration, NSDate *now) {
    NSCalendar *calendar = NSCalendar.currentCalendar;
    NSDictionary<NSString *, NSNumber *> *minutes = @{@"30_minutes" : @30, @"1_hour" : @60, @"4_hours" : @240};
    if (minutes[duration]) return now.timeIntervalSince1970 + minutes[duration].doubleValue * 60;
    NSDate *today = [calendar startOfDayForDate:now], *end = nil, *week;
    if ([duration isEqualToString:@"all_day"]) end = [calendar dateByAddingUnit:NSCalendarUnitDay value:1 toDate:today options:0];
    if ([duration isEqualToString:@"all_next_day"]) end = [calendar dateByAddingUnit:NSCalendarUnitDay value:2 toDate:today options:0];
    if ([duration isEqualToString:@"week"] && [calendar rangeOfUnit:NSCalendarUnitWeekOfYear startDate:&week interval:NULL forDate:now])
        end = [calendar dateByAddingUnit:NSCalendarUnitWeekOfYear value:1 toDate:week options:0];
    // The last second of the day or week.
    return end ? end.timeIntervalSince1970 - 1 : 0;
}

/// Slack's own suggestions (its default custom_status_presets: emoji, text, canonical text,
/// duration), for a team that sends none.
static NSArray<NSArray<NSString *> *> *DefaultPresets(void) {
    return @[
        @[ @":spiral_calendar_pad:", @"In a meeting", @"In a meeting", @"1_hour" ], @[ @":bus:", @"Commuting", @"Commuting", @"30_minutes" ],
        @[ @":face_with_thermometer:", @"Out sick", @"Out sick", @"all_day" ], @[ @":palm_tree:", @"Vacationing", @"Vacationing", @"no_expiration" ],
        @[ @":house_with_garden:", @"Working remotely", @"Working remotely", @"all_day" ]
    ];
}

/// The string keys of Slack's own suggestions by canonical text: they show in the user's
/// language, as Slack's client translates them.
static NSDictionary<NSString *, NSString *> *DefaultKeys(void) {
    return @{@"In a meeting" : @"shell.status.meeting", @"Commuting" : @"shell.status.commuting", @"Out sick" : @"shell.status.sick",
             @"Vacationing" : @"shell.status.vacation", @"Working remotely" : @"shell.status.remote"};
}

static NSString *WithoutColons(NSString *emoji) { return [emoji stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@":"]]; }

/// A suggestion: its emoji and text, the time it clears after in the secondary colour.
@interface SNStatusSuggestionRow : SNHoverView
@property (nonatomic, copy) NSString *emoji, *title, *detail;
@end

@implementation SNStatusSuggestionRow

- (BOOL)isFlipped { return YES; }

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    CGContextSetShouldSmoothFonts(NSGraphicsContext.currentContext.CGContext, false);
    SNDrawEmoji(self.emoji, kEmojiBox, NSMakeRect(4, (kRow - kEmojiBox) / 2, kEmojiBox, kEmojiBox), self.imageHolder);
    NSFont *font = SNFont(SNFontSizeBase, SNFontWeightRegular);
    CGFloat titleWidth = SNTextWidth(self.title, font);
    SNDrawText(self.title, font, SNColorContentPry, kRow, NSTextAlignmentLeft, 1, NSMakeRect(kRowText, 0, NSWidth(self.bounds) - kRowText, kRow));
    SNDrawText([@" – " stringByAppendingString:self.detail], font, SNColorContentSec, kRow, NSTextAlignmentLeft, 1,
               NSMakeRect(kRowText + titleWidth, 0, MAX(0, NSWidth(self.bounds) - kRowText - titleWidth), kRow));
}

@end

/// The emoji button over the field's icon: the chosen emoji, else the field's own smiley.
@interface SNStatusEmojiButton : SNHoverView
@property (nonatomic, copy) NSString *emoji;
@end

@implementation SNStatusEmojiButton

- (BOOL)isFlipped { return YES; }

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    if (!self.emoji.length) return;
    [SNColor(SNColorBasePry) setFill];
    NSRectFill(NSInsetRect(self.bounds, 4, 4));
    SNDrawEmoji(self.emoji, 18, NSMakeRect((kEmojiButton - 18) / 2, (kEmojiButton - 18) / 2, 18, 18), self.imageHolder);
}

@end

@interface SNStatusForm : NSView
@end

@implementation SNStatusForm
- (BOOL)isFlipped { return YES; }
@end

@implementation SNStatusDialog {
    id<SNSource> _source;
    NSDate *_now;
    SNConfirmDialog *_dialog;
    SNStatusForm *_form;
    SNFormInput *_input;
    SNStatusEmojiButton *_emojiButton;
    NSView *_suggestionsLabel, *_clearLabel;
    NSArray<SNStatusSuggestionRow *> *_rows;
    /// The suggestions as shown: @[emoji, text, canonical, duration].
    NSArray<NSArray<NSString *> *> *_presets;
    SNFormSelect *_clear;
    /// Slack's words for the chosen suggestion while its text is unchanged.
    NSString *_canonical, *_canonicalText;
}

static SNStatusDialog *current;

+ (SNStatusDialog *)current { return current && current->_dialog == SNConfirmDialog.current ? current : nil; }

+ (instancetype)showInWindow:(NSWindow *)window source:(id<SNSource>)source now:(NSDate *)now {
    SNStatusDialog *status = [self new];
    status->_source = source;
    status->_now = now;
    [status build];
    __weak SNStatusDialog *weakStatus = status;
    status->_dialog = [SNConfirmDialog showFormInWindow:window
                                                  title:SNLocalized(@"shell.status.title")
                                              accessory:status->_form
                                                  width:kWidth
                                           confirmTitle:SNLocalized(@"shell.status.save")
                                              confirmed:^{ [weakStatus submit]; }];
    if (!status->_dialog) return nil;
    SNUser *me = source.me;
    status.emoji = WithoutColons(me.statusEmoji ?: @"");
    status.text = me.statusText ?: @"";
    [status->_input focus];
    current = status;
    return status;
}

- (void)build {
    _form = [[SNStatusForm alloc] initWithFrame:NSMakeRect(0, 0, kInner, 0)];
    __weak SNStatusDialog *weakSelf = self;
    _input = [[SNFormInput alloc] initWithPlaceholder:SNLocalized(@"shell.status.placeholder") icon:@"emoji"];
    _input.changed = ^(NSString *text) { [weakSelf update]; };
    _emojiButton = [[SNStatusEmojiButton alloc] initWithFrame:NSMakeRect(4, (SNFormControlHeight - kEmojiButton) / 2, kEmojiButton, kEmojiButton)];
    _emojiButton.overlayRadius = 4;
    _emojiButton.tooltip = SNLocalized(@"shell.status.emoji");
    _emojiButton.action = ^(SNHoverView *button) {
        SNStatusDialog *status = weakSelf;
        if (!status) return;
        [SNEmojiPicker showForRect:button.bounds inView:button placement:SNPlacementBelow source:status->_source completion:^(NSString *name) { status.emoji = name; }];
    };
    [_input addSubview:_emojiButton];
    _suggestionsLabel = SNFormLabel(SNLocalizedFormat(@"shell.status.suggestions", _source.workspace.name ?: @""));
    NSMutableArray *presets = [NSMutableArray new], *rows = [NSMutableArray new];
    for (NSArray<NSString *> *preset in _source.workspace.statusPresets.count ? _source.workspace.statusPresets : DefaultPresets()) {
        NSString *key = DefaultKeys()[preset[2]], *text = key ? SNLocalized(key) : preset[1];
        [presets addObject:@[ preset[0], text, preset[2], preset[3] ]];
        SNStatusSuggestionRow *row = [[SNStatusSuggestionRow alloc] initWithFrame:NSMakeRect(0, 0, kInner, kRow)];
        row.emoji = WithoutColons(preset[0]);
        row.title = text;
        row.detail = SNLocalized([@"shell.status.clear." stringByAppendingString:preset[3]]);
        row.overlayRadius = 6;
        NSUInteger index = rows.count;
        row.action = ^(SNHoverView *view) { [weakSelf chooseSuggestionAtIndex:index]; };
        [rows addObject:row];
    }
    _presets = presets;
    _rows = rows;
    _clearLabel = SNFormLabel(SNLocalized(@"shell.status.clearAfter"));
    _clear = [[SNFormSelect alloc] initWithFrame:NSMakeRect(0, 0, kInner, SNFormControlHeight)];
    NSMutableArray *choices = [NSMutableArray new];
    for (NSString *duration in SNStatusDurations())
        [choices addObject:[SNFormChoice choiceWithTitle:SNLocalized([@"shell.status.clear." stringByAppendingString:duration]) value:duration]];
    _clear.choices = choices;
    _clear.value = @"all_day";
    for (NSView *view in @[ _input, _suggestionsLabel, _clearLabel, _clear ]) [_form addSubview:view];
    for (NSView *row in _rows) [_form addSubview:row];
    CGFloat y = 0;
    _input.frame = NSMakeRect(0, y, kInner, SNFormControlHeight);
    y += SNFormControlHeight + kFieldGap;
    _suggestionsLabel.frame = NSMakeRect(0, y, kInner, SNFormLabelLine);
    y += SNFormLabelLine + 4;
    for (SNStatusSuggestionRow *row in _rows) {
        row.frame = NSMakeRect(0, y, kInner, kRow);
        y += kRow;
    }
    y += kFieldGap;
    _clearLabel.frame = NSMakeRect(0, y, kInner, SNFormLabelLine);
    y += SNFormLabelLine + SNFormLabelGap;
    _clear.frame = NSMakeRect(0, y, kInner, SNFormControlHeight);
    [_form setFrameSize:NSMakeSize(kInner, y + SNFormControlHeight)];
}

- (NSString *)text { return _input.text; }

- (void)setText:(NSString *)text {
    _input.text = text ?: @"";
    [self update];
}

- (NSString *)emoji { return _emojiButton.emoji ?: @""; }

- (void)setEmoji:(NSString *)emoji {
    _emojiButton.emoji = emoji ?: @"";
    _emojiButton.needsDisplay = YES;
    [self update];
}

- (NSString *)clearAfter { return _clear.value ?: @"all_day"; }
- (void)setClearAfter:(NSString *)clearAfter { _clear.value = clearAfter; }

- (NSArray<NSString *> *)suggestionTitles { return [_rows valueForKey:@"title"]; }

- (void)chooseSuggestionAtIndex:(NSUInteger)index {
    if (index >= _presets.count) return;
    NSArray<NSString *> *preset = _presets[index];
    self.emoji = WithoutColons(preset[0]);
    self.text = preset[1];
    self.clearAfter = preset[3];
    _canonical = preset[2];
    _canonicalText = preset[1];
}

/// Save waits for a status: a text or an emoji.
- (void)update {
    NSString *text = [self.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    _dialog.confirmEnabled = text.length || self.emoji.length;
}

- (void)save { [_dialog confirm]; }
- (void)cancel { [_dialog cancel]; }

- (void)submit {
    NSString *text = [self.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *emoji = self.emoji.length ? self.emoji : kDefaultEmoji;
    NSString *canonical = [self.text isEqualToString:_canonicalText] ? _canonical : @"";
    [_source setMyStatusText:text canonical:canonical emoji:[NSString stringWithFormat:@":%@:", emoji] expiration:SNStatusExpiration(self.clearAfter, _now)];
}

@end
