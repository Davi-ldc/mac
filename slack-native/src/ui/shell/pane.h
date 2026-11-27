// How the window's columns are filled. The shell owns the window, its chrome and navigation;
// each column inside the content card is a pane: a class that implements SNPane and registers
// itself for its slot from +load, so the shell never names it:
//
//   @implementation SNSidebarPane
//   + (void)load { SNRegisterPane(SNPaneSlotSidebar, self); }
//   - (instancetype)initWithSource:(id<SNSource>)source navigator:(id<SNNavigator>)navigator { ... }
//   - (NSView *)view { ... }
//   @end
//
// Panes draw on a clear background: the shell paints each column's surface (the sidebar's
// translucent fill over the window gradient, the conversation's #1a1d21).
#import <AppKit/AppKit.h>

#import "source/source.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SNPaneSlot) {
    /// The resizable list column at the left of the content card.
    SNPaneSlotSidebar,
    /// The conversation: header, messages, composer.
    SNPaneSlotPrimary,
    /// The thread column at the right, present while a thread is open.
    SNPaneSlotSecondary,
};

/// The rail's tabs, each a different list in the sidebar.
typedef NS_ENUM(NSInteger, SNTab) {
    SNTabHome,
    SNTabDirectMessages,
    SNTabActivity,
    SNTabFiles,
    SNTabAgents,
};

/// What the conversation column shows instead of a conversation: the channel browser (/open),
/// and the Files tab's pages (its files browser on all files, canvases or lists).
extern NSString *const SNPageChannels, *const SNPageFiles, *const SNPageFilesCanvases, *const SNPageFilesLists;
/// With a conversation: its "Files and links" tab in place of its messages.
extern NSString *const SNPageConversationFiles;
/// What the right column shows instead of a thread (Slack's flexpanes): the keyboard shortcuts
/// (/shortcuts) and the feedback form (/feedback).
extern NSString *const SNPanelShortcuts, *const SNPanelFeedback;
/// What /feedback was given: the feedback panel starts with it the next time it opens, once.
void SNSetFeedbackStartText(NSString *_Nullable text);
NSString *_Nullable SNTakeFeedbackStartText(void);
/// The panel of someone's full profile ("profile:<user ID>"), and whose profile a panel is (nil for
/// other panels).
NSString *SNPanelProfile(NSString *userID);
NSString *_Nullable SNPanelProfileUserID(NSString *_Nullable panel);

/// Where the window is: a rail tab, the conversation (or page) shown and the thread (or panel)
/// open beside it.
@interface SNLocation : NSObject <NSCopying>
+ (instancetype)locationWithTab:(SNTab)tab conversation:(nullable NSString *)conversationID thread:(nullable NSString *)threadTS;
+ (instancetype)locationWithTab:(SNTab)tab
                   conversation:(nullable NSString *)conversationID
                         thread:(nullable NSString *)threadTS
                           page:(nullable NSString *)page
                          panel:(nullable NSString *)panel;
@property (nonatomic, readonly) SNTab tab;
@property (nonatomic, readonly, nullable) NSString *conversationID;
@property (nonatomic, readonly, nullable) NSString *threadTS;
/// Set without a conversation (or SNPageConversationFiles with one); the panel without a thread.
@property (nonatomic, readonly, nullable) NSString *page, *panel;
/// Optional target message ts to scroll to and transiently highlight (from search).
@property (nonatomic, readonly, nullable) NSString *messageTS;
/// The same place with `panel` open in the right column (nil closes it), a thread there closed.
- (SNLocation *)locationWithPanel:(nullable NSString *)panel;
/// The same place targeting `messageTS` (in the conversation, or in `threadTS` when set).
- (SNLocation *)locationWithMessage:(nullable NSString *)messageTS;
@end

/// Moves the window somewhere; each move is a step of the top bar's back/forward history.
@protocol SNNavigator <NSObject>
@property (nonatomic, readonly) SNLocation *location;
/// Any move, such as closing the conversation (a location without one: the DMs tab's header X).
- (void)go:(SNLocation *)location;
- (void)openConversation:(NSString *)conversationID;
- (void)openThread:(NSString *)threadTS inConversation:(NSString *)conversationID;
- (void)closeThread;
- (void)selectTab:(SNTab)tab;
/// The search modal with `query` searched at once (the /search command); nil puts the last query
/// searched back in the field with its suggestions.
- (void)openSearchWithQuery:(nullable NSString *)query;
/// Empties the Home sidebar's filter, as Slack does for what the search modal opens and for Home
/// chosen again.
- (void)resetSidebarFilter;
@end

@protocol SNPane <NSObject>
- (instancetype)initWithSource:(id<SNSource>)source navigator:(id<SNNavigator>)navigator;
/// Created once; the shell sizes it to fill the column.
@property (nonatomic, readonly) NSView *view;
@optional
/// After every navigation, and once before the window first shows.
- (void)showLocation:(SNLocation *)location;
/// The narrowest the column may be resized to.
@property (nonatomic, readonly) CGFloat minimumWidth;
/// After a move that shows this column's conversation or thread: the keyboard goes where typing
/// goes (the composer). The shell asks the thread column when a thread is open, else the
/// conversation's.
- (void)focusForTyping;
/// Empties the pane's filter (the Home sidebar's): the navigator's resetSidebarFilter.
- (void)resetFilters;
@end

/// Registers the class filling `slot`; the last registration of a slot wins and Nil clears it.
void SNRegisterPane(SNPaneSlot slot, Class<SNPane> _Nullable paneClass);
Class<SNPane> _Nullable SNRegisteredPane(SNPaneSlot slot);

NS_ASSUME_NONNULL_END
