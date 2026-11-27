// Attached files, the drop overlay and the command list, against the official client's CSS (no
// capture of them exists): the geometry and colours of client-boot-styles' gallery, thumbnail,
// card, status circle and arrows checked on offscreen renders; pastes, drops, Slack's limits and
// sending files with text on the public fixture.
#import "../net/stub.h"
#import "app/launch.h"
#import "render/images.h"
#import "render/strings.h"
#import "snapshot.h"
#import "test.h"
#import "ui/composer/attachments.h"
#import "ui/composer/composer.h"
#import "ui/composer/pasteboard.h"
#import "ui/composer/textview.h"
#import "ui/kit/dialog.h"
#import "ui/kit/hoverview.h"
#import "ui/kit/overlay.h"
#import "ui/shell/shell.h"

// The drag double answers only what the composer asks of a drag.
#pragma clang diagnostic ignored "-Wprotocol"
#pragma clang diagnostic ignored "-Wobjc-protocol-property-synthesis"

@interface SNTestDrag : NSObject <NSDraggingInfo>
@property (nonatomic) NSPasteboard *draggingPasteboard;
@end

@implementation SNTestDrag
@end

static NSURL *Folder(void) {
    NSURL *folder = [NSFileManager.defaultManager.temporaryDirectory URLByAppendingPathComponent:@"slack-native-tests/attachments" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:nil];
    return folder;
}

static NSURL *LocalFile(NSString *name, NSString *contents) {
    NSURL *url = [Folder() URLByAppendingPathComponent:name];
    [contents writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return url;
}

static NSURL *PictureFile(void) {
    NSURL *url = [Folder() URLByAppendingPathComponent:@"chart.png"];
    [NSFileManager.defaultManager removeItemAtURL:url error:nil];
    [NSFileManager.defaultManager copyItemAtURL:[SNPublicFixture() URLByAppendingPathComponent:@"images/chart.png"] toURL:url error:nil];
    return url;
}

/// A composer at the bottom of an offscreen window filled like the conversation pane.
static SNComposer *ComposerIn(id<SNSource> source, NSSize size, NSString **channel) {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:(NSRect){NSZeroPoint, size} styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:YES];
    window.releasedWhenClosed = NO;
    NSView *host = [[NSView alloc] initWithFrame:(NSRect){NSZeroPoint, size}];
    host.wantsLayer = YES;
    host.layer.backgroundColor = SNCGColor(SNMeasuredMessagePaneBg);
    window.contentView = host;
    SNComposer *composer = [[SNComposer alloc] initWithSource:source];
    composer.frame = NSMakeRect(0, 0, size.width, 200);
    [host addSubview:composer];
    *channel = source.sections.firstObject.conversationIDs.firstObject;
    [composer showConversation:*channel threadTS:nil];
    return composer;
}

static SNComposerTextView *TextOf(NSView *view) {
    if ([view isKindOfClass:SNComposerTextView.class]) return (SNComposerTextView *)view;
    for (NSView *subview in view.subviews) {
        SNComposerTextView *found = TextOf(subview);
        if (found) return found;
    }
    return nil;
}

static void Fit(SNComposer *composer) {
    composer.frame = NSMakeRect(0, 0, composer.frame.size.width, composer.preferredHeight);
    [composer layoutSubtreeIfNeeded];
}

static NSArray<SNUpload *> *Attached(id<SNSource> source, NSString *channel) { return [source uploadsInConversation:channel threadTS:nil]; }

static BOOL Near(uint32_t color, uint32_t expected, int tolerance) {
    for (int shift = 8; shift < 32; shift += 8)
        if (abs((int)((color >> shift) & 0xff) - (int)((expected >> shift) & 0xff)) > tolerance) return NO;
    return YES;
}

