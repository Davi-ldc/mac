// Owns the launcher: its two hotkeys, the panel, and the root list (applications,
// quicklinks and commands) with Suggestions, search ordering and the Google fallback.
#import <Carbon/Carbon.h>

#import "apps.h"
#import "bench.h"
#import "calculatoritem.h"
#import "clipboard.h"
#import "clipboardscreen.h"
#import "currencies.h"
#import "features.h"
#import "hotkey.h"
#import "icons.h"
#import "picker.h"
#import "quicklinks.h"
#import "quicklinkscreens.h"
#import "ranking.h"
#import "webicons.h"

static const NSUInteger kSuggestionCount = 8;

static DKPicker *launcher;

static DKItem *ApplicationItem(NSDictionary *app, NSSet<NSString *> *running) {
    NSString *path = app[@"path"];
    NSURL *url = [NSURL fileURLWithPath:path];
    DKItem *item = [DKItem new];
    item.title = app[@"title"];
    item.alternateTitles = app[@"alternateTitles"];
    item.keywords = app[@"keywords"];
    item.accessory = @"Application";
    item.key = path;
    item.running = [running containsObject:path];
    item.iconLoader = ^NSImage *{ return DKFileIcon(path); };
    item.actions = @[
        [DKAction actionWithTitle:@"Open Application" symbol:@"arrow.up.forward.app" shortcut:@"return" handler:^{
            [launcher hide];
            [NSWorkspace.sharedWorkspace openApplicationAtURL:url configuration:[NSWorkspaceOpenConfiguration configuration]
                                            completionHandler:nil];
        }],
        [DKAction actionWithTitle:@"Show in Finder" symbol:@"folder" shortcut:@"cmd+shift+f" handler:^{
            [launcher hide];
            [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[ url ]];
        }],
    ];
    return item;
}

static DKItem *CommandItem(NSString *title, NSString *extension, DKCommand command, void (^run)(void)) {
    DKItem *item = [DKItem new];
    item.title = title;
    item.subtitle = extension;
    item.accessory = @"Command";
    item.key = [@"command:" stringByAppendingString:title];
    item.iconLoader = ^NSImage *{ return DKCommandIcon(command); };
    item.actions = @[ [DKAction actionWithTitle:@"Open Command" symbol:@"arrow.right.circle" shortcut:@"return" handler:run] ];
    return item;
}

/// Raycast's fallback: the query searched with Google, in Safari. Listed after the results,
/// and so first when nothing matches.
static DKItem *GoogleSearchItem(NSString *query) {
    NSURLComponents *search = [NSURLComponents componentsWithString:@"https://www.google.com/search"];
    search.queryItems = @[ [NSURLQueryItem queryItemWithName:@"q" value:query] ];
    NSURL *url = search.URL;
    DKItem *item = [DKItem new];
    item.title = @"Google Search";
    item.subtitle = @"Web Searches";
    item.accessory = @"Fallback";
    item.section = [NSString stringWithFormat:@"Use \"%@\" with...", query];
    item.key = @"fallback:google";
    item.iconLoader = ^NSImage *{ return DKCommandIcon(DKCommandGoogleSearch); };
    item.actions = @[ [DKAction actionWithTitle:@"Search Google" symbol:@"magnifyingglass" shortcut:@"return" handler:^{
        [launcher hide];
        DKOpenURL(url);
    }] ];
    return item;
}

/// Raycast's order among equally good results: applications, then commands, then quicklinks.
static NSInteger Kind(DKItem *item) {
    if ([item.accessory isEqualToString:@"Application"]) return 5;
    return [item.accessory isEqualToString:@"Command"] ? 4 : 3;
}

static BOOL Rank(DKRank *rank, DKItem *item, NSString *query) {
    // Raycast also matches a quicklink by its extension's name, which it does not show.
    NSString *subtitle = Kind(item) == 3 ? @"Quicklinks" : item.subtitle;
    return DKRankItem(rank, item.title, item.alternateTitles, subtitle, item.keywords, item.key, Kind(item), query);
}

