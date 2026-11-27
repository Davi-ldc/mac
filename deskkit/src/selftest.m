// Owns `deskkit --selftest`: checks of the parts that run without a screen or keyboard.
#import <Carbon/Carbon.h>
#import <QuartzCore/QuartzCore.h>
#import <mach/mach.h>

#import "calculator.h"
#import "clipboard.h"
#import "clipboardscreen.h"
#import "crypto.h"
#import "detailview.h"
#import "features.h"
#import "formview.h"
#import "listview.h"
#import "panel.h"
#import "picker.h"
#import "press.h"
#import "quicklinks.h"
#import "quicklinkscreens.h"
#import "ranking.h"
#import "support.h"
#import "theme.h"

static int failures;

static void Expect(BOOL condition, const char *what) {
    printf("%s %s\n", condition ? "ok  " : "FAIL", what);
    if (!condition) failures++;
}

/// Lets the history's background writes finish and their results reach the main thread.
static void Settle(void) { [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]]; }

static DKClipboardHistory *History(NSURL *folder, NSString *service) {
    return [[DKClipboardHistory alloc] initWithFolder:folder key:^{ return DKKeychainKey(service, @"clipboard"); }];
}

/// Loads the history and waits for its entries, which are read off the main thread.
static void Load(DKClipboardHistory *history) {
    [history load];
    NSDate *patience = [NSDate dateWithTimeIntervalSinceNow:10];
    while (!history.loaded && patience.timeIntervalSinceNow > 0)
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
}

static void Copy(DKClipboardHistory *history, NSPasteboard *board, NSString *type, id content) {
    [board clearContents];
    if ([content isKindOfClass:NSString.class]) [board setString:content forType:type];
    else [board setData:content forType:type];
    [history recordPasteboard:board];
}

static NSData *TinyImage(NSBitmapImageFileType type) {
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:30 pixelsHigh:20
                                                                    bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
                                                                   colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    return [bitmap representationUsingType:type properties:@{}];
}

