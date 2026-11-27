// The message composer (components.json message_composer, effects.txt [composer-*]): a rounded
// box with the formatting toolbar, the text and the footer buttons (+, Aa, emoji, mention, send).
// It grows with its text up to a maximum and scrolls after that; Return sends, Shift+Return
// starts a new line. Typed markdown (*bold*, _italic_, ~strike~, `code`, links, lists, quotes)
// is sent as rich_text with its mrkdwn fallback; a message starting with "/" runs as a slash
// command (the list of commands opens on the "/"; ui/composer/commands.h). Files attach from "+" > Upload from your
// computer (⌘O), a paste or a drop, upload at once and show in a row under the text until they
// are sent with the message. Drafts are kept per conversation and thread.
#import <AppKit/AppKit.h>

#import "source/source.h"
#import "ui/shell/pane.h"

NS_ASSUME_NONNULL_BEGIN

/// The composer's box, which the inline message editor draws too: the text 13 pt in from the
/// sides, 9.75 pt under the top when no formatting bar is shown and 8.25 pt above the 40 pt
/// footer.
static const CGFloat SNComposerTextInset = 13, SNComposerTextTop = 9.75, SNComposerTextBottom = 8.25, SNComposerFooterHeight = 40;
/// The box's 1 pt border (brighter while focused) and fill, in `box` of a flipped view.
void SNDrawComposerBox(NSRect box, BOOL focused);

@interface SNComposer : NSView
- (instancetype)initWithSource:(id<SNSource>)source;
/// The conversation the composer writes to, with an optional thread; changing it saves the draft
/// of the previous one and restores this one's, and updates the placeholder.
- (void)showConversation:(nullable NSString *)conversationID threadTS:(nullable NSString *)threadTS;
@property (nonatomic, readonly, nullable) NSString *conversationID, *threadTS;
/// The height the composer wants at its current width: it grows with the text up to a maximum.
@property (nonatomic, readonly) CGFloat preferredHeight;
/// Called after preferredHeight changed; the owner resizes the composer.
@property (nonatomic, copy, nullable) void (^heightDidChange)(SNComposer *composer);
/// Where slash commands go (/msg opens the DM, /search the search).
@property (nonatomic, weak, nullable) id<SNNavigator> navigator;
/// Up arrow in an empty composer: the owner starts editing the user's last message.
@property (nonatomic, copy, nullable) void (^editLastMessage)(SNComposer *composer);
/// Makes the text the window's first responder.
- (void)focus;
@property (nonatomic, readonly, getter=isFocused) BOOL focused;
/// The text as typed, for tests and the owner's checks.
@property (nonatomic, copy) NSString *text;
/// The line under the box: who is typing here, or that Slack is trying to connect; empty when
/// neither.
@property (nonatomic, readonly) NSString *noticeText;
/// The notice over the box (too many files at once), nil when none shows.
@property (nonatomic, readonly, nullable) NSString *notice;
/// Attaches files to the conversation or thread shown; folders, empty files and files over 1 GB
/// are refused with Slack's dialogs, and only 10 files go with a message.
- (void)attachFiles:(NSArray<NSURL *> *)files;
/// The open panel ("+" > Upload from your computer, ⌘O).
- (void)chooseFiles;
/// Files dragged over the column the composer writes to (its pane's view forwards its
/// NSDraggingDestination calls here): Slack's overlay covers `view` while they are over it, and
/// a drop attaches them, or sends them at once with Shift held.
- (NSDragOperation)dragEntered:(id<NSDraggingInfo>)drag overView:(NSView *)view;
- (void)dragExited;
- (BOOL)performDrag:(id<NSDraggingInfo>)drag;
/// The files' row, for tests and snapshots.
@property (nonatomic, readonly) NSView *attachmentsView;
@end

NS_ASSUME_NONNULL_END
