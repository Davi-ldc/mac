// Owns the quicklinks store (quicklinks.plist) and opening links.
#import <AppKit/AppKit.h>

#import "quicklinks.h"
#import "support.h"

static NSArray<NSDictionary *> *cached;
static NSDate *cachedModified;

static NSURL *StoreURL(void) { return [DKSupportDirectory() URLByAppendingPathComponent:@"quicklinks.plist"]; }

static NSDate *StoreModified(void) {
    return [NSFileManager.defaultManager attributesOfItemAtPath:StoreURL().path error:nil].fileModificationDate;
}

static void Store(NSArray<NSDictionary *> *links) {
    [links writeToURL:StoreURL() atomically:YES];
    cached = [links copy];
    cachedModified = StoreModified();
}

static NSArray<NSDictionary *> *Defaults(void) {
    NSDate *now = NSDate.date;
    NSMutableArray *defaults = [NSMutableArray new];
    for (NSArray *pair in @[ @[ @"downloads", @"~/Downloads" ], @[ @"documents", @"~/Documents" ],
                             @[ @"Gmail", @"https://mail.google.com" ], @[ @"Meet", @"https://meet.google.com" ],
                             @[ @"Claude", @"https://claude.ai" ], @[ @"GitHub", @"https://github.com" ] ])
        [defaults addObject:@{@"name" : pair[0], @"link" : pair[1], @"created" : now, @"updated" : now, @"opened" : @0}];
    return defaults;
}

NSArray<NSDictionary *> *DKQuicklinks(void) {
    NSDate *modified = StoreModified();
    if (cached && [modified isEqualToDate:cachedModified]) return cached;
    if (!modified) {
        Store(Defaults());
        return cached;
    }
    // A hand edit that broke the file keeps the last good list rather than being overwritten,
    // and entries without a name and a link are skipped.
    NSArray *links = [NSArray arrayWithContentsOfURL:StoreURL()];
    if (links)
        cached = [links filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id link, id bindings) {
            return [link isKindOfClass:NSDictionary.class] && [link[@"name"] isKindOfClass:NSString.class] &&
                   [link[@"link"] isKindOfClass:NSString.class];
        }]];
    cachedModified = modified;
    return cached ?: @[];
}

static NSUInteger IndexOf(NSArray<NSDictionary *> *links, NSString *name) {
    return [links indexOfObjectPassingTest:^BOOL(NSDictionary *link, NSUInteger i, BOOL *stop) {
        return [link[@"name"] isEqualToString:name];
    }];
}

NSArray<NSDictionary *> *DKSublinks(NSDictionary *quicklink) {
    NSArray *sublinks = quicklink[@"sublinks"];
    if (![sublinks isKindOfClass:NSArray.class]) return @[];
    return [sublinks filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id sublink, id bindings) {
        return [sublink isKindOfClass:NSDictionary.class] && [sublink[@"title"] isKindOfClass:NSString.class] &&
               [sublink[@"url"] isKindOfClass:NSString.class];
    }]];
}

void DKSaveQuicklink(NSString *oldName, NSString *name, NSString *link, NSArray<NSDictionary *> *sublinks) {
    NSMutableArray *links = [DKQuicklinks() mutableCopy];
    NSUInteger index = oldName ? IndexOf(links, oldName) : NSNotFound;
    NSMutableDictionary *entry = index == NSNotFound ? [@{@"created" : NSDate.date, @"opened" : @0} mutableCopy]
                                                     : [links[index] mutableCopy];
    entry[@"name"] = name;
    entry[@"link"] = link;
    entry[@"sublinks"] = sublinks.count ? sublinks : nil;
    entry[@"updated"] = NSDate.date;
    if (index == NSNotFound) [links addObject:entry];
    else links[index] = entry;
    Store(links);
}

void DKDeleteQuicklink(NSString *name) {
    NSMutableArray *links = [DKQuicklinks() mutableCopy];
    NSUInteger index = IndexOf(links, name);
    if (index == NSNotFound) return;
    [links removeObjectAtIndex:index];
    Store(links);
}

NSURL *DKQuicklinkURL(NSString *link) {
    if ([link hasPrefix:@"/"] || [link hasPrefix:@"~"]) return [NSURL fileURLWithPath:link.stringByExpandingTildeInPath];
    NSURL *url = [NSURL URLWithString:[link containsString:@"://"] ? link : [@"https://" stringByAppendingString:link]];
    BOOL web = [url.scheme isEqualToString:@"http"] || [url.scheme isEqualToString:@"https"];
    return url.scheme.length && (url.host.length || !web) ? url : nil;
}

void DKOpenURL(NSURL *url) {
    NSURL *safari = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:@"com.apple.Safari"];
    if (safari && [url.scheme hasPrefix:@"http"])
        [NSWorkspace.sharedWorkspace openURLs:@[ url ] withApplicationAtURL:safari
                                configuration:[NSWorkspaceOpenConfiguration configuration] completionHandler:nil];
    else
        [NSWorkspace.sharedWorkspace openURL:url];
}

void DKOpenQuicklink(NSDictionary *quicklink, NSDictionary *sublink) {
    NSURL *url = DKQuicklinkURL((sublink ? sublink[@"url"] : quicklink[@"link"]) ?: @"");
    if (!url) return;
    DKOpenURL(url);
    NSMutableArray *links = [DKQuicklinks() mutableCopy];
    NSUInteger index = IndexOf(links, quicklink[@"name"]);
    if (index == NSNotFound) return;
    NSMutableDictionary *entry = [links[index] mutableCopy];
    entry[@"opened"] = @([entry[@"opened"] integerValue] + 1);
    links[index] = entry;
    Store(links);
}