/// `color` (0xRRGGBBAA) over an opaque `under`.
static uint32_t Over(uint32_t color, uint32_t under) {
    double alpha = (color & 0xff) / 255.0;
    uint32_t result = 0xff;
    for (int shift = 8; shift < 32; shift += 8)
        result |= (uint32_t)round(((color >> shift) & 0xff) * alpha + ((under >> shift) & 0xff) * (1 - alpha)) << shift;
    return result;
}

SN_SNAPSHOT(ComposerShowsAttachedFilesAsTheClientsCSS) {
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    NSString *channel;
    NSSize size = NSMakeSize(1100, 320);
    SNComposer *composer = ComposerIn(source, size, &channel);
    Fit(composer);
    CGFloat bare = composer.preferredHeight;
    [composer attachFiles:@[ PictureFile(), LocalFile(@"Quarterly report.pdf", @"%PDF-1.4 made up") ]];
    SNWaitUntil(3, ^BOOL { return Attached(source, channel).count == 2 && Attached(source, channel)[1].state == SNUploadReady; });
    source.failsRequests = YES;
    [composer attachFiles:@[ LocalFile(@"archive.zip", @"PK made up") ]];
    SNWaitUntil(3, ^BOOL { return Attached(source, channel).count == 3 && Attached(source, channel)[2].state == SNUploadFailed; });
    source.failsRequests = NO;
    source.latency = 60;
    [composer attachFiles:@[ LocalFile(@"notes.txt", @"made-up notes") ]];
    Fit(composer);
    SNExpect(composer.preferredHeight == bare + SNComposerAttachmentsHeight, "the files' row adds 78 pt to the box (8 + 62 + 8)");

    SNComposerAttachments *row = (SNComposerAttachments *)composer.attachmentsView;
    NSArray<NSView *> *items = row.itemViews;
    SNExpect(items.count == 4, "one item per file, in the order attached");
    SNHoverView *picture = (SNHoverView *)items[0];
    picture.hovered = YES;
    // Hovering a file that still uploads leaves its spinner: the x shows over the button only.
    ((SNHoverView *)items[3]).hovered = YES;
    // The thumbnail decodes off the main thread; the render waits for it here.
    [picture.imageHolder imageWithURL:Attached(source, channel)[0].fileURL pixels:124];
    SNWaitUntil(2, ^BOOL { return SNImageLoadsInFlight() == 0; });
    picture.needsDisplay = YES;
    SNPixels *pixels = SNRenderView(composer.superview, size);
    SNSaveSnapshot(@"composer_attachments", pixels);

    // In the render's points: the box is 20 pt in, the row under the text, the footer under it.
    NSRect box = [composer convertRect:composer.attachmentsView.superview.frame toView:nil];
    CGFloat boxLeft = NSMinX(box), boxBottom = size.height - NSMinY(box);
    CGFloat itemsTop = boxBottom - 1 - 40 - 8 - 62, first = boxLeft + 1 + 8;
    NSRect thumb = [items[0] convertRect:items[0].bounds toView:nil];
    SNExpect(fabs(NSMinX(thumb) - first) < 0.01 && fabs(size.height - NSMaxY(thumb) + 10 - itemsTop) < 0.01,
             "the first item 8 pt in from the box's inside and 8 pt over the 62 pt row's bottom padding and the 40 pt footer");
    NSRect card = [items[1] convertRect:items[1].bounds toView:nil];
    SNExpect(fabs(NSMinX(card) - (first + 62 + 12)) < 0.01 && fabs(NSWidth(card) - 10 - 234) < 0.01, "the card follows 12 pt later, 234 pt wide");

    uint32_t boxFill = [pixels colorAtPoint:NSMakePoint(NSMaxX(box) - 120, itemsTop + 31)];
    SNExpect(Near([pixels colorAtPoint:NSMakePoint(first + 0.5, itemsTop + 0.5)], boxFill, 6), "the thumbnail's 12 pt corner is cut");
    SNExpect(!Near([pixels colorAtPoint:NSMakePoint(first + 31, itemsTop + 31)], boxFill, 6), "the picture fills its thumbnail");
    CGFloat cardLeft = first + 62 + 12;
    SNExpect(Near([pixels colorAtPoint:NSMakePoint(cardLeft + 200, itemsTop + 31)], SNColorBasePry, 3), "the card is base-pry");
    SNExpect(Near([pixels colorAtPoint:NSMakePoint(cardLeft + 120, itemsTop + 0.25)], Over(SNColorOtlTer, SNColorBasePry), 14), "inside a 1 pt otl-ter border");
    SNExpect(!Near([pixels colorAtPoint:NSMakePoint(cardLeft + 13 + 18, itemsTop + 13 + 18)], SNColorBasePry, 20), "with the 36 pt type icon 13 pt in");

    // Status circles: 22 pt, 10 pt past the top-right corners.
    CGFloat hoveredX = first + 62 + 10 - 11, circleY = itemsTop - 10 + 11;
    SNExpect(Near([pixels colorAtPoint:NSMakePoint(hoveredX - 8, circleY)], SNColorBaseInvPry, 4), "the hovered file's remove x sits on a base-inv-pry disc");
    SNExpect(Near([pixels colorAtPoint:NSMakePoint(hoveredX, circleY - 10.6)], boxFill, 6), "on a clear 22 pt button (status_btn--remove), not a primary-background ring");
    CGFloat readyX = cardLeft + 234 + 10 - 11;
    SNExpect(Near([pixels colorAtPoint:NSMakePoint(readyX, circleY - 6)], boxFill, 6), "an uploaded file shows no circle until hovered");
    CGFloat uploadingX = cardLeft + 2 * (234 + 12) + 234 + 10 - 11;
    BOOL arc = NO;
    for (CGFloat angle = 0; angle < 2 * M_PI; angle += 0.1)
        arc = arc || Near([pixels colorAtPoint:NSMakePoint(uploadingX + 5.6 * cos(angle), circleY + 5.6 * sin(angle))], SNColorContentHgl1, 40);
    SNExpect(arc, "an uploading file's circle turns a content-hgl-1 spinner, hovered or not");
    SNExpect(row.rightArrow.hidden && row.leftArrow.hidden, "no arrows while the row fits");
    composer.frame = NSMakeRect(0, 0, 640, composer.frame.size.height);
    [composer layoutSubtreeIfNeeded];
    SNExpect(!row.rightArrow.hidden && row.leftArrow.hidden, "a row wider than the box offers the right arrow only");
}

