// The rows the Files tab and a conversation's "Files and links" list (client-boot-styles:
// c-pillow_file in .p-explorer_result--list, the sk entity of LinkEntity, SearchFileSkeleton):
// a file's 36 pt type icon or picture, its name in 15 pt bold and a 13 pt line about who shared
// or made it and when; a link's site icon on a 36 pt tile, its title and address. On hover a
// file shows its actions group at the top right (and, in a conversation, what a click does in
// place of its line), a link its details and more buttons and "Open in browser".
#import <AppKit/AppKit.h>

#import "source/source.h"
#import "ui/kit/button.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SNFileRowStyle) {
    /// The tab's peek (files_tab_view__preview): no frame, a line under every row but the last.
    SNFileRowPeek,
    /// An explorer list: one framed group whose outer corners are rounded.
    SNFileRowList,
};

typedef NS_ENUM(NSInteger, SNFileRowDetail) {
    /// "Shared by Ana on 19 nov" (owner-timestamp, a conversation's files).
    SNFileRowDetailShared,
    /// "Created by Ana · Last viewed today" (the Files tab sorted by recently viewed).
    SNFileRowDetailViewed,
    /// "Created by Ana · Updated 2 days ago" (the Files tab sorted by update or relevance).
    SNFileRowDetailUpdated,
};

/// A file row's height: the peek's 60 pt plus its line, a list's 61 (its top border) plus the
/// last row's bottom border.
CGFloat SNFileRowHeight(SNFileRowStyle style, BOOL last);
/// A link row's: the entity's 62 pt plus the same lines.
CGFloat SNLinkRowHeight(SNFileRowStyle style, BOOL last);

/// What a click on a file does in Slack's lists, here: Slack's own files the viewer does not show
/// download, the rest open in the browser; either way it joins the recently viewed files.
void SNOpenFile(SNFile *file, id<SNSource> source);
/// The row's second line for `detail` at `now`.
NSString *SNFileRowDescription(SNFile *file, SNFileRowDetail detail, id<SNSource> source, NSDate *now);

@interface SNFileRow : SNHoverView
- (instancetype)initWithSource:(id<SNSource>)source style:(SNFileRowStyle)style;
@property (nonatomic) SNFile *file;
@property (nonatomic) SNFileRowDetail detail;
/// Where it sits in its group (a list rounds the outer corners and closes the last).
@property (nonatomic) BOOL first, last;
/// Hovered, the second line says what a click does (a conversation's files).
@property (nonatomic) BOOL showsActionOnHover;
/// The hover actions (download, open in browser, more), for tests and snapshots.
@property (nonatomic, readonly) NSArray<SNButton *> *actionButtons;
@end

@interface SNLinkRow : SNHoverView
- (instancetype)initWithStyle:(SNFileRowStyle)style;
@property (nonatomic) SNChannelLink *link;
@property (nonatomic) BOOL first, last;
/// View link details and More, for tests and snapshots.
@property (nonatomic, readonly) NSArray<SNButton *> *actionButtons;
@end

/// SearchFileSkeleton: a 36 pt tile and three bars while the list loads; `index` varies the
/// title bar's length as Slack's random one does.
@interface SNFileSkeletonRow : NSView
- (instancetype)initWithStyle:(SNFileRowStyle)style index:(NSUInteger)index last:(BOOL)last;
@end

NS_ASSUME_NONNULL_END