static void TestCrypto(NSString *service) {
    NSData *key = DKKeychainKey(service, @"clipboard");
    Expect(key.length == 64, "keychain key created");
    Expect([DKKeychainKey(service, @"clipboard") isEqualToData:key], "keychain key read back");
    NSData *plain = [@"secret clipboard text" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *sealed = DKEncrypt(plain, key);
    Expect([DKDecrypt(sealed, key) isEqualToData:plain], "encrypt then decrypt");
    Expect([sealed rangeOfData:plain options:0 range:NSMakeRange(0, sealed.length)].location == NSNotFound,
           "plaintext absent from sealed data");
    NSMutableData *tampered = [sealed mutableCopy];
    ((uint8_t *)tampered.mutableBytes)[20] ^= 1;
    Expect(DKDecrypt(tampered, key) == nil, "tampered data rejected");
}

static void TestHistory(NSString *service) {
    NSFileManager *files = NSFileManager.defaultManager;
    NSURL *folder = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
    [files createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:nil];
    DKClipboardHistory *history = History(folder, service);
    Load(history);
    NSPasteboard *board = [NSPasteboard pasteboardWithUniqueName];

    Copy(history, board, NSPasteboardTypeString, @"copied once");
    Copy(history, board, NSPasteboardTypeString, @"copied once");
    NSString *head = [@"" stringByPaddingToLength:2000 withString:@"a" startingAtIndex:0];
    Copy(history, board, NSPasteboardTypeString, [head stringByAppendingString:@" first ending"]);
    Copy(history, board, NSPasteboardTypeString, [head stringByAppendingString:@" second ending"]);
    [board clearContents];
    [board setString:@"hunter2" forType:NSPasteboardTypeString];
    [board setData:[NSData data] forType:@"org.nspasteboard.ConcealedType"];
    Expect(DKPasteboardIsPrivate(board), "concealed copy is detected");
    [history recordPasteboard:board];
    Copy(history, board, NSPasteboardTypeTIFF, TinyImage(NSBitmapImageFileTypeTIFF));
    Settle();

    NSArray<DKClip *> *clips = [history clipsMatching:@"" limit:100];
    Expect(clips.count == 4, "one entry per content, concealed copy skipped");
    Expect([history clipsMatching:@"copied" limit:100].count == 1, "copying the same text twice keeps one entry");
    Expect([history clipsMatching:@"aaaaaaaa" limit:100].count == 2,
           "texts that share their first 2000 characters stay apart");
    DKClip *image = clips.firstObject;
    Expect(image.kind == DKClipImage && NSEqualSizes(image.imageSize, NSMakeSize(30, 20)) && image.thumbnail.length,
           "a TIFF copy is kept as an image with its size and thumbnail");
    NSData *png = [history contentOf:image];
    Expect(png.length > 8 && !memcmp(png.bytes, "\x89PNG", 4), "a TIFF copy is stored as PNG");

    BOOL plaintextOnDisk = NO;
    for (NSString *file in [files subpathsAtPath:folder.path]) {
        NSData *data = [NSData dataWithContentsOfFile:[folder.path stringByAppendingPathComponent:file]];
        if ([data rangeOfData:[@"copied once" dataUsingEncoding:NSUTF8StringEncoding] options:0
                        range:NSMakeRange(0, data.length)].location != NSNotFound)
            plaintextOnDisk = YES;
    }
    Expect(!plaintextOnDisk, "history files on disk are encrypted");

    // Leftovers: content whose entry was never written, an entry sealed with another key,
    // and one like it that is past the retention period.
    NSData *junk = [@"sealed with a lost key" dataUsingEncoding:NSUTF8StringEncoding];
    for (NSString *name in @[ @"orphan.data", @"recent.meta", @"recent.data", @"expired.meta", @"expired.data" ])
        [junk writeToURL:[folder URLByAppendingPathComponent:name] atomically:YES];
    [files setAttributes:@{NSFileModificationDate : [NSDate dateWithTimeIntervalSinceNow:-100 * 86400]}
            ofItemAtPath:[folder URLByAppendingPathComponent:@"expired.meta"].path error:nil];
    DKClipboardHistory *reloaded = History(folder, service);
    Load(reloaded);
    Settle();
    Expect([reloaded clipsMatching:@"" limit:100].count == 4, "history survives a restart");
    BOOL (^exists)(NSString *) = ^BOOL(NSString *name) {
        return [files fileExistsAtPath:[folder URLByAppendingPathComponent:name].path];
    };
    Expect(!exists(@"orphan.data"), "content without an entry is swept");
    Expect(exists(@"recent.meta") && exists(@"recent.data"), "an unreadable entry is kept until it would expire");
    Expect(!exists(@"expired.meta") && !exists(@"expired.data"), "an expired unreadable entry goes with its content");

    [board releaseGlobally];
    [files removeItemAtURL:folder error:nil];
}

static void TestHistoryLimits(NSString *service) {
    NSFileManager *files = NSFileManager.defaultManager;
    NSURL *folder = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
    [files createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:nil];
    DKClipboardHistory *history = History(folder, service);
    Load(history);
    NSPasteboard *board = [NSPasteboard pasteboardWithUniqueName];
    NSString * (^text)(NSString *) = ^(NSString *start) { return [start stringByPaddingToLength:600 withString:@"." startingAtIndex:0]; };

    history.entryByteLimit = 1000;
    Copy(history, board, NSPasteboardTypeString, [@"" stringByPaddingToLength:1001 withString:@"x" startingAtIndex:0]);
    Settle();
    Expect([history clipsMatching:@"" limit:10].count == 0, "a copy over the entry limit is not recorded");

    Copy(history, board, NSPasteboardTypeString, text(@"first"));
    Settle();
    unsigned long long entry = history.byteCount;
    history.byteLimit = entry * 3 + entry / 2;
    for (NSString *start in @[ @"second", @"third", @"fourth" ]) Copy(history, board, NSPasteboardTypeString, text(start));
    Settle();
    NSArray<NSString *> *left = [[history clipsMatching:@"" limit:10] valueForKey:@"text"];
    Expect(left.count == 3 && [left[0] hasPrefix:@"fourth"] && [left[2] hasPrefix:@"second"],
           "over the size limit, the oldest entry goes first");
    Expect(history.byteCount <= history.byteLimit, "the history stays within its size limit");
    Expect([files contentsOfDirectoryAtPath:folder.path error:nil].count == 6, "an evicted entry's two files are deleted");

    DKClipboardHistory *reloaded = History(folder, service);
    reloaded.byteLimit = entry * 2 + entry / 2;
    Load(reloaded);
    Settle();
    left = [[reloaded clipsMatching:@"" limit:10] valueForKey:@"text"];
    Expect(left.count == 2 && [left[1] hasPrefix:@"third"], "a history over its size limit at load drops its oldest entries");

    [board releaseGlobally];
    [files removeItemAtURL:folder error:nil];
}

static BOOL RanksFirst(NSString *query, NSString *a, NSString *b) {
    DKRank rankA, rankB;
    BOOL matched = DKRankItem(&rankA, a, nil, nil, nil, [@"selftest:" stringByAppendingString:a], 5, query) &&
                   DKRankItem(&rankB, b, nil, nil, nil, [@"selftest:" stringByAppendingString:b], 5, query);
    return matched && DKCompareRanks(&rankA, a, &rankB, b, query) == NSOrderedAscending;
}

static void TestHistoryKeyWait(NSString *service) {
    NSFileManager *files = NSFileManager.defaultManager;
    NSURL *folder = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
    [files createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:nil];
    NSPasteboard *board = [NSPasteboard pasteboardWithUniqueName];
    // Stands for the Keychain: a read waits as on a prompt (not for ever, so that a load
    // that waited with it would fail the checks rather than hang), then gives `answer`.
    dispatch_semaphore_t answered = dispatch_semaphore_create(0);
    __block NSData *answer = nil;
    __block NSUInteger reads = 0;
    DKClipboardHistory *history = [[DKClipboardHistory alloc] initWithFolder:folder key:^NSData *{
        reads++;
        dispatch_semaphore_wait(answered, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
        return answer;
    }];
    NSDate *asked = NSDate.date;
    [history load];
    [history load];
    Expect(-asked.timeIntervalSinceNow < 1, "loading does not wait for the Keychain's answer");
    Copy(history, board, NSPasteboardTypeString, @"copied while the prompt is up");
    Settle();
    Expect(reads == 1 && !history.loaded && ![files contentsOfDirectoryAtPath:folder.path error:nil].count,
           "while a Keychain prompt is up the key is asked for once and nothing is recorded");
    dispatch_semaphore_signal(answered);
    Settle();
    Copy(history, board, NSPasteboardTypeString, @"copied after the key was refused");
    Settle();
    Expect(!history.loaded && ![files contentsOfDirectoryAtPath:folder.path error:nil].count, "a refused key records nothing");
    answer = DKKeychainKey(service, @"clipboard");
    dispatch_semaphore_signal(answered);
    Load(history);
    Copy(history, board, NSPasteboardTypeString, @"copied with the key");
    Settle();
    Expect([history clipsMatching:@"" limit:10].count == 1, "once the key is given, copies are recorded");
    [board releaseGlobally];
    [files removeItemAtURL:folder error:nil];
}

static void TestRanking(void) {
    Expect(DKMatchScore(@"Shortcuts", @"h") == 0 && DKMatchScore(@"Home", @"h") > 0,
           "a single letter only matches the start of a word");
    Expect(RanksFirst(@"vs", @"Visual Studio Code", @"Voice Memos"), "\"vs\": two word starts beat a start and a middle");
    Expect(RanksFirst(@"c", @"Chess", @"Google Chrome"), "\"c\": the title's start beats a later word's");
    Expect(RanksFirst(@"git", @"GitHub", @"Gitter"), "\"git\": a whole word, even closed by a capital, beats a prefix");
    Expect(DKMatchScore(@"Google Chrome", @"chr") > 0 && DKMatchScore(@"Synchronize", @"chr") == 0,
           "\"chr\": letters at a word start match, the same letters inside a word do not");
    DKRank settings;
    Expect(DKRankItem(&settings, @"System Settings", @[ @"System Preferences" ], nil, nil, @"selftest:settings", 5, @"pref"),
           "an alternate title matches");
    DKRank ghostty, terminal;
    Expect(DKRankItem(&ghostty, @"Ghostty", nil, nil, @[ @"Terminal" ], @"selftest:ghostty", 5, @"term") &&
               DKRankItem(&terminal, @"Terminal", nil, nil, nil, @"selftest:terminal", 5, @"term") &&
               DKCompareRanks(&terminal, @"Terminal", &ghostty, @"Ghostty", @"term") == NSOrderedAscending,
           "a keyword finds an item, below the titles that match");
    Expect(DKMatchScore(@"Audio MIDI Setup", @"mu") == 0, "\"mu\": a word start and a later middle letter are not enough");
    Expect(DKMatchScore(@"Chess", @"x") == 0, "no match, no result");

    Expect(RanksFirst(@"c", @"Chess", @"Clock"), "equal matches go by name before any use");
    DKRecordUse(@"selftest:Clock", @"");
    Expect(RanksFirst(@"c", @"Clock", @"Chess"), "then by use");
    DKRecordUse(@"selftest:Google Chrome", @"chr");
    Expect(RanksFirst(@"ch", @"Chess", @"Google Chrome"), "a query typed once is not remembered");
    DKRecordUse(@"selftest:Google Chrome", @"chr");
    Expect(RanksFirst(@"ch", @"Google Chrome", @"Chess"), "a query typed to open an app in use brings it first for shorter ones");
    Expect(RanksFirst(@"chr", @"Google Chrome", @"Chr"), "and for itself, above an equal title");
}

static void TestPickerBack(void) {
    NSApplication.sharedApplication.activationPolicy = NSApplicationActivationPolicyAccessory;
    DKPage * (^page)(void) = ^{
        DKPage *page = [DKPage new];
        page.title = page.placeholder = @"";
        page.items = ^NSArray *(NSString *query) { return @[]; };
        return page;
    };
    DKPicker *picker = [[DKPicker alloc] initWithRootPage:page() logo:[NSImage new]];
    [picker showForInspection:nil];
    [picker pushScreen:page()];
    [picker pop];
    Expect(picker.visible, "Esc on a screen opened from the root goes back to the root");
    [picker hide];
    [picker showForInspection:page()];
    [picker pop];
    Expect(!picker.visible, "Esc on a screen opened by its own hotkey closes the panel");
}

/// Stands in for a field with the keyboard: notes the editing commands it is given.
@interface DKEditingProbe : NSView
@property(copy) NSString *commands;
@end
@implementation DKEditingProbe
- (BOOL)acceptsFirstResponder { return YES; }
- (void)note:(SEL)command { _commands = [_commands ?: @"" stringByAppendingFormat:@"%@ ", NSStringFromSelector(command)]; }
- (void)cut:(id)sender { [self note:_cmd]; }
- (void)copy:(id)sender { [self note:_cmd]; }
- (void)paste:(id)sender { [self note:_cmd]; }
- (void)selectAll:(id)sender { [self note:_cmd]; }
- (void)undo:(id)sender { [self note:_cmd]; }
- (void)redo:(id)sender { [self note:_cmd]; }
@end

/// A key press handed to the panel as the application hands over one no menu took.
static void Press(NSWindow *panel, NSString *characters, NSEventModifierFlags modifiers) {
    [panel sendEvent:[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:modifiers
                                     timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:panel.windowNumber
                                       context:nil characters:characters charactersIgnoringModifiers:characters
                                     isARepeat:NO keyCode:0]];
}

static void TestEditingKeys(void) {
    const NSEventModifierFlags command = NSEventModifierFlagCommand, shift = NSEventModifierFlagShift;
    __block NSString *searched;
    __block BOOL rowTakesCut = NO, cutByRow = NO;
    DKPage *page = [DKPage new];
    page.title = page.placeholder = @"";
    page.items = ^NSArray *(NSString *query) {
        searched = query;
        DKItem *item = [DKItem new];
        item.title = item.key = @"row";
        item.actions = rowTakesCut ? @[ [DKAction actionWithTitle:@"" symbol:nil shortcut:@"cmd+x" handler:^{ cutByRow = YES; }] ] : @[];
        return @[ item ];
    };
    DKPicker *picker = [[DKPicker alloc] initWithRootPage:page logo:[NSImage new]];
    [picker showForInspection:nil];
    DKPanel *panel;
    for (NSWindow *window in NSApp.windows)
        if ([window isKindOfClass:DKPanel.class] && window.visible) panel = (DKPanel *)window;

    NSTextView *field = (NSTextView *)panel.firstResponder;
    [field insertText:@"abc" replacementRange:field.selectedRange];
    Press(panel, @"a", command);
    Expect(NSEqualRanges(field.selectedRange, NSMakeRange(0, 3)), "cmd+A selects the search field's text");
    [field insertText:@"d" replacementRange:field.selectedRange];
    Press(panel, @"z", command);
    BOOL undone = [searched isEqualToString:@""];
    Press(panel, @"Z", command | shift);
    Expect(undone && [searched isEqualToString:@"d"], "cmd+Z undoes typing there and shift+cmd+Z redoes it, and the list follows");

    DKEditingProbe *probe = [DKEditingProbe new];
    [panel.canvas addSubview:probe];
    [panel makeFirstResponder:probe];
    for (NSString *key in @[ @"x", @"c", @"v", @"a", @"z" ]) Press(panel, key, command);
    Press(panel, @"Z", command | shift);
    Press(panel, @"V", command | shift);
    NSString *all = @"cut: copy: paste: selectAll: undo: redo: ";
    Expect([probe.commands isEqualToString:all], "cmd+X, C, V, A, Z and shift+cmd+Z edit whatever has the keyboard, and nothing else does");
    rowTakesCut = YES;
    [picker reload];
    Press(panel, @"x", command);
    Expect(cutByRow && [probe.commands isEqualToString:all], "a row's own shortcut on one of those keys wins");
    [picker hide];
}

static DKListView *ListInWindow(void) {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 750, 411) styleMask:NSWindowStyleMaskBorderless
                                                     backing:NSBackingStoreBuffered defer:NO];
    window.releasedWhenClosed = NO;
    DKListView *list = [[DKListView alloc] initWithFrame:NSMakeRect(0, 0, 750, 411)];
    window.contentView = list;
    return list;
}

