// The Files tab and a conversation's "Files and links": the explorer's requests as the web client
// sends them, the links, the recently viewed files, the shared lists behind the tab and its peek,
// and the navigation between them, over the public fixture's made-up files and links in Slack's
// shapes.
#import "app/launch.h"
#import "model/json.h"
#import "net/switches.h"
#import "render/strings.h"
#import "store/fixture.h"
#import "test.h"
#import "ui/channel/pane.h"
#import "ui/composer/composer.h"
#import "ui/files/attachments.h"
#import "ui/files/browser.h"
#import "ui/files/peek.h"
#import "ui/files/rows.h"
#import "ui/files/sidebar.h"
#import "ui/files/tab.h"
#import "ui/shell/shell.h"

static SNShell *Shell(id<SNSource> source, SNLocation *location) {
    SNSetLanguage(@"en");
    SNShell *shell = [[SNShell alloc] initWithSource:source defaults:nil];
    [shell go:location];
    [shell.window.contentView layoutSubtreeIfNeeded];
    return shell;
}

/// The last call of `method` and its parameters.
static NSDictionary *LastCall(SNFixtureSource *source, NSString *method) {
    for (NSArray *call in source.calls.reverseObjectEnumerator)
        if ([call[0] isEqualToString:method]) return call[1];
    return nil;
}

SN_TEST(FilesSearchWordsAsTheClient) {
    SNFileSearch *search = [SNFileSearch new];
    search.query = @" roadmap ";
    search.conversationID = @"C1";
    search.excludedFileTypes = @[ SNFileTypeImages, SNFileTypeVideos, SNFileTypeFolders ];
    SNExpect([[search requestQueryWithReference:@"<#C1|general>"] isEqualToString:@"roadmap in:<#C1|general> -type:images -type:videos -type:folder"],
             "typed words, then in: and the excluded types");
    search.query = @"";
    search.conversationID = nil;
    search.excludedFileTypes = @[];
    search.fileTypes = SNFileTypesAll();
    search.creatorID = @"U1";
    SNExpect([[search requestQueryWithReference:nil] isEqualToString:@"type:lists type:quip type:documents type:spreadsheets type:presentations type:pdfs creator:<@U1>"],
             "All files' types and Created by you");
    SNChannelLink *link = [SNChannelLink linkWithJSON:@{@"url" : @"https://github.com/a/b", @"title" : @"", @"icon_url" : @"https://github.com/favicon.ico", @"timestamp" : @"1795290500.000000"}];
    SNExpect(link && !link.title && link.timestamp == 1795290500 && [link.iconURL.host isEqualToString:@"github.com"], "a link: an empty title is none, timestamp as Slack sends it");
    SNExpect(![SNChannelLink linkWithJSON:@{@"url" : @"not a url"}], "an item without an address is no link");
    SNFile *file = [SNFile fileWithJSON:@{@"id" : @"F1", @"created" : @1795100000, @"updated" : @1795380000, @"last_read" : @1795390000123, @"username" : @"bot"}];
    SNExpect(file.lastRead == 1795390000 && file.updated == 1795380000 && [file.userName isEqualToString:@"bot"], "last_read in milliseconds reads as seconds");
}

