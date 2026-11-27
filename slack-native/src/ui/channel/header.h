// The conversation's header (components.json channel_header, channel_tab_bar; effects.txt [B7]
// [B8] [L9], measured live): a 49 pt row with the star, the title (a DM's 24 pt avatar or the
// channel's glyph, then the name in 18 pt black) and the icon buttons; under it the 38 pt tab bar
// (Mensagens, Adicionar canvas, Arquivos e links, +) with the selected tab's 2 pt #e3ceeb
// underline and the #35373b line. Every hover is instant: bell and search only brighten, the
// members, huddle and kebab buttons get their measured fills. Hovering "Arquivos e links" while
// another tab is chosen opens its peek after 320 ms (ui/files/peek.h).
#import <AppKit/AppKit.h>

#import "source/source.h"
#import "ui/files/attachments.h"
#import "ui/huddle/headercontrol.h"
#import "ui/kit/button.h"

NS_ASSUME_NONNULL_BEGIN

static const CGFloat SNChannelHeaderHeight = 87;

@interface SNChannelHeader : NSView
- (instancetype)initWithSource:(id<SNSource>)source;
/// `closable` adds the close button (a conversation opened from the DMs tab).
- (void)showConversation:(SNConversation *)conversation closable:(BOOL)closable;
@property (nonatomic, readonly, nullable) SNConversation *conversation;
@property (nonatomic, readonly) SNButton *star, *members, *bell, *search, *more, *close;
/// The huddle button and its options caret; jade while a huddle goes on there.
@property (nonatomic, readonly) SNHuddleHeaderControl *huddle;
/// Mensagens, Adicionar canvas, Arquivos e links, +.
@property (nonatomic, readonly) NSArray<SNHoverView *> *tabs;
@property (nonatomic, copy, nullable) void (^closeAction)(void);
/// Takes no room (a page such as the channel browser fills the column instead).
@property (nonatomic) BOOL collapsed;
/// The tab shown: 0 for Mensagens, 2 for Arquivos e links.
@property (nonatomic) NSUInteger selectedTab;
/// A click on Mensagens (0) or Arquivos e links (2).
@property (nonatomic, copy, nullable) void (^tabChosen)(NSUInteger index);
/// The conversation's files and links, which the peek lists.
@property (nonatomic, copy, nullable) SNConversationAttachments *_Nullable (^attachments)(void);
/// Opens the files peek now (tests and snapshots skip the hover delay), and closes it.
- (void)showFilesPreview;
- (void)closeFilesPreview;
@end

NS_ASSUME_NONNULL_END