/// What the list's rows look like, as a bitmap of the part of them in view.
static NSData *RowsPicture(DKListView *list) {
    [list layoutSubtreeIfNeeded];
    for (NSScrollView *scroll in list.subviews) {
        if (![scroll isKindOfClass:NSScrollView.class]) continue;
        NSView *rows = scroll.documentView;
        NSBitmapImageRep *bitmap = [rows bitmapImageRepForCachingDisplayInRect:rows.visibleRect];
        [rows cacheDisplayInRect:rows.visibleRect toBitmapImageRep:bitmap];
        return bitmap.TIFFRepresentation;
    }
    return nil;
}

static void TestListUpdates(void) {
    NSArray<DKItem *> * (^items)(NSUInteger, NSString *, NSUInteger, NSString *) =
        ^(NSUInteger first, NSString *firstSection, NSUInteger second, NSString *secondSection) {
            NSMutableArray<DKItem *> *made = [NSMutableArray new];
            for (NSUInteger i = 0; i < first + second; i++) {
                DKItem *item = [DKItem new];
                item.title = [NSString stringWithFormat:@"%@ %lu", i < first ? firstSection : secondSection, (unsigned long)i];
                item.subtitle = i % 3 ? nil : @"Subtitle";
                item.accessory = i % 2 ? @"Application" : @"Command";
                item.running = i % 4 == 1;
                item.section = i < first ? firstSection : secondSection;
                item.key = item.title;
                [made addObject:item];
            }
            return made;
        };
    // Rows that stay items, items that turn into headers and back, a list longer than the
    // view, an empty one, and growing again.
    NSArray<NSArray<DKItem *> *> *steps = @[
        items(8, @"Suggestions", 3, @"Commands"), items(5, @"Results", 1, @"Use with..."), items(30, @"Results", 1, @"Use with..."),
        items(2, @"Results", 1, @"Use with..."), @[], items(8, @"Suggestions", 3, @"Commands"),
    ];
    DKListView *updated = ListInWindow();
    BOOL same = YES;
    NSMutableSet<NSData *> *pictures = [NSMutableSet new];
    for (NSArray<DKItem *> *step in steps) {
        [updated setItems:step keepSelection:NO];
        DKListView *fresh = ListInWindow();
        [fresh setItems:step keepSelection:NO];
        NSData *picture = RowsPicture(updated);
        same = same && picture && [picture isEqualToData:RowsPicture(fresh)];
        if (picture) [pictures addObject:picture];
    }
    Expect(pictures.count == steps.count - 1, "the list's rows can be told apart in a picture");
    Expect(same, "a list whose rows changed in place looks like one filled afresh");
}