SN_TEST(FilesExplorerRequests) {
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    SNConversationAttachments *attachments = [[SNConversationAttachments alloc] initWithSource:source conversationID:@"C02RANDOM"];
    __block NSInteger changes = 0;
    attachments.changed = ^{ changes++; };
    [attachments reload];
    SNExpect([attachments isLoading:SNAttachmentAll], "the three lists load at once");
    SNSettle(0.1);
    NSDictionary *files = nil;
    for (NSArray *call in source.calls)
        if ([call[0] isEqualToString:@"search.modules.files"] && [call[1][@"query"] containsString:@"-type:images"]) files = call[1];
    SNExpect([files[@"query"] isEqualToString:@"in:<#C02RANDOM|random> -type:images -type:videos -type:folder"], "files: the channel by name, no pictures, videos or folders");
    SNExpect([files[@"module"] isEqualToString:@"files"] && [files[@"search_context"] isEqualToString:@"desktop_files_channel_tab"] &&
                 [files[@"sort"] isEqualToString:@"timestamp"] && [files[@"sort_dir"] isEqualToString:@"desc"] && [files[@"count"] isEqualToString:@"50"],
             "newest first, 50 a page, as the channel tab");
    SNExpect([files[@"highlight"] isEqualToString:@"1"] && !files[@"browse"], "the filters make it a search, not a browse");
    NSDictionary *links = LastCall(source, @"conversations.searchLinks");
    SNExpect([links[@"channel_id"] isEqualToString:@"C02RANDOM"] && [links[@"sort"] isEqualToString:@"timestamp"] && [links[@"page"] isEqualToString:@"1"],
             "links: conversations.searchLinks newest first");
    NSArray<SNAttachment *> *mixed = [attachments mixedIncludingMedia:NO];
    SNExpect(mixed.count == 3 && mixed[0].link && mixed[1].file && mixed[2].link, "one list by when they were shared: link, file, link");
    SNExpect([mixed[1].file.fileID isEqualToString:@"F20MODEL"] && !attachments.media.count, "the channel's file, no media");
    SNExpect(changes >= 3 && ![attachments isLoading:SNAttachmentAll] && ![attachments hasMore:SNAttachmentFiles], "each answer tells the views; one page each");
    SNExpect(!SNIsMutatingMethod(@"search.modules.files") && !SNIsMutatingMethod(@"conversations.searchLinks"), "both are reads, allowed in read-only mode");

    attachments.sort = SNAttachmentOldest;
    SNSettle(0.1);
    mixed = [attachments mixedIncludingMedia:NO];
    SNExpect(mixed.firstObject.link && [mixed.firstObject.link.url.host isEqualToString:@"github.com"], "oldest first reverses the list");
    SNExpect([LastCall(source, @"conversations.searchLinks")[@"sort_dir"] isEqualToString:@"asc"], "and asks Slack in that order");
    attachments.query = @"modelo";
    SNSettle(0.1);
    SNExpect([LastCall(source, @"search.modules.files")[@"query"] hasPrefix:@"modelo in:<#C02RANDOM|random>"], "a search puts the words first");
    SNExpect(attachments.files.count == 1 && !attachments.links.count, "and finds what matches");
}

SN_TEST(FilesUnifiedBrowser) {
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    SNShell *shell = Shell(source, [SNLocation locationWithTab:SNTabHome conversation:@"C03DESIGN" thread:nil]);
    [shell selectTab:SNTabFiles];
    SNExpect([shell.location.page isEqualToString:SNPageFiles] && !shell.location.conversationID, "the Files tab opens on All files");
    SNSettle(0.1);
    [shell.window.contentView layoutSubtreeIfNeeded];
    SNFilesBrowserView *browser = nil;
    for (NSView *view in [shell paneInSlot:SNPaneSlotPrimary].view.subviews)
        if ([view isKindOfClass:SNFilesBrowserView.class]) browser = (SNFilesBrowserView *)view;
    SNExpect(browser && !browser.hidden, "the files browser fills the conversation column");
    NSDictionary *call = LastCall(source, @"search.modules.files");
    SNExpect([call[@"query"] isEqualToString:@"type:lists type:quip type:documents type:spreadsheets type:presentations type:pdfs"] &&
                 [call[@"sort"] isEqualToString:@"last_engaged"] && !call[@"sort_dir"] && [call[@"search_context"] isEqualToString:@"desktop_files_browser"],
             "All files: Slack's default types, recently viewed");
    SNExpect(browser.files.count == 9, "every canvas, list, document, spreadsheet, presentation and PDF of the fixture");
    NSUInteger rows = 0;
    for (NSView *item in browser.items) rows += [item isKindOfClass:SNFileRow.class];
    SNExpect(rows == 9, "a row each");

    browser.filter = @"created";
    SNSettle(0.1);
    call = LastCall(source, @"search.modules.files");
    SNExpect([call[@"query"] hasSuffix:@"creator:<@U01ALEX>"] && [call[@"sort"] isEqualToString:@"timestamp"], "Created by you: the user's, by last update");
    SNExpect(![call[@"query"] containsString:@"type:pdfs"], "only the kinds one creates");
    SNExpect(browser.files.count == 1 && [browser.files.firstObject.fileID isEqualToString:@"F21PLAN"], "the user's canvas");
    browser.filter = @"shared";
    SNSettle(0.1);
    call = LastCall(source, @"search.modules.files");
    SNExpect([call[@"shared_with_you"] isEqualToString:@"1"] && [call[@"search_only_my_channels"] isEqualToString:@"true"] && [call[@"sort"] isEqualToString:@"score"],
             "Shared with you: the user's channels, by relevance");
    browser.filter = @"all";
    browser.fileTypes = @[ SNFileTypePDFs ];
    SNSettle(0.1);
    SNExpect([LastCall(source, @"search.modules.files")[@"query"] isEqualToString:@"type:pdfs"] && browser.files.count == 2, "one type: the PDFs");
    browser.fileTypes = @[ SNFileTypeEmails ];
    SNSettle(0.1);
    SNExpect(!browser.files.count, "none of another");
    BOOL empty = NO;
    for (NSView *item in browser.items) empty |= [item isKindOfClass:NSClassFromString(@"SNExplorerEmptyState")];
    SNExpect(empty, "Slack's empty state");
    [browser search:@"plano"];
    SNSettle(0.1);
    SNExpect([LastCall(source, @"search.modules.files")[@"query"] hasPrefix:@"plano type:emails"] && [browser.sort isEqualToString:@"score"], "a search sorts by relevance");

    [shell go:[SNLocation locationWithTab:SNTabFiles conversation:nil thread:nil page:SNPageFilesCanvases panel:nil]];
    SNSettle(0.1);
    SNExpect([LastCall(source, @"search.modules.files")[@"query"] isEqualToString:@"type:quip"] && browser.files.count == 1, "Canvases: canvases only, filters reset");
    [shell selectTab:SNTabHome];
    SNExpect([shell.location.conversationID isEqualToString:@"C03DESIGN"] && !shell.location.page, "Home comes back to its conversation");
    [shell selectTab:SNTabFiles];
    SNExpect([shell.location.page isEqualToString:SNPageFilesCanvases], "and Files to its page");
}

