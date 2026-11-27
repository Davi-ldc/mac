// Owns the quicklink screens: the list with each link's details, the form, the row actions,
// and the list of a quicklink's sub-links.
#import "icons.h"
#import "quicklinks.h"
#import "quicklinkscreens.h"
#import "ranking.h"
#import "support.h"
#import "theme.h"
#import "webicons.h"

static NSString *DisplayLink(NSString *link) { return [link hasPrefix:@"~"] ? link.stringByExpandingTildeInPath : link; }

static NSImage *QuicklinkIcon(NSString *link) {
    NSURL *url = DKQuicklinkURL(link);
    if (url.isFileURL) return DKFileIcon(url.path);
    return url.host.length ? DKWebIcon(url.host) : DKSymbolIcon(@"link");
}

/// The form's text for sub-links: one per line, "title | link" and " | icon" when it has one.
static NSString *SublinkLines(NSArray<NSDictionary *> *sublinks) {
    NSMutableArray<NSString *> *lines = [NSMutableArray new];
    for (NSDictionary *sublink in sublinks) {
        NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithObjects:sublink[@"title"], sublink[@"url"], nil];
        NSString *icon = sublink[@"icon"];
        if ([icon isKindOfClass:NSString.class] && icon.length) [parts addObject:icon];
        [lines addObject:[parts componentsJoinedByString:@" | "]];
    }
    return [lines componentsJoinedByString:@"\n"];
}

/// A line of the form's text in its parts, trimmed.
static NSArray<NSString *> *LineParts(NSString *line) {
    NSMutableArray<NSString *> *parts = [NSMutableArray new];
    for (NSString *part in [line componentsSeparatedByString:@"|"])
        [parts addObject:[part stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]];
    return parts;
}