static void TestImagePaste(void) {
    NSPasteboard *board = [NSPasteboard pasteboardWithUniqueName];
    [board clearContents];
    [board setData:TinyImage(NSBitmapImageFileTypePNG) forType:NSPasteboardTypePNG];
    Expect(DKPasteboardHoldsOnlyImage(board), "a copied screenshot is pasted into Ghostty as ctrl+v");
    [board setString:@"caption" forType:NSPasteboardTypeString];
    Expect(!DKPasteboardHoldsOnlyImage(board), "an image with text keeps cmd+v");
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"deskkit-selftest.png"];
    [TinyImage(NSBitmapImageFileTypePNG) writeToFile:path atomically:YES];
    [board clearContents];
    [board setString:[NSURL fileURLWithPath:path].absoluteString forType:NSPasteboardTypeFileURL];
    Expect(DKPasteboardHoldsOnlyImage(board), "a copied image file is pasted as ctrl+v");
    [board clearContents];
    [board setString:@"text" forType:NSPasteboardTypeString];
    Expect(!DKPasteboardHoldsOnlyImage(board), "text keeps cmd+v");
    [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    [board releaseGlobally];
}

static void TestPreview(void) {
    NSData * (^png)(NSInteger, NSInteger, CGFloat) = ^(NSInteger width, NSInteger height, CGFloat dpi) {
        NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:width pixelsHigh:height
                                                                        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
                                                                       colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
        bitmap.size = NSMakeSize(width * 72 / dpi, height * 72 / dpi);
        return [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    };
    size_t (^pixelsWide)(NSImage *) = ^(NSImage *image) { return CGImageGetWidth([image CGImageForProposedRect:NULL context:nil hints:nil]); };
    NSSize room = NSMakeSize(433, 195);
    // As a Retina screenshot is: 800 × 500 points.
    NSImage *large = DKClipPreview(png(1600, 1000, 144), room, 2);
    Expect(NSEqualSizes(large.size, NSMakeSize(312, 195)) && pixelsWide(large) == 624,
           "an image's preview is scaled down to its room, with a pixel for each of the screen's");
    NSImage *dense = DKClipPreview(png(600, 300, 216), room, 2);
    Expect(NSEqualSizes(dense.size, NSMakeSize(200, 100)) && pixelsWide(dense) == 400, "also when the image fits and only has more pixels");
    NSImage *small = DKClipPreview(png(200, 120, 72), room, 2);
    Expect(NSEqualSizes(small.size, NSMakeSize(200, 120)) && pixelsWide(small) == 200, "an image smaller than its room is not enlarged");
    Expect(!DKClipPreview([@"text" dataUsingEncoding:NSUTF8StringEncoding], room, 2), "what is no image has no preview");
}

/// Megabytes of GPU buffers the process holds.
static double GraphicsFootprint(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return 0;
    return info.ledger_tag_graphics_footprint / 1048576.0;
}

static void TestDetailDrawing(void) {
    DKPage * (^page)(BOOL) = ^(BOOL showsDetail) {
        DKPage *page = [DKPage new];
        page.title = page.placeholder = @"";
        page.showsDetail = showsDetail;
        page.items = ^NSArray *(NSString *query) {
            DKItem *item = [DKItem new];
            item.title = item.key = @"row";
            item.detail = ^{
                DKDetail *detail = [DKDetail new];
                detail.text = @"Some text";
                detail.metadata = @[ @[ @"Content type", @"Text" ], @[ @"Characters", @"9" ], @[ @"Words", @"2" ] ];
                return detail;
            };
            return @[ item ];
        };
        return page;
    };
    void (^draw)(void) = ^{ [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]]; };
    DKPicker *picker = [[DKPicker alloc] initWithRootPage:page(NO) logo:[NSImage new]];
    [picker showForInspection:nil];
    DKDetailView *pane;
    for (NSWindow *window in NSApp.windows)
        if ([window isKindOfClass:DKPanel.class] && window.visible)
            for (NSView *view in ((DKPanel *)window).canvas.subviews)
                if ([view isKindOfClass:DKDetailView.class]) pane = (DKDetailView *)view;
    draw();
    Expect(pane && !pane.layer.contents, "the detail pane holds no picture while hidden");
    double before = GraphicsFootprint();
    [picker pushScreen:page(YES)];
    draw();
    // The rasterizer's buffers came with the pane's second drawing and stayed for a second.
    [picker reload];
    draw();
    Expect(pane.layer.contents && GraphicsFootprint() - before < 16, "shown, it is drawn without the GPU rasterizer and its buffers");
    [picker pop];
    draw();
    Expect(pane && !pane.layer.contents, "and gives its picture up when hidden again");
    [picker hide];
}

