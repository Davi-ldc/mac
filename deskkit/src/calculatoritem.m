// Owns the calculator card's item: Raycast's last-answer rule while typing, the note on
// currency rates, and the card's actions (copying and pasting the answer, putting it in
// the search bar, swapping units, refreshing rates).
#import "calculator.h"
#import "calculatoritem.h"
#import "currencies.h"
#import "hud.h"
#import "paste.h"

/// How long a pasted answer waits on the pasteboard before what was there comes back.
static const NSTimeInterval kPasteRestoreSeconds = 0.5;

static DKCalculation *Calculate(NSString *query) {
    return DKCalculate(query, NSLocale.currentLocale, DKCurrencies.shared.rates, NSTimeZone.localTimeZone, NSDate.date);
}

/// The last query that computed, kept for Raycast's rule in DKCalculatorItem.
static DKCalculation *lastValid;

static BOOL HasLetter(NSString *text) {
    return [text rangeOfCharacterFromSet:NSCharacterSet.letterCharacterSet].location != NSNotFound;
}

/// Raycast's tryCalculate: a query that does not compute but continues the last one that
/// did, with no letters added, shows that one's answer.
static DKCalculation *CalculationFor(NSString *query) {
    DKCalculation *calculation = Calculate(query);
    if (calculation) return lastValid = calculation;
    NSString *last = lastValid.query;
    if (!last || ![query.lowercaseString hasPrefix:last.lowercaseString]) return nil;
    if (query.length >= 3 && HasLetter([query substringFromIndex:last.length])) return nil;
    return [lastValid calculationForQuery:query];
}

/// date-fns's formatDistance with a suffix, which Raycast writes the rates' age with.
static NSString *Ago(NSDate *date) {
    double minutes = round(-date.timeIntervalSinceNow / 60);
    NSString *distance;
    if (minutes < 1) distance = @"less than a minute";
    else if (minutes < 2) distance = @"1 minute";
    else if (minutes < 45) distance = [NSString stringWithFormat:@"%.0f minutes", minutes];
    else if (minutes < 90) distance = @"about 1 hour";
    else if (minutes < 1440) distance = [NSString stringWithFormat:@"about %.0f hours", round(minutes / 60)];
    else if (minutes < 2520) distance = @"1 day";
    else if (minutes < 43200) distance = [NSString stringWithFormat:@"%.0f days", round(minutes / 1440)];
    else distance = @"over a month";
    return [distance stringByAppendingString:@" ago"];
}

static void Copy(NSString *text) {
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:text forType:NSPasteboardTypeString];
}

/// Pastes `text` into the app the panel opened over and then puts back what the pasteboard
/// held, as Raycast's Paste Answer leaves the clipboard as it was. The answer is marked
/// transient, so the clipboard history does not keep it.
static void Paste(DKPicker *picker, NSString *text) {
    NSRunningApplication *target = picker.previousApplication;
    NSPasteboard *board = NSPasteboard.generalPasteboard;
    NSMutableArray<NSPasteboardItem *> *saved = [NSMutableArray new];
    for (NSPasteboardItem *item in board.pasteboardItems) {
        NSPasteboardItem *copy = [NSPasteboardItem new];
        for (NSPasteboardType type in item.types) {
            NSData *data = [item dataForType:type];
            if (data) [copy setData:data forType:type];
        }
        [saved addObject:copy];
    }
    [board clearContents];
    [board setString:text forType:NSPasteboardTypeString];
    [board setData:[NSData data] forType:@"org.nspasteboard.TransientType"];
    [picker dismiss];
    if (!target) return;
    DKPasteInto(target);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kPasteRestoreSeconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [board clearContents];
        if (saved.count) [board writeObjects:saved];
    });
}