SN_TEST(ComposerTakesPastesAndDropsAsBrowsersHandThem) {
    NSPasteboard *pasteboard = [NSPasteboard pasteboardWithUniqueName];
    [pasteboard clearContents];
    [pasteboard setData:[NSData dataWithContentsOfURL:[SNPublicFixture() URLByAppendingPathComponent:@"images/chart.png"]] forType:NSPasteboardTypePNG];
    NSArray<NSURL *> *files = SNComposerFilesFromPasteboard(pasteboard);
    SNExpect(files.count == 1 && [files[0].lastPathComponent isEqualToString:@"image.png"] && [NSData dataWithContentsOfURL:files[0]].length > 0,
             "a screenshot pastes as image.png");
    [pasteboard clearContents];
    [pasteboard writeObjects:@[ @"cells as text" ]];
    [pasteboard setData:[NSData dataWithContentsOfURL:[SNPublicFixture() URLByAppendingPathComponent:@"images/chart.png"]] forType:NSPasteboardTypePNG];
    SNExpect(SNComposerFilesFromPasteboard(pasteboard).count == 0, "text with a picture of it pastes as text");
    NSURL *notes = LocalFile(@"notes.txt", @"made-up notes");
    [pasteboard clearContents];
    [pasteboard writeObjects:@[ notes ]];
    SNExpect([SNComposerFilesFromPasteboard(pasteboard) isEqualToArray:@[ notes ]], "a Finder copy pastes its files");

    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    NSString *channel;
    SNComposer *composer = ComposerIn(source, NSMakeSize(848, 320), &channel);
    SNTestDrag *drag = [SNTestDrag new];
    drag.draggingPasteboard = pasteboard;
    NSView *pane = composer.superview;
    SNExpect([composer dragEntered:drag overView:pane] == NSDragOperationCopy && pane.subviews.lastObject != composer, "files over the column show the overlay");
    SNExpect([composer performDrag:drag] && pane.subviews.lastObject == composer && Attached(source, channel).count == 1, "a drop attaches them and takes the overlay away");
    [pasteboard clearContents];
    [pasteboard writeObjects:@[ @"words" ]];
    SNExpect([composer dragEntered:drag overView:pane] == NSDragOperationNone, "a drag of text is not a drop of files");
    [pasteboard releaseGlobally];
}