static NSArray<DKItem *> *CommandItems(void) {
    return @[
        CommandItem(@"Search Quicklinks", @"Quicklinks", DKCommandSearchQuicklinks,
                    ^{ [launcher pushScreen:DKQuicklinksPage(launcher)]; }),
        CommandItem(@"Create Quicklink", @"Quicklinks", DKCommandCreateQuicklink,
                    ^{ [launcher pushScreen:DKQuicklinkForm(launcher, nil)]; }),
        CommandItem(@"Clipboard History", @"Clipboard History", DKCommandClipboardHistory,
                    ^{ [launcher pushScreen:DKClipboardPage(launcher)]; }),
    ];
}

/// Every item of the root list and the commands among them. They are made again only when
/// what they show has changed, so a row that is the same from one query to the next is the
/// same object, which is how the list knows it has nothing to do.
static NSArray<DKItem *> *allItems, *commandItems;
/// The quicklinks the items were made from.
static NSArray<NSDictionary *> *listedQuicklinks;
/// What the root list was last asked for: the query its rows answer.
static NSString *listedQuery;

static void MakeItems(void) {
    NSMutableArray<DKItem *> *all = [NSMutableArray new];
    NSSet<NSString *> *running = DKRunningApplicationPaths();
    for (NSDictionary *app in DKApplications()) [all addObject:ApplicationItem(app, running)];
    listedQuicklinks = DKQuicklinks();
    for (NSDictionary *quicklink in listedQuicklinks) {
        DKItem *item = DKQuicklinkItem(launcher, quicklink);
        item.accessory = @"Quicklink";
        [all addObject:item];
    }
    commandItems = CommandItems();
    [all addObjectsFromArray:commandItems];
    for (DKItem *item in all) {
        NSString *key = item.key;
        for (DKAction *action in item.heldAction ? @[ item.actions.firstObject, item.heldAction ] : @[ item.actions.firstObject ]) {
            void (^run)(void) = action.handler;
            action.handler = ^{
                DKRecordUse(key, listedQuery);
                run();
            };
        }
    }
    allItems = all;
}

static NSArray<DKItem *> *RootItems(NSString *query) {
    if (!allItems || DKQuicklinks() != listedQuicklinks) MakeItems();
    listedQuery = [query copy];
    NSArray<DKItem *> *all = allItems, *commands = commandItems;

    if (!query.length) {
        NSMutableArray<DKItem *> *used = [NSMutableArray new];
        NSMutableDictionary<NSString *, NSNumber *> *frecency = [NSMutableDictionary new];
        for (DKItem *item in all) {
            double score = DKFrecency(item.key);
            if (score <= 0) continue;
            frecency[item.key] = @(score);
            [used addObject:item];
        }
        [used sortUsingComparator:^NSComparisonResult(DKItem *a, DKItem *b) { return [frecency[b.key] compare:frecency[a.key]]; }];
        NSMutableArray *rows = [NSMutableArray new];
        for (DKItem *item in [used subarrayWithRange:NSMakeRange(0, MIN(used.count, kSuggestionCount))]) {
            item.section = @"Suggestions";
            [rows addObject:item];
        }
        // Commands already among the suggestions are not listed twice.
        for (DKItem *item in commands) {
            if ([rows containsObject:item]) continue;
            item.section = @"Commands";
            [rows addObject:item];
        }
        return rows;
    }

    NSMutableArray<DKItem *> *matches = [NSMutableArray new];
    NSMutableDictionary<NSString *, NSValue *> *ranks = [NSMutableDictionary new];
    for (DKItem *item in all) {
        DKRank rank;
        if (!Rank(&rank, item, query)) continue;
        item.section = @"Results";
        ranks[item.key] = [NSValue valueWithBytes:&rank objCType:@encode(DKRank)];
        [matches addObject:item];
    }
    [matches sortUsingComparator:^NSComparisonResult(DKItem *a, DKItem *b) {
        DKRank rankA, rankB;
        [ranks[a.key] getValue:&rankA size:sizeof rankA];
        [ranks[b.key] getValue:&rankB size:sizeof rankB];
        return DKCompareRanks(&rankA, a.title, &rankB, b.title, query);
    }];
    // Raycast's calculator card heads the results whenever the query computes.
    DKItem *calculation = DKCalculatorItem(launcher, query);
    if (calculation) [matches insertObject:calculation atIndex:0];
    [matches addObject:GoogleSearchItem(query)];
    return matches;
}

