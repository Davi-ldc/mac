// The Home sidebar's list entries and the one view that draws any of them
// (components.json sidebar_channel_row, sidebar_section_heading, sidebar_badge).
#import <AppKit/AppKit.h>

#import "source/source.h"
#import "ui/kit/avatar.h"
#import "ui/kit/hoverview.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SNSidebarItemKind) {
    /// Conversas, Círculos, Rascunhos e enviados, Diretórios.
    SNSidebarItemPage,
    SNSidebarItemDivider,
    SNSidebarItemHeading,
    /// What an empty Favoritos section says.
    SNSidebarItemHint,
    SNSidebarItemConversation,
    /// "Adicionar canais" at the end of the channels section.
    SNSidebarItemAdd,
    /// Space between sections.
    SNSidebarItemGap,
    /// What the filter shows when nothing matches: the text and a button that searches instead.
    SNSidebarItemNoResults,
};

typedef NS_ENUM(NSInteger, SNSidebarPage) {
    SNSidebarPageThreads,
    SNSidebarPageHuddles,
    SNSidebarPageDrafts,
    SNSidebarPageDirectories,
};

@interface SNSidebarItem : NSObject
@property (nonatomic) SNSidebarItemKind kind;
/// Unique in the list and stable across rebuilds: rows are reused and hover is kept by it.
@property (nonatomic, copy) NSString *key;
@property (nonatomic) CGFloat height;
@property (nonatomic) SNSidebarPage page;
@property (nonatomic, nullable) SNSection *section;
/// A heading's conversations, the ones a collapsed section hides included.
@property (nonatomic, copy, nullable) NSArray<NSString *> *sectionConversationIDs;
@property (nonatomic, copy, nullable) NSString *conversationID;
/// Listed by the filter: a heading shows its section open whatever the section's state.
@property (nonatomic) BOOL filtered;
@end

/// What a row shows, looked up from the source when the row is configured.
@interface SNSidebarRowState : NSObject
@property (nonatomic, copy) NSString *title;
/// Slack icon of the 16 pt icon slot (nil for an avatar), drawn in an `iconSize` box (16 by default).
@property (nonatomic, copy, nullable) NSString *icon;
@property (nonatomic) CGFloat iconSize;
/// The DM's person: avatar with presence and status emoji.
@property (nonatomic, nullable) SNUser *user;
@property (nonatomic) SNAvatarPresence presence;
@property (nonatomic) BOOL doNotDisturb;
/// Members of a group DM besides the user (drawn as a count).
@property (nonatomic) NSInteger memberCount;
@property (nonatomic) BOOL selected, unread, muted, draft, collapsed;
@property (nonatomic) NSInteger mentions;
/// A huddle going on in the conversation: how many are in it and the first faces of the
/// facepile; `myHuddle` when the user is in it from here.
@property (nonatomic) NSInteger huddleCount;
@property (nonatomic, copy, nullable) NSArray<SNUser *> *huddleFaces;
@property (nonatomic) BOOL myHuddle;
/// The DM's person is in a huddle: the headphones take their status emoji's place.
@property (nonatomic) BOOL userInHuddle;
/// The no-results entry's button.
@property (nonatomic, copy, nullable) NSString *buttonTitle;
@end

@class SNSidebarRowView;

@protocol SNSidebarRowDelegate <NSObject>
- (void)sidebarRowClicked:(SNSidebarRowView *)row;
/// A hover action: the DM row's close, the heading's add, filter and menu buttons; "search" from
/// the no-results entry's button.
- (void)sidebarRow:(SNSidebarRowView *)row action:(NSString *)action fromView:(NSView *)view;
@end

/// Draws its item in -drawRect: (icon, text, badge), with an avatar subview for DMs and hover
/// action buttons that show only while hovered, so hovering never lays the list out.
@interface SNSidebarRowView : SNHoverView
@property (nonatomic, weak, nullable) id<SNSidebarRowDelegate> delegate;
@property (nonatomic, readonly, nullable) SNSidebarItem *item;
@property (nonatomic, readonly, nullable) SNSidebarRowState *state;
- (void)showItem:(SNSidebarItem *)item state:(SNSidebarRowState *)state;
/// The heading's caret turns with the 100 ms ease of the CSS when the section collapses.
- (void)setCollapsed:(BOOL)collapsed animated:(BOOL)animated;
/// The hover action buttons by name ("close", "add", "filter", "menu"), and the no-results
/// entry's "search", for tests.
- (nullable SNHoverView *)actionButton:(NSString *)action;
/// What a click on the row's main target does (Return or Space on it): the no-results entry's
/// button, else the row's own action.
- (void)performPrimaryAction;
@end

NS_ASSUME_NONNULL_END
