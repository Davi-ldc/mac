// The message list (components.json message_pane, date_divider, new_messages_divider): a
// virtualized, bottom-anchored list of variable-height rows. Only the rows in view exist; each
// message's layout is cached by its identifier (dropped when the source names it changed) and
// width, so scrolling only moves and reuses views. It groups messages by sender, puts a date
// divider before each day (its pill pins to the top while that day scrolls by), marks the first
// unread message with the red "Novo" line, asks for older history when the reader scrolls to
// the top and shows a jump-to-latest button when far from the bottom. One tracking area hovers
// the rows; the action bar follows the hovered row. It also marks what it shows as read, the
// one place that does (see -showMessages:...).
#import <AppKit/AppKit.h>

#import "source/source.h"
#import "render/document.h"
#import "ui/channel/actionbar.h"
#import "ui/channel/editor.h"
#import "ui/channel/row.h"
#import "ui/kit/popover.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SNMessageListMode) {
    /// A conversation's history with date dividers and reply bars.
    SNMessageListChannel,
    /// A thread: the parent, the replies count line, then the replies.
    SNMessageListThread,
};

@class SNMessageListView;

@protocol SNMessageListDelegate <NSObject>
- (void)messageList:(SNMessageListView *)list openThreadOfMessage:(SNMessage *)message;
/// A click on a link, mention, channel, button or picture in a message.
- (void)messageList:(SNMessageListView *)list activateTarget:(SNRenderTarget *)target inMessage:(SNMessage *)message;
/// The inline editor closed; the keyboard goes back to the composer.
- (void)messageListDidFinishEditing:(SNMessageListView *)list;
@end

@interface SNMessageListView : NSView
- (instancetype)initWithSource:(id<SNSource>)source mode:(SNMessageListMode)mode;
@property (nonatomic, weak, nullable) id<SNMessageListDelegate> delegate;
@property (nonatomic, readonly) id<SNSource> source;
/// Shows `messages` (oldest first) of a conversation, or of its thread `threadTS` (the parent
/// first), keeping the reader's place: at the bottom it stays at the bottom, otherwise the
/// message at the top stays where it is. A new conversation starts at the bottom, a new thread
/// at the top; nil shows nothing. `lastRead` puts the "Novo" line above the first later message.
///
/// What is shown is marked read (markConversation:readThrough: or markThread:...) through the
/// newest message Slack has (never a pending or failed send's local ts) while its reader can see
/// it: the list is in a visible column of the key window, the window is on screen and the list
/// is at its bottom; again as newer messages arrive while that holds. After "Mark unread" (in
/// either column) the conversation is not marked again until a list shows it anew.
- (void)showMessages:(NSArray<SNMessage *> *)messages
      inConversation:(nullable NSString *)conversationID
            threadTS:(nullable NSString *)threadTS
            lastRead:(nullable NSString *)lastRead;
@property (nonatomic, readonly, nullable) NSString *conversationID, *threadTS;
/// Drops the cached layouts that `change` made stale, in every conversation: the messages its
/// messageKeys name, the huddle messages of conversations in its huddles, and all of them when a
/// name or custom emoji they show changed. YES when the rows shown here need laying out again, by
/// showing the messages again; changed messages come with their own messages or threads.
- (BOOL)applyChange:(SNChange *)change;
/// Shows a change to the conversation's messages where the rows stand: the rows of the messages
/// its messageKeys name are made again from the source
/// (messageWithIdentifier:inConversation:), inserted or taken out, day dividers and grouping
/// settled around them; only those are laid out again and the rows below move. NO when the
/// change is not of that kind (a page, the spinner, a thread's list): show the messages again.
- (BOOL)showChangedMessages:(SNChange *)change;
/// The message whose thread is open, tinted.
@property (nonatomic, copy, nullable) NSString *highlightedTS;
/// Transient highlight applied when jumping to a searched message (nil once faded).
@property (nonatomic, readonly, nullable) NSString *jumpHighlightedTS;
/// Scrolls to `ts` (immediately if loaded, or once it arrives) and transiently highlights it.
- (void)jumpToMessageTS:(NSString *)ts;
/// Updates the "New" / "Novo" divider position immediately without reloading the list.
- (void)updateLastRead:(nullable NSString *)lastRead;
/// YES while `key` (conversation ID or thread key) was marked unread and holds off auto-read.
+ (BOOL)isReadHeldForKey:(NSString *)key;
/// Space under the last message, above the composer.
@property (nonatomic) CGFloat bottomInset;
- (void)scrollToBottom;
@property (nonatomic, readonly) BOOL atBottom;
/// The clock dates are worded against ("Hoje", "há 2 dias"); now by default.
@property (nonatomic, null_resettable) NSDate *now;

/// For tests, snapshots and the bench.
@property (nonatomic, readonly) NSScrollView *scrollView;
@property (nonatomic, readonly) SNMessageActionBar *actionBar;
/// The row in view of the message with this ts.
- (nullable SNMessageRowView *)rowForTS:(NSString *)ts;
/// Hovers the row of the message with this ts as the pointer would (nil: none), action bar
/// included.
- (void)hoverMessageTS:(nullable NSString *)ts;
@property (nonatomic, readonly) NSUInteger visibleRowCount;
/// Scrolls so `offset` points of content lie above the view's top.
- (void)scrollToOffset:(CGFloat)offset;
@property (nonatomic, readonly) CGFloat contentHeight;
/// The more-actions menu of a message.
- (NSArray<SNMenuItem *> *)menuItemsForMessage:(SNMessage *)message;
/// Drops the cached layouts (the bench's cold start).
- (void)clearCache;
/// Conversations and threads whose layouts are cached, the shown one first.
@property (nonatomic, readonly) NSArray<NSString *> *cachedLayoutKeys;
@property (nonatomic, readonly) NSUInteger cachedLayoutCount;

/// Replaces the user's message's row with the inline editor and scrolls to it (the more menu's
/// "Editar mensagem", Up in an empty composer); one message at a time.
- (void)editMessage:(SNMessage *)message;
@property (nonatomic, readonly, nullable) SNMessageEditor *editor;
/// The delete confirmation with the message in it; deletes when confirmed.
- (void)confirmDeleteOfMessage:(SNMessage *)message;
@end

NS_ASSUME_NONNULL_END