static NSArray<DKAction *> *Actions(DKPicker *picker, DKCalculation *calculation) {
    __weak DKPicker *weakPicker = picker;
    NSString *answer = calculation.answer;
    void (^copy)(NSString *, NSString *) = ^(NSString *text, NSString *feedback) {
        Copy(text);
        [weakPicker dismiss];
        DKShowHUD(feedback);
    };
    NSMutableArray *actions = [NSMutableArray new];
    DKAction *copyAnswer = [DKAction actionWithTitle:@"Copy Answer" symbol:@"clipboard" shortcut:@"return" handler:^{
        copy(answer, @"Copied answer to clipboard");
    }];
    copyAnswer.otherShortcuts = @[ [DKShortcut shortcutWithString:@"cmd+shift+c"] ];
    [actions addObject:copyAnswer];
    [actions addObject:[DKAction actionWithTitle:@"Paste Answer" symbol:@"clipboard" shortcut:@"cmd+return" handler:^{
        Paste(weakPicker, answer);
    }]];
    NSString *unformatted = calculation.unformattedAnswer;
    if (unformatted)
        [actions addObject:[DKAction actionWithTitle:@"Copy Unformatted Answer" symbol:@"clipboard" shortcut:@"cmd+opt+c" handler:^{
            copy(unformatted, @"Copied answer to clipboard");
        }]];
    NSString *questionAndAnswer = [NSString stringWithFormat:@"%@ = %@", calculation.query, answer];
    [actions addObject:[DKAction actionWithTitle:@"Copy Question and Answer" symbol:@"clipboard" shortcut:@"cmd+opt+shift+c" handler:^{
        copy(questionAndAnswer, @"Copied to clipboard");
    }]];

    DKAction *toSearchBar = [DKAction actionWithTitle:@"Put Answer in Search Bar" symbol:@"textformat" shortcut:@"cmd+shift+return"
                                              handler:^{ [weakPicker search:answer]; }];
    toSearchBar.startsSection = YES;
    [actions addObject:toSearchBar];
    NSString *swapped = calculation.swappedQuery;
    if (swapped)
        [actions addObject:[DKAction actionWithTitle:@"Swap Units" symbol:@"arrow.left.arrow.right" shortcut:@"cmd+shift+s"
                                             handler:^{ [weakPicker search:swapped]; }]];
    if (calculation.usesCurrency)
        [actions addObject:[DKAction actionWithTitle:@"Refresh Currencies" symbol:@"arrow.clockwise" shortcut:@"cmd+r"
                                             handler:^{ [DKCurrencies.shared refresh:YES]; }]];

    DKAction *help = [DKAction actionWithTitle:@"Discover the power of Calculator" symbol:@"info.circle" shortcut:@"cmd+shift+i"
                                       handler:^{
        [weakPicker hide];
        [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"https://manual.raycast.com/calculator"]];
    }];
    help.startsSection = YES;
    [actions addObject:help];
    return actions;
}

DKItem *DKCalculatorItem(DKPicker *picker, NSString *query) {
    DKCalculation *calculation = CalculationFor(query);
    if (!calculation) return nil;
    if (calculation.usesCurrency) [DKCurrencies.shared refresh:NO];
    DKItem *item = [DKItem new];
    item.title = calculation.answer;
    item.accessory = @"Calculator";
    item.section = @"Calculator";
    item.key = @"calculator";
    item.calculation = calculation;
    NSDate *updated = DKCurrencies.shared.updated;
    item.subtitle = calculation.usesCurrency && updated ? [@"Updated " stringByAppendingString:Ago(updated)] : nil;
    item.actionsTitle = @"Calculator";
    __weak DKPicker *weakPicker = picker;
    item.actionsLoader = ^NSArray<DKAction *> *{ return Actions(weakPicker, calculation); };
    return item;
}

void DKWarmCalculator(void) {
    for (NSString *query in @[ @"1.5 km + 2 m to mi", @"sqrt(2)*3%", @"time in utc" ]) Calculate(query);
    lastValid = nil;
}