SN_TEST(FilesSidebarAndRecentlyViewed) {
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    SNShell *shell = Shell(source, [SNLocation locationWithTab:SNTabFiles conversation:nil thread:nil page:SNPageFiles panel:nil]);
    SNFilesSidebarPane *pane = (SNFilesSidebarPane *)[shell paneForTab:SNTabFiles];
    SNExpect([pane isKindOfClass:SNFilesSidebarPane.class] && pane.view.superview, "the Files tab has its own sidebar");
    SNExpect(pane.rows.count == 3, "All files, Canvases, Lists; nothing viewed yet");
    [(SNHoverView *)pane.rows[2] action]((SNHoverView *)pane.rows[2]);
    SNExpect([shell.location.page isEqualToString:SNPageFilesLists], "a page row shows its page");

    NSMutableArray<SNFile *> *files = [NSMutableArray new];
    for (int i = 0; i < 12; i++) [files addObject:[SNFile fileWithJSON:@{@"id" : [NSString stringWithFormat:@"F9%02d", i], @"title" : @"Plano", @"filetype" : @"quip"}]];
    for (SNFile *file in files) [source noteFileViewed:file];
    [source noteFileViewed:files[3]];
    SNExpect(source.recentFiles.count == 10 && [source.recentFiles.firstObject.fileID isEqualToString:@"F903"], "the ten opened last, most recent first");
    [source forgetRecentFile:@"F903"];
    SNExpect(source.recentFiles.count == 9 && ![[source.recentFiles valueForKey:@"fileID"] containsObject:@"F903"], "removing one");
    SNExpect(pane.rows.count == 3 + 2 + 9, "then a divider, Recently viewed and the files");
}