static void TestQuicklinkURLs(void) {
    Expect(DKQuicklinkURL(@"https://exa mple.com") == nil, "a link with a space is refused");
    Expect(DKQuicklinkURL(@"https://") == nil, "a web address without a host is refused");
    Expect([DKQuicklinkURL(@"github.com").absoluteString isEqualToString:@"https://github.com"], "https is assumed");
    Expect(DKQuicklinkURL(@"~/Downloads").isFileURL, "a folder path is a file URL");
}

static NSDictionary *Quicklink(NSString *name) {
    for (NSDictionary *quicklink in DKQuicklinks())
        if ([quicklink[@"name"] isEqualToString:name]) return quicklink;
    return nil;
}

static NSArray<NSDictionary *> *MadeUpAccounts(void) {
    return @[ @{@"title" : @"Ana", @"url" : @"https://mail.example.com/u/1/"},
              @{@"title" : @"bob@example.com", @"url" : @"https://mail.example.com/u/0/", @"icon" : @"avatars/bob.png"} ];
}

static void TestSublinks(void) {
    NSArray<NSDictionary *> *accounts = MadeUpAccounts();
    // A hand edit's leftovers: an entry that is no dictionary, and one without a link.
    DKSaveQuicklink(nil, @"Mail", @"https://mail.example.com", [accounts arrayByAddingObjectsFromArray:(NSArray *)@[ @"junk", @{@"title" : @"x"} ]]);
    Expect([DKSublinks(Quicklink(@"Mail")) isEqualToArray:accounts], "sub-links keep their order; entries without a title and a link are skipped");

    DKForm *form = DKQuicklinkForm([DKPicker new], Quicklink(@"Mail"));
    NSString *(^submit)(NSString *) = ^NSString *(NSString *lines) { return form.submit(@[ @"https://mail.example.com", @"Mail", lines ]); };
    Expect(!submit(form.fields[2].value) && [DKSublinks(Quicklink(@"Mail")) isEqualToArray:accounts],
           "the form lists the sub-links one per line and saves them back unchanged");
    Expect([submit(@"Ana") hasPrefix:@"Sub-link line 1 "], "a sub-link without a link is refused");
    Expect([submit(@"\nana | https://exa mple.com") hasPrefix:@"Sub-link line 2:"], "and one whose link is no link, naming its line");
    Expect(!submit(@" \n") && !Quicklink(@"Mail")[@"sublinks"], "emptied, the sub-links are gone");
    DKSaveQuicklink(@"Mail", @"Mail", @"https://mail.example.com", accounts);
}

/// A key event the panel tells by its code: Return, Esc, an arrow.
static void SendKey(NSWindow *panel, NSEventType type, unsigned short keyCode, NSString *characters, BOOL repeat) {
    [panel sendEvent:[NSEvent keyEventWithType:type location:NSZeroPoint modifierFlags:0
                                     timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:panel.windowNumber
                                       context:nil characters:characters charactersIgnoringModifiers:characters
                                     isARepeat:repeat keyCode:keyCode]];
}

static void PressKey(NSWindow *panel, unsigned short keyCode, NSString *characters) {
    SendKey(panel, NSEventTypeKeyDown, keyCode, characters, NO);
}

static void TestSublinkList(void) {
    __block DKPicker *picker;
    DKPage *root = [DKPage new];
    root.title = root.placeholder = @"";
    root.items = ^NSArray *(NSString *query) { return @[ DKQuicklinkItem(picker, Quicklink(@"Mail")) ]; };
    picker = [[DKPicker alloc] initWithRootPage:root logo:[NSImage new]];
    [picker showForInspection:nil];
    DKPanel *panel;
    for (NSWindow *window in NSApp.windows)
        if ([window isKindOfClass:DKPanel.class] && window.visible) panel = (DKPanel *)window;
    DKListView *list;
    DKFormView *form;
    for (NSView *view in panel.canvas.subviews) {
        if ([view isKindOfClass:DKListView.class]) list = (DKListView *)view;
        if ([view isKindOfClass:DKFormView.class]) form = (DKFormView *)view;
    }

    Expect(DKQuicklinkItem(picker, Quicklink(@"Mail")).heldAction && !DKQuicklinkItem(picker, Quicklink(@"GitHub")).heldAction,
           "a quicklink with sub-links opens its first one when held, one without has nothing to hold");
    NSData *picture = TinyImage(NSBitmapImageFileTypePNG);
    PressKey(panel, kVK_Return, @"\r");
    SendKey(panel, NSEventTypeKeyUp, kVK_Return, @"\r", NO);
    NSString *first = list.selectedItem.title;
    PressKey(panel, kVK_DownArrow, @"");
    Expect([first isEqualToString:@"Ana"] && [list.selectedItem.title isEqualToString:@"bob@example.com"],
           "Return on a quicklink with sub-links lists them in their order");

    [picker search:@"bob"];
    Expect([list.selectedItem.title isEqualToString:@"bob@example.com"], "the list is searched by title");
    PressKey(panel, kVK_Escape, @"\x1b");
    PressKey(panel, kVK_Escape, @"\x1b");
    Expect(picker.visible && [list.selectedItem.title isEqualToString:@"Mail"], "Esc clears the search, then goes back to the quicklink");

    [picker pushScreen:DKQuicklinkForm(picker, Quicklink(@"Mail"))];
    NSString *before = form.values[2];
    [form focusNextField];
    [form focusNextField];
    PressKey(panel, kVK_Return, @"\r");
    Expect(!form.hidden && [form.values[2] isEqualToString:[before stringByAppendingString:@"\n"]],
           "Return in the sub-links field starts a line after the last one");

    NSTextField *field;
    NSMutableArray<NSView *> *views = [NSMutableArray arrayWithObject:form];
    while (views.count) {
        NSView *view = views.lastObject;
        [views removeLastObject];
        if ([view isKindOfClass:NSTextField.class] && [((NSTextField *)view).stringValue isEqualToString:form.values[2]]) field = (NSTextField *)view;
        [views addObjectsFromArray:view.subviews];
    }
    NSRect text = [field.cell titleRectForBounds:field.bounds];
    NSPoint firstLine = [form convertPoint:NSMakePoint(NSMidX(text), field.isFlipped ? NSMinY(text) + 4 : NSMaxY(text) - 4) fromView:field];
    NSPoint belowLines = [form convertPoint:NSMakePoint(NSMidX(text), field.isFlipped ? NSMaxY(text) - 4 : NSMinY(text) + 4) fromView:field];
    NSURL *dropped = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"deskkit-selftest-icon.png"]];
    [picture writeToURL:dropped atomically:YES];
    BOOL refused = ![form dropFile:dropped at:belowLines];
    BOOL taken = [form dropFile:dropped at:firstLine];
    NSURL *copy = [DKSupportDirectory() URLByAppendingPathComponent:@"sublink-icons/Ana.png"];
    Expect(refused && taken && [[form.values[2] componentsSeparatedByString:@"\n"].firstObject hasSuffix:@" | sublink-icons/Ana.png"] &&
               [[NSData dataWithContentsOfURL:copy] isEqualToData:picture],
           "an image dropped on a sub-link's line is copied into deskkit's folder as its icon; below the lines it is refused");
    [NSFileManager.defaultManager removeItemAtURL:dropped error:nil];
    [picker hide];
}