/// The sub-links the form's text lists, or nil and in `error` what is wrong with a line.
static NSArray<NSDictionary *> *ParseSublinks(NSString *text, NSString **error) {
    NSCharacterSet *space = NSCharacterSet.whitespaceCharacterSet;
    NSArray<NSString *> *lines = [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
    NSMutableArray<NSDictionary *> *sublinks = [NSMutableArray new];
    for (NSUInteger i = 0; i < lines.count; i++) {
        if (![lines[i] stringByTrimmingCharactersInSet:space].length) continue;
        NSArray<NSString *> *parts = LineParts(lines[i]);
        if (parts.count < 2 || parts.count > 3 || !parts[0].length || !parts[1].length) {
            *error = [NSString stringWithFormat:@"Sub-link line %lu should read title | link | icon, the icon optional.", (unsigned long)i + 1];
            return nil;
        }
        if (!DKQuicklinkURL(parts[1])) {
            *error = [NSString stringWithFormat:@"Sub-link line %lu: the link is neither a web address nor a folder path.", (unsigned long)i + 1];
            return nil;
        }
        NSMutableDictionary *sublink = [@{@"title" : parts[0], @"url" : parts[1]} mutableCopy];
        if (parts.count == 3 && parts[2].length) sublink[@"icon"] = parts[2];
        [sublinks addObject:sublink];
    }
    return sublinks;
}

DKForm *DKQuicklinkForm(DKPicker *picker, NSDictionary *existing) {
    DKForm *form = [DKForm new];
    form.title = existing ? @"Edit Quicklink" : @"Create Quicklink";
    form.icon = DKCommandIcon(DKCommandSearchQuicklinks);
    form.submitTitle = @"Save Quicklink";
    DKFormField *link = [DKFormField fieldWithLabel:@"Link" placeholder:@"https://example.com" value:existing[@"link"]];
    link.multiline = YES;
    link.info = @"A web address, opened in Safari, or a folder such as ~/Downloads, opened in Finder.";
    DKFormField *sublinks = [DKFormField fieldWithLabel:@"Sub-links" placeholder:@"Work | https://example.com/work | avatars/work.png"
                                                  value:existing ? SublinkLines(DKSublinks(existing)) : nil];
    sublinks.multiline = sublinks.oneEntryPerLine = YES;
    // A picture dropped on a line becomes that sub-link's icon, kept in deskkit's folder
    // under the title's name.
    sublinks.lineForDroppedFile = ^NSString *(NSString *line, NSURL *file) {
        NSArray<NSString *> *parts = LineParts(line);
        if (parts.count < 2 || !parts[0].length) return nil;
        NSString *name = [[parts[0] stringByReplacingOccurrencesOfString:@"/" withString:@"-"]
            stringByAppendingPathExtension:file.pathExtension.lowercaseString];
        NSURL *copy = [DKSupportSubdirectory(@"sublink-icons") URLByAppendingPathComponent:name];
        [NSFileManager.defaultManager removeItemAtURL:copy error:nil];
        if (![NSFileManager.defaultManager copyItemAtURL:file toURL:copy error:nil]) return nil;
        return [@[ parts[0], parts[1], [@"sublink-icons" stringByAppendingPathComponent:name] ] componentsJoinedByString:@" | "];
    };
    sublinks.info = @"One per line: title | link | icon. Choosing the quicklink then lists them.";
    form.fields = @[ link, [DKFormField fieldWithLabel:@"Name" placeholder:@"Quicklink name" value:existing[@"name"]], sublinks ];
    form.submit = ^NSString *(NSArray<NSString *> *values) {
        NSCharacterSet *space = NSCharacterSet.whitespaceAndNewlineCharacterSet;
        NSString *target = [values[0] stringByTrimmingCharactersInSet:space];
        NSString *name = [values[1] stringByTrimmingCharactersInSet:space];
        if (!target.length) return @"Enter a link.";
        if (!DKQuicklinkURL(target)) return @"This is neither a web address nor a folder path.";
        if (!name.length) return @"Enter a name.";
        for (NSDictionary *other in DKQuicklinks())
            if ([other[@"name"] isEqualToString:name] && ![name isEqualToString:existing[@"name"]])
                return @"Another quicklink already has this name.";
        NSString *error;
        NSArray<NSDictionary *> *choices = ParseSublinks(values[2], &error);
        if (!choices) return error;
        DKSaveQuicklink(existing[@"name"], name, target, choices);
        return nil;
    };
    return form;
}

static DKAction *CopyLinkAction(DKPicker *picker, NSString *link) {
    __weak DKPicker *weakPicker = picker;
    return [DKAction actionWithTitle:@"Copy Link" symbol:@"doc.on.doc" shortcut:@"cmd+shift+c" handler:^{
        [NSPasteboard.generalPasteboard clearContents];
        [NSPasteboard.generalPasteboard setString:DisplayLink(link) forType:NSPasteboardTypeString];
        [weakPicker dismiss];
    }];
}

/// Colours of Google's palette, behind the initial of an account without a photo.
static const unsigned kInitialColors[] = {0x1A73E8, 0xD93025, 0xE8710A, 0x1E8E3E, 0x9334E6, 0x129EAF, 0xE52592, 0x795548};

/// A sub-link's icon in a circle, as account pictures are drawn: its image file, which is
/// in deskkit's folder unless the path starts with / or ~, or else Google's stand-in for an
/// account without a photo, the title's initial on a colour the title picks.
static NSImage *SublinkIcon(NSDictionary *sublink) {
    NSString *path = sublink[@"icon"];
    path = [path isKindOfClass:NSString.class] && path.length ? path.stringByExpandingTildeInPath : nil;
    if (path && !path.isAbsolutePath) path = [DKSupportDirectory() URLByAppendingPathComponent:path].path;
    NSImage *picture = path ? [[NSImage alloc] initWithContentsOfFile:path] : nil;
    if (picture.isValid) {
        NSImage *icon = [[NSImage alloc] initWithSize:NSMakeSize(DKIconSize, DKIconSize)];
        [icon addRepresentation:DKIconBitmap(picture, DKIconSize / 2)];
        return icon;
    }
    NSString *title = sublink[@"title"];
    NSString *initial = title.length ? [title substringWithRange:[title rangeOfComposedCharacterSequenceAtIndex:0]].uppercaseString : @"";
    NSUInteger hash = 0;
    for (NSUInteger i = 0; i < title.length; i++) hash = hash * 31 + [title characterAtIndex:i];
    unsigned rgb = kInitialColors[hash % (sizeof kInitialColors / sizeof *kInitialColors)];
    NSColor *color = [NSColor colorWithSRGBRed:(rgb >> 16) / 255.0 green:(rgb >> 8 & 0xff) / 255.0 blue:(rgb & 0xff) / 255.0 alpha:1];
    NSFont *font = DKFont(13, 500);
    NSDictionary *attributes = @{NSFontAttributeName : font, NSForegroundColorAttributeName : NSColor.whiteColor};
    return [NSImage imageWithSize:NSMakeSize(DKIconSize, DKIconSize) flipped:NO drawingHandler:^BOOL(NSRect rect) {
        [color setFill];
        [[NSBezierPath bezierPathWithOvalInRect:rect] fill];
        // Centred on its capital's height rather than on its line, which has room for descenders.
        CGFloat width = [initial sizeWithAttributes:attributes].width;
        [initial drawAtPoint:NSMakePoint((rect.size.width - width) / 2, (rect.size.height - font.capHeight) / 2 + font.descender)
              withAttributes:attributes];
        return YES;
    }];
}

/// The list a quicklink with sub-links opens: its choices in their order, found by title.
static DKPage *SublinksPage(DKPicker *picker, NSDictionary *quicklink) {
    __weak DKPicker *weakPicker = picker;
    NSMutableArray<DKItem *> *rows = [NSMutableArray new];
    for (NSDictionary *sublink in DKSublinks(quicklink)) {
        DKItem *item = [DKItem new];
        item.title = sublink[@"title"];
        item.key = [@"sublink:" stringByAppendingString:sublink[@"title"]];
        item.iconLoader = ^NSImage *{ return SublinkIcon(sublink); };
        item.actions = @[
            [DKAction actionWithTitle:@"Open Link" symbol:@"arrow.up.right.square" shortcut:@"return" handler:^{
                [weakPicker hide];
                DKOpenQuicklink(quicklink, sublink);
            }],
            CopyLinkAction(picker, sublink[@"url"]),
        ];
        [rows addObject:item];
    }
    DKPage *page = [DKPage new];
    page.title = quicklink[@"name"];
    page.icon = QuicklinkIcon(quicklink[@"link"]);
    page.placeholder = [NSString stringWithFormat:@"Search %@...", quicklink[@"name"]];
    page.items = ^NSArray *(NSString *query) {
        if (!query.length) return rows;
        return [rows filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(DKItem *item, id bindings) {
            return DKMatchScore(item.title, query) > 0;
        }]];
    };
    return page;
}