int DKPrintRanking(NSString *query, NSUInteger count) {
    DKStartApplicationIndex();
    NSArray<DKItem *> *rows = RootItems(query);
    for (DKItem *item in [rows subarrayWithRange:NSMakeRange(0, MIN(count, rows.count))]) {
        DKRank rank = {0};
        BOOL ranked = query.length && Rank(&rank, item, query);
        printf("%s\t%s\t%g\t%.3f\t%ld\t%s\n", item.title.UTF8String, item.accessory.UTF8String, ranked ? rank.match : 0,
               ranked ? rank.frecency : DKFrecency(item.key), (long)rank.remembered, item.key.UTF8String);
    }
    return 0;
}

static void MakePicker(void) {
    DKStartApplicationIndex();
    DKPage *root = [DKPage new];
    root.placeholder = @"Search for apps or commands...";
    root.items = ^NSArray *(NSString *query) { return RootItems(query); };
    launcher = [[DKPicker alloc] initWithRootPage:root logo:DKLogo()];
    [NSNotificationCenter.defaultCenter addObserverForName:DKWebIconDidLoadNotification object:nil queue:nil
                                                usingBlock:^(NSNotification *note) {
        // An item keeps the icon it was first shown with, listed or not.
        for (DKItem *item in allItems) item.icon = nil;
        [launcher reloadIcons];
    }];
    [NSNotificationCenter.defaultCenter addObserverForName:DKApplicationsDidChangeNotification object:nil queue:nil
                                                usingBlock:^(NSNotification *note) {
        allItems = nil;
        [launcher reload];
    }];
    // New exchange rates change the answer of a currency calculation on screen.
    [NSNotificationCenter.defaultCenter addObserverForName:DKCurrenciesDidUpdateNotification object:nil queue:nil
                                                usingBlock:^(NSNotification *note) { [launcher reload]; }];
    // The history is read in the background, and may come after its screen was opened.
    [NSNotificationCenter.defaultCenter addObserverForName:DKClipboardHistoryDidLoadNotification object:DKClipboardHistory.shared
                                                     queue:nil usingBlock:^(NSNotification *note) { [launcher reload]; }];
}

/// The picker, warmed up once deskkit's start is over, so that the first hotkey finds it ready.
static void MakeWarmPicker(void) {
    MakePicker();
    DKWarmCalculator();
    [DKCurrencies.shared refresh:NO];
    DKWarmFileIcons([DKApplications() valueForKey:@"path"]);
    dispatch_async(dispatch_get_main_queue(), ^{ [launcher warmUp]; });
}

void DKStartLauncher(void) {
    MakeWarmPicker();
    [DKHotkey key:kVK_Space modifiers:cmdKey handler:^(BOOL pressed) {
        if (!pressed) return;
        if (launcher.visible) return [launcher dismiss];
        [launcher show];
    }];
    [DKHotkey key:kVK_ANSI_V modifiers:cmdKey | shiftKey handler:^(BOOL pressed) {
        if (!pressed) return;
        if (launcher.visible) return [launcher dismiss];
        [launcher showScreen:DKClipboardPage(launcher)];
    }];
}

DKPicker *DKBenchLauncher(void) {
    [DKClipboardHistory.shared load];
    MakeWarmPicker();
    return launcher;
}

void DKInspectLauncher(NSString *show) {
    [DKClipboardHistory.shared load];
    MakePicker();
    NSRange colon = [show rangeOfString:@":"];
    NSString *screen = colon.location == NSNotFound ? show : [show substringToIndex:colon.location];
    [launcher showForInspection:[screen isEqualToString:@"history"] ? DKClipboardPage(launcher) : nil];
    if ([screen isEqualToString:@"quicklinks"]) [launcher pushScreen:DKQuicklinksPage(launcher)];
    if ([screen isEqualToString:@"create"]) [launcher pushScreen:DKQuicklinkForm(launcher, nil)];
    if (colon.location != NSNotFound) [launcher search:[show substringFromIndex:NSMaxRange(colon)]];
    // After the search, so that "actions:1+2" opens the actions of that query's first row.
    if ([screen isEqualToString:@"actions"]) [launcher toggleActions];
}