static void Wait(NSTimeInterval seconds) { [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]]; }

static void TestPress(void) {
    __block NSUInteger held = 0;
    DKPress *tap = [[DKPress alloc] initWithSeconds:DKHoldSeconds held:^{ held++; }];
    Wait(DKHoldSeconds / 4);
    BOOL tapped = [tap end];
    Wait(DKHoldSeconds);
    Expect(tapped && !held && !tap.timing, "a press let go before the hold time is a tap, and its timer is gone");
    DKPress *hold = [[DKPress alloc] initWithSeconds:DKHoldSeconds held:^{ held++; }];
    Wait(DKHoldSeconds / 2);
    BOOL early = !held;
    Wait(DKHoldSeconds);
    Expect(early && held == 1 && !hold.timing && ![hold end], "one held the hold time is a hold, once, and no tap when let go");
}

static void TestHold(void) {
    __block NSString *ran = @"";
    DKItem *item = [DKItem new];
    item.title = item.key = @"row";
    item.actions = @[ [DKAction actionWithTitle:@"" symbol:nil shortcut:@"return" handler:^{ ran = [ran stringByAppendingString:@"tap "]; }] ];
    item.heldAction = [DKAction actionWithTitle:@"" symbol:nil shortcut:nil handler:^{ ran = [ran stringByAppendingString:@"hold "]; }];
    DKPage *page = [DKPage new];
    page.title = page.placeholder = @"";
    page.items = ^NSArray *(NSString *query) { return @[ item ]; };
    DKPicker *picker = [[DKPicker alloc] initWithRootPage:page logo:[NSImage new]];
    [picker showForInspection:nil];
    DKPanel *panel;
    for (NSWindow *window in NSApp.windows)
        if ([window isKindOfClass:DKPanel.class] && window.visible) panel = (DKPanel *)window;
    NSTableView *table;
    for (NSView *view in panel.canvas.subviews)
        if ([view isKindOfClass:DKListView.class])
            for (NSScrollView *scroll in view.subviews)
                if ([scroll isKindOfClass:NSScrollView.class]) table = scroll.documentView;

    void (^holdReturn)(NSTimeInterval) = ^(NSTimeInterval seconds) {
        ran = @"";
        SendKey(panel, NSEventTypeKeyDown, kVK_Return, @"\r", NO);
        Wait(seconds);
        SendKey(panel, NSEventTypeKeyDown, kVK_Return, @"\r", YES);
        SendKey(panel, NSEventTypeKeyUp, kVK_Return, @"\r", NO);
        Wait(DKHoldSeconds);
    };
    holdReturn(DKHoldSeconds / 4);
    Expect([ran isEqualToString:@"tap "], "Return let go before the hold time runs the row's action, on release");
    holdReturn(DKHoldSeconds * 3);
    Expect([ran isEqualToString:@"hold "], "Return held the hold time runs its held action instead, once despite the key's repeats");

    // The table follows the button in a loop of its own until it goes up, as it does here
    // when the timer posts the release. Events the window server queued for this process,
    // which no run loop takes out here as -[NSApplication run] would, can end that loop at
    // once, so they go first.
    void (^holdMouse)(NSTimeInterval) = ^(NSTimeInterval seconds) {
        ran = @"";
        while ([NSApp nextEventMatchingMask:NSEventMaskAny untilDate:nil inMode:NSDefaultRunLoopMode dequeue:YES]) {}
        NSPoint point = [table convertPoint:NSMakePoint(100, DKRowHeight / 2) toView:nil];
        NSEvent * (^mouse)(NSEventType) = ^(NSEventType type) {
            return [NSEvent mouseEventWithType:type location:point modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime
                                  windowNumber:panel.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1];
        };
        NSTimer *release = [NSTimer timerWithTimeInterval:seconds repeats:NO block:^(NSTimer *timer) {
            [NSApp postEvent:mouse(NSEventTypeLeftMouseUp) atStart:NO];
        }];
        [NSRunLoop.mainRunLoop addTimer:release forMode:NSRunLoopCommonModes];
        [table mouseDown:mouse(NSEventTypeLeftMouseDown)];
        Wait(DKHoldSeconds);
    };
    holdMouse(DKHoldSeconds / 4);
    Expect([ran isEqualToString:@""], "a click only selects the row");
    holdMouse(DKHoldSeconds * 3);
    Expect([ran isEqualToString:@"hold "], "the mouse button held the hold time on the row runs its held action");
    [picker hide];
}

