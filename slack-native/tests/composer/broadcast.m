// The thread composer's "Also send to #channel": shown only in threads, named after the
// conversation, sending the next reply with reply_broadcast and unchecking after it.
#import "app/launch.h"
#import "render/strings.h"
#import "snapshot.h"
#import "test.h"
#import "ui/composer/broadcast.h"
#import "ui/composer/composer.h"
#import "ui/composer/textview.h"

static id FirstSubview(NSView *view, Class kind) {
    for (NSView *subview in view.subviews) {
        if ([subview isKindOfClass:kind]) return subview;
        id found = FirstSubview(subview, kind);
        if (found) return found;
    }
    return nil;
}

static NSDictionary *LastPost(SNFixtureSource *source) {
    for (NSArray *call in source.calls.reverseObjectEnumerator)
        if ([call[0] isEqualToString:@"chat.postMessage"]) return call[1];
    return nil;
}

SN_TEST(ComposerAlsoSendsThreadRepliesToTheChannel) {
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 400, 400) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:YES];
    window.releasedWhenClosed = NO;
    SNComposer *composer = [[SNComposer alloc] initWithSource:source];
    composer.frame = NSMakeRect(0, 0, 393, 200);
    window.contentView = composer;
    SNComposerTextView *text = FirstSubview(composer, SNComposerTextView.class);

    [composer showConversation:@"C01GENERAL" threadTS:nil];
    CGFloat channelHeight = composer.preferredHeight;
    SNComposerBroadcastToggle *toggle = FirstSubview(composer, SNComposerBroadcastToggle.class);
    SNExpect(!toggle || toggle.hidden, "no checkbox under a conversation's composer");
    [composer showConversation:@"C01GENERAL" threadTS:@"1795192800.000103"];
    toggle = FirstSubview(composer, SNComposerBroadcastToggle.class);
    SNExpect(toggle && !toggle.hidden && [toggle.label isEqualToString:SNLocalizedFormat(@"composer.alsosend.channel", @"#general")], "a thread's names its channel");
    SNExpect(composer.preferredHeight > channelHeight, "and makes room for it");
    [composer showConversation:@"D05SAM" threadTS:@"1795192800.000200"];
    SNExpect([toggle.label isEqualToString:SNLocalized(@"composer.alsosend.dm")], "a DM's says direct message");
    [composer showConversation:@"C01GENERAL" threadTS:@"1795192800.000103"];

    [composer focus];
    [text insertText:@"shipping it" replacementRange:text.selectedRange];
    toggle.action(toggle);
    SNExpect(toggle.checked, "a click checks it");
    [text insertNewline:nil];
    NSDictionary *post = LastPost(source);
    SNExpect([post[@"thread_ts"] isEqualToString:@"1795192800.000103"] && [post[@"reply_broadcast"] isEqualToString:@"true"], "the reply is also sent to the channel");
    SNExpect(!toggle.checked, "sending unchecks it");
    [text insertText:@"only here" replacementRange:text.selectedRange];
    [text insertNewline:nil];
    post = LastPost(source);
    SNExpect([post[@"text"] isEqualToString:@"only here"] && !post[@"reply_broadcast"], "the next reply stays in the thread");
}

SN_SNAPSHOT(ComposerThreadAlsoSend) {
    SNFixtureSource *source = SNOpenFixture(SNPublicFixture());
    NSView *host = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 393, 200)];
    host.wantsLayer = YES;
    host.layer.backgroundColor = SNCGColor(SNMeasuredMessagePaneBg);
    SNComposer *composer = [[SNComposer alloc] initWithSource:source];
    [composer showConversation:@"C01GENERAL" threadTS:@"1795192800.000103"];
    composer.frame = NSMakeRect(0, 0, 393, composer.preferredHeight);
    [host addSubview:composer];
    SNComposerBroadcastToggle *toggle = FirstSubview(composer, SNComposerBroadcastToggle.class);
    SNSaveSnapshot(@"composer_thread_also_send", SNRenderView(host, NSMakeSize(393, composer.preferredHeight)));
    toggle.checked = YES;
    SNSaveSnapshot(@"composer_thread_also_send_checked", SNRenderView(host, NSMakeSize(393, composer.preferredHeight)));
}