DKItem *DKQuicklinkItem(DKPicker *picker, NSDictionary *quicklink) {
    NSString *link = quicklink[@"link"];
    NSArray<NSDictionary *> *sublinks = DKSublinks(quicklink);
    __weak DKPicker *weakPicker = picker;
    DKItem *item = [DKItem new];
    item.title = quicklink[@"name"];
    item.key = [@"quicklink:" stringByAppendingString:quicklink[@"name"]];
    item.iconLoader = ^NSImage *{ return QuicklinkIcon(link); };
    DKAction *remove = [DKAction actionWithTitle:@"Delete Quicklink" symbol:@"trash" shortcut:@"ctrl+x" handler:^{
        DKDeleteQuicklink(quicklink[@"name"]);
        [weakPicker reload];
    }];
    remove.destructive = YES;
    item.actions = @[
        [DKAction actionWithTitle:@"Open Quicklink" symbol:@"arrow.up.right.square" shortcut:@"return" handler:^{
            if (sublinks.count) return [weakPicker pushScreen:SublinksPage(weakPicker, quicklink)];
            [weakPicker hide];
            DKOpenQuicklink(quicklink, nil);
        }],
        CopyLinkAction(picker, link),
        [DKAction actionWithTitle:@"Edit Quicklink" symbol:@"pencil" shortcut:@"cmd+e" handler:^{
            [weakPicker pushScreen:DKQuicklinkForm(weakPicker, quicklink)];
        }],
        remove,
    ];
    if (sublinks.count)
        item.heldAction = [DKAction actionWithTitle:@"Open First Sub-link" symbol:nil shortcut:nil handler:^{
            [weakPicker hide];
            DKOpenQuicklink(quicklink, sublinks.firstObject);
        }];
    return item;
}

static DKDetail *QuicklinkDetail(NSDictionary *quicklink) {
    NSInteger opened = [quicklink[@"opened"] integerValue];
    NSDate *created = quicklink[@"created"], *updated = quicklink[@"updated"];
    DKDetail *detail = [DKDetail new];
    detail.text = DisplayLink(quicklink[@"link"]);
    detail.metadata = @[
        @[ @"Name", quicklink[@"name"] ],
        @[ @"Link", DisplayLink(quicklink[@"link"]) ],
        @[ @"Created", created ? DKFormatDate(created) : @"—" ],
        @[ @"Last Updated", updated ? DKFormatDate(updated) : @"—" ],
        @[ @"Opened", opened ? [NSString stringWithFormat:@"%ld time%@", (long)opened, opened == 1 ? @"" : @"s"] : @"Never" ],
    ];
    return detail;
}

DKPage *DKQuicklinksPage(DKPicker *picker) {
    DKPage *page = [DKPage new];
    page.title = @"Search Quicklinks";
    page.icon = DKCommandIcon(DKCommandSearchQuicklinks);
    page.placeholder = @"Search for Quicklinks...";
    page.showsDetail = YES;
    __weak DKPicker *weakPicker = picker;
    page.items = ^NSArray *(NSString *query) {
        NSMutableArray *items = [NSMutableArray new];
        for (NSDictionary *quicklink in DKQuicklinks()) {
            if (query.length && DKMatchScore(quicklink[@"name"], query) <= 0 && DKMatchScore(quicklink[@"link"], query) <= 0)
                continue;
            DKItem *item = DKQuicklinkItem(weakPicker, quicklink);
            item.section = @"Quicklinks";
            item.detail = ^DKDetail *{ return QuicklinkDetail(quicklink); };
            [items addObject:item];
        }
        return items;
    };
    return page;
}