SN_SNAPSHOT(ComposerShowsTheDropOverlay) {
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    NSString *channel;
    SNComposer *composer = ComposerIn(source, NSMakeSize(848, 600), &channel);
    NSPasteboard *pasteboard = [NSPasteboard pasteboardWithUniqueName];
    [pasteboard clearContents];
    [pasteboard writeObjects:@[ LocalFile(@"notes.txt", @"made-up notes") ]];
    SNTestDrag *drag = [SNTestDrag new];
    drag.draggingPasteboard = pasteboard;
    NSView *pane = composer.superview;
    [composer dragEntered:drag overView:pane];
    [pane.subviews.lastObject.layer removeAllAnimations];
    SNPixels *pixels = SNRenderView(pane, pane.bounds.size);
    SNSaveSnapshot(@"composer_drop_overlay", pixels);
    SNExpect(Near([pixels colorAtPoint:NSMakePoint(40, 40)], Over(SNColorWithAlpha(SNLegacyPrimaryBackground, 0.95), SNMeasuredMessagePaneBg), 2),
             "the pane's background at 95% over the column");
    BOOL title = NO;
    for (CGFloat x = 300; x < 548; x += 2) title = title || Near([pixels colorAtPoint:NSMakePoint(x, 300 - 32.75 + 17.5)], SNColorContentPry, 60);
    SNExpect(title, "the 28 pt title centred");
    [composer dragExited];
    [composer showConversation:channel threadTS:@"1795400000.000100"];
    [composer dragEntered:drag overView:pane];
    SNSaveSnapshot(@"composer_drop_overlay_thread", SNRenderView(pane, pane.bounds.size));
    [composer dragExited];
    [pasteboard releaseGlobally];
}

SN_TEST(ComposerKeepsToSlacksFileLimits) {
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    source.latency = 60;
    NSString *channel;
    SNComposer *composer = ComposerIn(source, NSMakeSize(848, 320), &channel);
    NSMutableArray<NSURL *> *many = [NSMutableArray new];
    for (int i = 0; i < 12; i++) [many addObject:LocalFile([NSString stringWithFormat:@"file-%d.txt", i], @"made up")];
    [composer attachFiles:many];
    SNExpect(Attached(source, channel).count == 10 && composer.notice.length, "10 files at most, and a notice says so");
    [composer attachFiles:@[ LocalFile(@"one-more.txt", @"made up") ]];
    SNExpect(Attached(source, channel).count == 10, "even one more");
    for (SNUpload *upload in Attached(source, channel)) [source removeUpload:upload];
    [composer attachFiles:@[ LocalFile(@"empty.txt", @""), Folder() ]];
    SNExpect(Attached(source, channel).count == 0 && SNConfirmDialog.current, "empty files and folders are refused with Slack's dialog");
    [SNConfirmDialog.current cancel];
}