// The frames snap.m keeps for "restore", which its shortcuts reach only with a window.
void DKSnapRemember(AXUIElementRef window, CGRect frame);
CGRect DKSnapRecall(AXUIElementRef window);

static void TestSnapping(void) {
    // A menu bar, and a Dock on the left that "larger" stops at.
    CGRect visible = CGRectMake(60, 39, 1500, 900), window = CGRectMake(80, 100, 600, 400);
    static const struct {
        const char *action;
        CGRect target;
    } cases[] = {
        {"leftHalf", {{60, 39}, {750, 900}}},
        {"rightHalf", {{810, 39}, {750, 900}}},
        {"topHalf", {{60, 39}, {1500, 450}}},
        {"bottomHalf", {{60, 489}, {1500, 450}}},
        {"topLeft", {{60, 39}, {750, 450}}},
        {"topRight", {{810, 39}, {750, 450}}},
        {"bottomLeft", {{60, 489}, {750, 450}}},
        {"bottomRight", {{810, 489}, {750, 450}}},
        {"firstThird", {{60, 39}, {500, 900}}},
        {"centerThird", {{560, 39}, {500, 900}}},
        {"lastThird", {{1060, 39}, {500, 900}}},
        {"firstTwoThirds", {{60, 39}, {1000, 900}}},
        {"centerTwoThirds", {{310, 39}, {1000, 900}}},
        {"lastTwoThirds", {{560, 39}, {1000, 900}}},
        {"maximize", {{60, 39}, {1500, 900}}},
        {"maximizeHeight", {{80, 39}, {600, 900}}},
        {"center", {{510, 289}, {600, 400}}},
        {"larger", {{60, 70}, {650, 460}}},
        {"smaller", {{110, 130}, {540, 340}}},
    };
    for (size_t i = 0; i < sizeof cases / sizeof *cases; i++)
        Expect(CGRectEqualToRect(DKSnapTarget(@(cases[i].action), window, visible), cases[i].target), cases[i].action);
    Expect(CGRectIsNull(DKSnapTarget(@"nonsense", window, visible)), "unknown action");

    // Each shortcut gets its own reference to the window, as `again` is to `first`.
    AXUIElementRef first = AXUIElementCreateApplication(1), again = AXUIElementCreateApplication(1);
    AXUIElementRef second = AXUIElementCreateApplication(2);
    DKSnapRemember(first, window);
    DKSnapRemember(again, visible);
    Expect(CGRectEqualToRect(DKSnapRecall(again), window), "restore goes back to the frame before the first snap");
    Expect(CGRectIsNull(DKSnapRecall(first)), "a restored frame is forgotten");
    for (pid_t pid = 1; pid <= 51; pid++) {
        AXUIElementRef other = AXUIElementCreateApplication(pid);
        DKSnapRemember(other, window);
        CFRelease(other);
    }
    Expect(CGRectIsNull(DKSnapRecall(first)) && CGRectEqualToRect(DKSnapRecall(second), window),
           "the 50 windows snapped last keep their frames");
    CFRelease(first), CFRelease(again), CFRelease(second);
}

/// The answer for `query` as a Brazilian-English Mac writes it (decimal comma), with fixed
/// rates and clock; nil when no calculator shows.
static DKCalculation *Calculate(NSString *query, NSString *locale) {
    NSDictionary *rates = @{@"USD" : [NSDecimalNumber decimalNumberWithString:@"1"], @"BRL" : [NSDecimalNumber decimalNumberWithString:@"5.3456"],
                            @"EUR" : [NSDecimalNumber decimalNumberWithString:@"0.9123"]};
    // 22 November 2026, 12:00 in São Paulo.
    NSDate *now = [NSDate dateWithTimeIntervalSince1970:1795359600];
    return DKCalculate(query, [NSLocale localeWithLocaleIdentifier:locale], rates, [NSTimeZone timeZoneWithName:@"America/Sao_Paulo"], now);
}

static void ExpectAnswer(NSString *query, NSString *answer) {
    NSString *got = Calculate(query, @"en_BR").answer;
    BOOL same = answer ? [got isEqualToString:answer] : got == nil;
    NSString *what = [NSString stringWithFormat:@"calculator: %@ is %@%@", query, answer ?: @"no calculator",
                                                same ? @"" : [NSString stringWithFormat:@" (got %@)", got ?: @"none"]];
    Expect(same, what.UTF8String);
}

