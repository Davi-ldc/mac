// Files in the message list: every kind of the public fixture's files conversation (made-up
// values in Slack's shapes) rendered offscreen in the conversation and thread columns, hovered
// and expanded, and the players' lifecycle: made on play, released when hidden or recycled.
#import "app/launch.h"
#import "model/json.h"
#import "render/images.h"
#import "snapshot.h"
#import "test.h"
#import "ui/channel/list.h"
#import "ui/files/filenet.h"
#import "ui/files/mediaview.h"

static NSArray<SNMessage *> *FileMessages(void) {
    NSData *data = [NSData dataWithContentsOfURL:[SNPublicFixture() URLByAppendingPathComponent:@"conversations.history/C05FILES.json"]];
    NSArray *items = SNJSONArray([NSJSONSerialization JSONObjectWithData:data options:0 error:nil], @"messages");
    NSMutableArray<SNMessage *> *messages = [NSMutableArray new];
    for (NSDictionary *item in items.reverseObjectEnumerator) [messages addObject:[SNMessage messageWithJSON:item conversationID:@"C05FILES"]];
    return messages;
}

/// A list on the conversation background in an offscreen window, showing the files conversation.
static SNMessageListView *FilesList(id<SNSource> source, NSSize size, SNMessageListMode mode) {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:(NSRect){NSZeroPoint, size} styleMask:NSWindowStyleMaskBorderless
                                                     backing:NSBackingStoreBuffered
                                                       defer:YES];
    window.releasedWhenClosed = NO;
    NSView *background = [[NSView alloc] initWithFrame:(NSRect){NSZeroPoint, size}];
    background.wantsLayer = YES;
    background.layer.backgroundColor = SNCGColor(SNColorBasePry);
    window.contentView = background;
    SNMessageListView *list = [[SNMessageListView alloc] initWithSource:source mode:mode];
    list.frame = background.bounds;
    [background addSubview:list];
    NSArray<SNMessage *> *messages = FileMessages();
    [list showMessages:messages inConversation:@"C05FILES" threadTS:mode == SNMessageListThread ? messages.firstObject.ts : nil lastRead:nil];
    [list layoutSubtreeIfNeeded];
    return list;
}

static SNFileView *FileViewOf(SNMessageListView *list, NSString *fileID) {
    for (SNMessage *message in FileMessages()) {
        SNMessageRowView *row = [list rowForTS:message.ts];
        for (NSView *view in row.subviews)
            if ([view isKindOfClass:SNFileView.class] && [((SNFileView *)view).file.fileID isEqualToString:fileID]) return (SNFileView *)view;
    }
    return nil;
}


/// Every kind at the conversation's width, hovered, a snippet expanded, then the thread column.
SN_SNAPSHOT(ChannelFilesOfEveryKind) {
    id<SNSource> source = SNOpenFixture(SNPublicFixture());
    SNMessageListView *list = FilesList(source, NSMakeSize(840, 2400), SNMessageListChannel);
    [list scrollToOffset:0];
    NSView *column = list.superview;
    // The first render starts the posters and pages loading; the second has them.
    SNRenderView(column, column.frame.size);
    SNSaveSnapshot(@"channel_files", SNRenderView(column, column.frame.size));
    for (NSString *fileID in @[ @"F10CLIP", @"F11REPORT", @"F13NOTES", @"F15VOICE", @"F16ASSETS" ]) {
        SNFileView *view = FileViewOf(list, fileID);
        SNExpect(view != nil, [NSString stringWithFormat:@"%@ shown", fileID].UTF8String);
        view.hovered = YES;
    }
    SNSettle(0.3);
    SNSaveSnapshot(@"channel_files_hover", SNRenderView(column, column.frame.size));
    for (NSString *fileID in @[ @"F10CLIP", @"F11REPORT", @"F13NOTES", @"F15VOICE", @"F16ASSETS" ]) FileViewOf(list, fileID).hovered = NO;
    NSString *notes = [NSString stringWithContentsOfURL:[SNPublicFixture() URLByAppendingPathComponent:@"images/release-notes.txt"] encoding:NSUTF8StringEncoding error:NULL];
    [FileViewOf(list, @"F13NOTES") expandWithContent:notes];
    NSString *hours = [NSString stringWithContentsOfURL:[SNPublicFixture() URLByAppendingPathComponent:@"images/hours.csv"] encoding:NSUTF8StringEncoding error:NULL];
    [FileViewOf(list, @"F14HOURS") expandWithContent:hours];
    [list scrollToBottom];
    FileViewOf(list, @"F14HOURS").hovered = YES;
    SNSettle(0.3);
    SNSaveSnapshot(@"channel_files_expanded", SNRenderView(column, column.frame.size));
    FileViewOf(list, @"F14HOURS").hovered = NO;
    SNMessageListView *thread = FilesList(source, NSMakeSize(393, 2400), SNMessageListThread);
    [thread scrollToOffset:0];
    SNRenderView(thread.superview, thread.superview.frame.size);
    SNSaveSnapshot(@"thread_files", SNRenderView(thread.superview, thread.superview.frame.size));
}