SN_TEST(ComposerSendsFilesWithTheText) {
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    NSString *channel;
    SNComposer *composer = ComposerIn(source, NSMakeSize(848, 320), &channel);
    [composer attachFiles:@[ LocalFile(@"notes.txt", @"made-up notes") ]];
    SNWaitUntil(3, ^BOOL { return Attached(source, channel).firstObject.state == SNUploadReady; });
    composer.text = @"the notes";
    [composer focus];
    [TextOf(composer) insertNewline:nil];
    SNExpect(Attached(source, channel).count == 0 && composer.text.length == 0, "Return sends the text and the files together");
    SNWaitUntil(3, ^BOOL { return [source messagesInConversation:channel].lastObject.sendState == SNMessageSent; });
    SNMessage *sent = [source messagesInConversation:channel].lastObject;
    SNExpect([sent.text isEqualToString:@"the notes"] && sent.files.count == 1 && [sent.files[0].fileID hasPrefix:@"F0FIX"], "one message with both, confirmed as Slack's");
    [composer attachFiles:@[ PictureFile() ]];
    SNWaitUntil(3, ^BOOL { return Attached(source, channel).firstObject.state == SNUploadReady; });
    [composer focus];
    [TextOf(composer) insertNewline:nil];
    SNExpect([source messagesInConversation:channel].lastObject.files.count == 1 && Attached(source, channel).count == 0, "files alone are a message too");
}

SN_SNAPSHOT(ComposerListsSlashCommands) {
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    NSString *channel;
    SNComposer *composer = ComposerIn(source, NSMakeSize(900, 520), &channel);
    Fit(composer);
    [composer focus];
    SNComposerTextView *text = TextOf(composer);
    [text insertText:@"/" replacementRange:text.selectedRange];
    // The client's own commands list at once; client.appCommands' arrive on the next turn.
    SNWaitUntil(2, ^BOOL { return [SNOverlayHost hostForWindow:composer.window].subviews.count == 1 && [source commandNamed:@"/remind"]; });
    NSView *panel = [SNOverlayHost hostForWindow:composer.window].subviews.firstObject;
    SNExpect(panel && NSWidth(panel.frame) == 575 && NSHeight(panel.frame) == 262, "the list: 575 pt wide at most, 262 pt tall at most, scrolled");
    SNPixels *pixels = SNRenderWindow(composer.window);
    SNSaveSnapshot(@"composer_autocomplete_commands", pixels);
    NSRect frame = [panel convertRect:panel.bounds toView:nil];
    CGFloat top = 520 - NSMaxY(frame);
    SNExpect(Near([pixels colorAtPoint:NSMakePoint(NSMinX(frame) + 300, top + 8 + 30)], SNColorBaseInvHgl1, 4) &&
                 !Near([pixels colorAtPoint:NSMakePoint(NSMinX(frame) + 300, top + 8 + 60 + 30)], SNColorBaseInvHgl1, 4),
             "60 pt rows, the first on the highlight");
    [text insertText:@"rem" replacementRange:text.selectedRange];
    [text insertTab:nil];
    SNExpect([text.string isEqualToString:@"/remind "] && [SNOverlayHost hostForWindow:composer.window].subviews.count == 0,
             "Tab puts the command in with a space, and the list goes");
}

SN_SNAPSHOT(ChannelShowsMessagesOnlyTheUserSees) {
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    SNShell *shell = [[SNShell alloc] initWithSource:source defaults:nil];
    NSString *channel = source.sections.firstObject.conversationIDs.firstObject;
    [shell go:[SNLocation locationWithTab:SNTabHome conversation:channel thread:nil]];
    [source showCommandFeedback:SNLocalized(@"composer.command.collapse.done") inConversation:channel threadTS:nil temporary:YES];
    SNPixels *pixels = SNRenderWindow(shell.window);
    SNSaveSnapshot(@"channel_ephemeral", pixels);
    SNExpect([source messagesInConversation:channel].lastObject.isEphemeral, "the answer is in the conversation");
}