SN_TEST(FilesTabAndPeekInAConversation) {
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    SNShell *shell = Shell(source, [SNLocation locationWithTab:SNTabHome conversation:@"C02RANDOM" thread:nil]);
    SNChannelPane *pane = (SNChannelPane *)[shell paneInSlot:SNPaneSlotPrimary];
    [pane.header showFilesPreview];
    SNExpect(SNFilesPeek.current && SNFilesPeek.current.list.rows.count == 7, "the peek opens on the skeleton");
    SNExpect(NSHeight(SNFilesPeek.current.panel.frame) == 430, "420 pt of loading plus 10");
    SNSettle(0.1);
    NSArray<NSView *> *rows = SNFilesPeek.current.list.rows;
    SNExpect(rows.count == 3 && [rows[0] isKindOfClass:SNLinkRow.class] && [rows[1] isKindOfClass:SNFileRow.class], "then the links and files");
    SNExpect(NSHeight(rows[0].frame) == 63 && NSHeight(rows[1].frame) == 61 && NSHeight(rows[2].frame) == 62, "62 pt links, 60 pt files, a line between");
    SNExpect(NSHeight(SNFilesPeek.current.panel.frame) == 63 + 61 + 63 + 10 && NSWidth(SNFilesPeek.current.panel.frame) == 360, "the rows' estimates plus 10, 360 wide");
    SNFileRow *file = (SNFileRow *)rows[1];
    NSString *shared = SNFileRowDescription(file.file, SNFileRowDetailShared, source, [NSDate dateWithTimeIntervalSince1970:1795291000 + 40 * 86400]);
    SNExpect([shared hasPrefix:@"Shared by priya on "], "who shared it and on which day");
    SNExpect([SNFileRowDescription(file.file, SNFileRowDetailShared, source, [NSDate dateWithTimeIntervalSince1970:1795291000 + 60]) isEqualToString:@"Shared by priya today"],
             "today in words");
    SNExpect(file.actionButtons.count == 3, "download, open in browser, more");

    [pane.header.tabs[2] action](pane.header.tabs[2]);
    SNExpect(!SNFilesPeek.current, "choosing the tab closes the peek");
    SNExpect([shell.location.page isEqualToString:SNPageConversationFiles] && [shell.location.conversationID isEqualToString:@"C02RANDOM"], "and shows the conversation's files");
    SNExpect(pane.header.selectedTab == 2 && pane.list.hidden && pane.composer.hidden, "in place of the messages and composer");
    SNSettle(0.1);
    SNConversationFilesView *tab = nil;
    for (NSView *view in pane.view.subviews)
        if ([view isKindOfClass:SNConversationFilesView.class]) tab = (SNConversationFilesView *)view;
    NSUInteger fileRows = 0, linkRows = 0;
    for (NSView *item in tab.items) fileRows += [item isKindOfClass:SNFileRow.class], linkRows += [item isKindOfClass:SNLinkRow.class];
    SNExpect(tab && !tab.hidden && fileRows == 1 && linkRows == 2, "All: the file and the links");
    tab.kind = SNAttachmentLinks;
    linkRows = fileRows = 0;
    for (NSView *item in tab.items) fileRows += [item isKindOfClass:SNFileRow.class], linkRows += [item isKindOfClass:SNLinkRow.class];
    SNExpect(linkRows == 2 && !fileRows, "Links: only the links");
    tab.kind = SNAttachmentMedia;
    BOOL empty = NO;
    for (NSView *item in tab.items) empty |= [item isKindOfClass:NSClassFromString(@"SNExplorerEmptyState")];
    SNExpect(empty, "Media: none here");
    [pane.header.tabs[0] action](pane.header.tabs[0]);
    SNExpect(!shell.location.page && pane.header.selectedTab == 0 && !pane.list.hidden && !pane.composer.hidden && tab.hidden, "Messages comes back");

    [shell go:[SNLocation locationWithTab:SNTabHome conversation:@"G04ENG" thread:nil]];
    [pane.header showFilesPreview];
    SNSettle(0.1);
    SNExpect(SNFilesPeek.current.list.rows.count == 0 && NSHeight(SNFilesPeek.current.panel.frame) == 200, "an empty conversation's peek: 200 pt");
    [SNFilesPeek.current close];
}

SN_TEST(FilesBrowserAndTabControlsDoNotOverlapAtNarrowWidths) {
    SNSetLanguage(@"pt-BR");
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    SNShell *shell = [[SNShell alloc] initWithSource:source defaults:nil];
    [shell go:[SNLocation locationWithTab:SNTabFiles conversation:nil thread:nil page:SNPageFiles panel:nil]];
    [shell.window setContentSize:NSMakeSize(1020, 680)];
    [shell.window.contentView layoutSubtreeIfNeeded];
    SNFilesBrowserView *browser = nil;
    for (NSView *sub in [shell paneInSlot:SNPaneSlotPrimary].view.subviews)
        if ([sub isKindOfClass:SNFilesBrowserView.class]) browser = (SNFilesBrowserView *)sub;
    SNExpect(browser != nil, "files browser visible");
    NSView *filters = [browser valueForKey:@"filters"], *types = [browser valueForKey:@"types"];
    NSView *sortSelect = [browser valueForKey:@"sortSelect"], *advanced = [browser valueForKey:@"advanced"];
    SNExpect(!NSIntersectsRect(filters.frame, types.frame) && !NSIntersectsRect(filters.frame, sortSelect.frame) &&
                 !NSIntersectsRect(filters.frame, advanced.frame) && !NSIntersectsRect(types.frame, sortSelect.frame) &&
                 !NSIntersectsRect(sortSelect.frame, advanced.frame),
             "files browser controls wrap without overlapping in pt-BR at narrow widths");

    // Files peek stays clamped inside short window bounds.
    [shell go:[SNLocation locationWithTab:SNTabHome conversation:@"C02RANDOM" thread:nil]];
    [shell.window setContentSize:NSMakeSize(900, 500)];
    [shell.window.contentView layoutSubtreeIfNeeded];
    SNChannelPane *pane = (SNChannelPane *)[shell paneInSlot:SNPaneSlotPrimary];
    [pane.header showFilesPreview];
    SNSettle(0.15);
    NSRect peekFrame = SNFilesPeek.current.panel.frame;
    NSRect hostBounds = SNFilesPeek.current.panel.superview.bounds;
    SNExpect(NSMinX(peekFrame) >= 8 && NSMinY(peekFrame) >= 8 && NSMaxX(peekFrame) <= NSMaxX(hostBounds) - 8 && NSMaxY(peekFrame) <= NSMaxY(hostBounds) - 8,
             "files peek panel clamps within window bounds");
    [SNFilesPeek.current close];
    SNSetLanguage(@"en");
}