SN_TEST(ChannelFilesTakeSlacksComponents) {
    id<SNSource> source = SNOpenFixture(SNPublicFixture());
    SNMessageListView *list = FilesList(source, NSMakeSize(840, 2400), SNMessageListChannel);
    SNFileView *video = FileViewOf(list, @"F10CLIP"), *pdf = FileViewOf(list, @"F11REPORT"), *zip = FileViewOf(list, @"F16ASSETS"), *docx = FileViewOf(list, @"F17BRIEF");
    SNExpect([video isKindOfClass:SNMediaFileView.class] && [FileViewOf(list, @"F15VOICE") isKindOfClass:SNMediaFileView.class], "videos and clips get players");
    // getDimensions: a 480x608 portrait poster in a 764 pt column is capped at 354 tall.
    SNExpect(NSEqualSizes(video.frame.size, NSMakeSize(279, 354)), "the video box by Slack's caps");
    SNExpect(pdf.frame.size.width == 426 && pdf.frame.size.height == 1 + 12 + 36 + 12 + 1 + 200 + 1, "a lone PDF shows its first page under the header");
    SNExpect(zip.frame.size.width == 328 && docx.frame.size.width == 328 && NSMinY(zip.frame) == NSMinY(docx.frame) && NSMinX(docx.frame) == NSMaxX(zip.frame) + 8,
             "two files share a row of 328 pt cards 8 pt apart");
    SNFileView *notes = FileViewOf(list, @"F13NOTES");
    // Six preview lines on 19.5 pt with 4 pt above and below fit the 200 pt box.
    SNExpect(notes.frame.size.height == 22 + 1 + 4 + 6 * 19.5 + 4 + 1, "the preview's lines under the name");
    SNExpect(notes.frame.size.width == 840 - 76, "and spans the column");
    SNExpect(zip.actionButtons.count == 3 && pdf.actionButtons.count == 3, "download, open in the browser, more");
    SNExpect(FileViewOf(list, @"F14HOURS").actionButtons.count == 2, "a CSV does not open in a new window");
}

SN_TEST(ChannelSnippetExpandsInPlace) {
    id<SNSource> source = SNOpenFixture(SNPublicFixture());
    SNMessageListView *list = FilesList(source, NSMakeSize(840, 2400), SNMessageListChannel);
    SNFileView *notes = FileViewOf(list, @"F13NOTES");
    CGFloat collapsed = notes.frame.size.height, rowHeight = notes.superview.frame.size.height;
    NSMutableArray *lines = [NSMutableArray new];
    for (int i = 1; i <= 600; i++) [lines addObject:[NSString stringWithFormat:@"line %d", i]];
    [notes expandWithContent:[lines componentsJoinedByString:@"\n"]];
    notes = FileViewOf(list, @"F13NOTES");
    SNExpect(notes.isExpanded && notes.frame.size.height > collapsed + 500 * 19 && notes.superview.frame.size.height > rowHeight, "the row grows to the whole text");
    SNExpect(notes.actionButtons.count == 4, "Collapse joins the actions");
    [notes toggleExpansion];
    notes = FileViewOf(list, @"F13NOTES");
    SNExpect(!notes.isExpanded && notes.frame.size.height == collapsed, "collapsing gives the 200 pt box back");
    SNMessageListView *thread = FilesList(source, NSMakeSize(393, 2400), SNMessageListThread);
    SNExpect(!FileViewOf(thread, @"F13NOTES").isExpanded, "each column keeps its own expansion");
}

SN_TEST(ChannelMediaPlaysOnlyWhenAsked) {
    id<SNSource> source = SNOpenFixture(SNPublicFixture());
    SNMessageListView *list = FilesList(source, NSMakeSize(840, 2400), SNMessageListChannel);
    SNMediaFileView *video = (SNMediaFileView *)FileViewOf(list, @"F10CLIP");
    SNExpect(video.media == nil, "nothing plays or loads before a click");
    SNSetFileCredentials(nil, nil);
    [video togglePlayback];
    SNExpect(video.media == nil, "without the session's cookies nothing streams");
    // Credentials, and a URL nothing answers on this Mac: the player is made, never reaching out.
    SNSetFileCredentials(^NSArray<NSHTTPCookie *> * { return @[]; }, @"test");
    SNFile *local = [SNFile fileWithJSON:@{@"id" : @"F0LOCAL", @"mimetype" : @"video/mp4", @"filetype" : @"mp4", @"mode" : @"hosted",
                                           @"mp4" : @"http://127.0.0.1:9/clip.mp4", @"duration_ms" : @4000}];
    SNMediaFileView *player = (SNMediaFileView *)SNMakeFileView(local, SNFileStyleVideo, @"test");
    player.frame = NSMakeRect(0, 0, 320, 200);
    [video.superview addSubview:player];
    [player togglePlayback];
    SNExpect(player.media != nil && player.media.player.rate > 0, "a click makes the player and plays");
    [player togglePlayback];
    SNExpect(player.media != nil && !player.media.playing, "a second click pauses");
    player.hidden = YES;
    SNExpect(player.media == nil, "hidden (a recycled row), the player is released");
    player.hidden = NO;
    [player togglePlayback];
    [player removeFromSuperview];
    SNExpect(player.media == nil, "removed, released too");
    SNSetFileCredentials(nil, nil);
}