static void TestCalculator(void) {
    // Precedence, powers to the right, unary minus below powers.
    ExpectAnswer(@"2+3*4", @"14");
    ExpectAnswer(@"(2+3)*4", @"20");
    ExpectAnswer(@"2^3^2", @"512");
    ExpectAnswer(@"-2^2", @"-4");
    ExpectAnswer(@"(-2)^2", @"4");
    ExpectAnswer(@"-5+3", @"-2");
    ExpectAnswer(@"2 * -3", @"-6");
    ExpectAnswer(@"2 - -3", @"5");
    ExpectAnswer(@"3*", @"3");
    ExpectAnswer(@"2pi", @"6,2831853072");
    ExpectAnswer(@"5!", @"120");
    // Percentages.
    ExpectAnswer(@"10% of 200", @"20");
    ExpectAnswer(@"200 + 10%", @"220");
    ExpectAnswer(@"200 - 10%", @"180");
    ExpectAnswer(@"200 / 10%", @"2.000");
    ExpectAnswer(@"10% + 5%", @"15%");
    ExpectAnswer(@"50 % 3", @"2");
    ExpectAnswer(@"20% off 50", @"40");
    ExpectAnswer(@"5 as % of 20", @"25%");
    // Division by zero and other impossible answers show nothing.
    ExpectAnswer(@"1/0", nil);
    ExpectAnswer(@"5 mod 0", nil);
    ExpectAnswer(@"sqrt(-1)", nil);
    ExpectAnswer(@"(2+3", nil);
    // Decimal arithmetic and Raycast's ways of writing large and small numbers.
    ExpectAnswer(@"0.1+0.2", @"0,3");
    ExpectAnswer(@"1234567.89*3.7", @"4.567.901,193");
    ExpectAnswer(@"10/3", @"3,3333333333");
    ExpectAnswer(@"1e14*1", @"100T");
    ExpectAnswer(@"1e15*1", @"1P");
    ExpectAnswer(@"2^64", @"1,8446744074e19");
    ExpectAnswer(@"1/123456789", @"8,1000000737e-9");
    ExpectAnswer(@"0.0000012345*1", @"0,0000012345");
    ExpectAnswer(@"170!*1", @"7,2574156153e306");
    ExpectAnswer(@"2^10000", @"∞");
    // The decimal comma, and the point as a thousands separator or a decimal point.
    ExpectAnswer(@"1,5+1", @"2,5");
    ExpectAnswer(@"1.5+1", @"2,5");
    ExpectAnswer(@"1.005*1000", @"1.005.000");
    Expect([Calculate(@"1,000+1", @"en_US").answer isEqualToString:@"1,001"], "calculator: the US groups with commas");
    // Words, lone numbers and the answer itself show no calculator.
    ExpectAnswer(@"hello", nil);
    ExpectAnswer(@"pi", nil);
    ExpectAnswer(@"5", nil);
    ExpectAnswer(@"1.5", nil);
    ExpectAnswer(@"-5", nil);
    ExpectAnswer(@"2 mm", nil);
    // Functions, bases.
    ExpectAnswer(@"sqrt(16)", @"4");
    ExpectAnswer(@"sin(pi/2)", @"1");
    ExpectAnswer(@"log2(8)", @"3");
    ExpectAnswer(@"round(3.14159, 2)", @"3,14");
    ExpectAnswer(@"255 in hex", @"0xFF");
    ExpectAnswer(@"0xff + 1", @"0x100");
    ExpectAnswer(@"0xff", @"255");
    // Units, through NSMeasurement.
    ExpectAnswer(@"10 km to mi", @"6,2137119224 mi");
    ExpectAnswer(@"10 km", @"6,2137119224 mi");
    ExpectAnswer(@"km to mi", @"0,6213711922 mi");
    ExpectAnswer(@"100 c in f", @"212 f");
    ExpectAnswer(@"98.6 °F in °C", @"37 °C");
    ExpectAnswer(@"1 gb to mb", @"1.000 MB");
    ExpectAnswer(@"1 GiB in MiB", @"1.024 MiB");
    ExpectAnswer(@"1 mile in feet", @"5.280 feet");
    ExpectAnswer(@"6'2\" in cm", @"187,96 cm");
    ExpectAnswer(@"1 m", @"3 feet 3,3700787402 inches");
    ExpectAnswer(@"90 min", @"1 hour 30 min");
    ExpectAnswer(@"1 day in hours", @"24 hours");
    ExpectAnswer(@"1 km + 500 m", @"1,5 km");
    ExpectAnswer(@"2 m * 3 m", @"6 m²");
    ExpectAnswer(@"10 km to kg", nil);
    // Money and dates.
    ExpectAnswer(@"100 usd in brl", @"R$534,56");
    ExpectAnswer(@"5 usd + 3 eur", @"€7,56");
    ExpectAnswer(@"$100", @"R$534,56");
    ExpectAnswer(@"100 chf in usd", nil);
    ExpectAnswer(@"today + 30 days", @"December 22");
    ExpectAnswer(@"time in tokyo", @"00:00");
    ExpectAnswer(@"days until christmas", @"33 days");

    DKCalculation *sum = Calculate(@"1+2", @"en_BR");
    Expect([sum.expressionLabel isEqualToString:@"Sum"] && [sum.answerLabel isEqualToString:@"Three"], "calculator: 1+2 is a Sum, Three");
    DKCalculation *product = Calculate(@"6*2-1/4", @"en_BR");
    Expect([product.expression isEqualToString:@"6×2−1÷4"] && [product.expressionLabel isEqualToString:@"Expression"],
           "calculator: operators written as Raycast writes them, several make an Expression");
    DKCalculation *root = Calculate(@"sqrt(16)", @"en_BR");
    Expect([root.expressionLabel isEqualToString:@"Square Root"] && [root.answerLabel isEqualToString:@"Four"], "calculator: sqrt is a Square Root");
    DKCalculation *distance = Calculate(@"10 km in mi", @"en_BR");
    Expect([distance.expressionLabel isEqualToString:@"Kilometers"] && [distance.answerLabel isEqualToString:@"Miles"] &&
               [distance.swappedQuery isEqualToString:@"10 mi in km "] && [distance.unformattedAnswer isEqualToString:@"6.21371192237334"],
           "calculator: a conversion names its units and swaps them");
    DKCalculation *money = Calculate(@"100 usd in brl", @"en_BR");
    Expect(money.usesCurrency && [money.expressionLabel isEqualToString:@"US Dollar"] && [money.answerLabel isEqualToString:@"Brazilian Real"],
           "calculator: currencies are named");
    DKCalculation *plus = Calculate(@"today + 30 days", @"en_BR");
    Expect([plus.expressionLabel isEqualToString:@"Sunday, 22 November"] && [plus.answerLabel isEqualToString:@"Tuesday"],
           "calculator: a date reached from today names both days");
    NSArray *highlighted = [Calculate(@"10% of 200", @"en_BR").highlights valueForKey:@"rangeValue"];
    Expect(highlighted.count == 3, "calculator: numbers and percent signs are highlighted, words are not");
}

int DKSelfTest(void) {
    // Usage counts and quicklinks go to a scratch folder, away from the user's.
    NSString *home = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    setenv("DESKKIT_HOME", home.fileSystemRepresentation, 1);
    NSString *service = @"local.deskkit.selftest";
    TestCrypto(service);
    TestHistory(service);
    TestHistoryLimits(service);
    TestHistoryKeyWait(service);
    DKKeychainDelete(service, @"clipboard");
    TestRanking();
    TestPickerBack();
    TestEditingKeys();
    TestListUpdates();
    TestImagePaste();
    TestPreview();
    TestDetailDrawing();
    TestQuicklinkURLs();
    TestSublinks();
    TestSublinkList();
    TestPress();
    TestHold();
    TestSnapping();
    TestCalculator();
    [NSFileManager.defaultManager removeItemAtPath:home error:nil];
    printf("%d failure(s)\n", failures);
    return failures ? 1 : 0;
}
