// The Activity feed's rows, as the web client's multi-line activity row (ActivityRowContentMultiLine,
// CSS activity_multi_line_row_content and activity_row_content_container--peek): a 36 pt picture
// at 80% opacity until unread, the sender beside the time it happened, the message in up to two
// lines (one for a reaction, under "Você: "), the place it happened in 13 pt, and for a reaction
// its pill. Unread rows have a black sender, brighter text and an 8 pt dot at the right (a
// thread its unread replies' count instead). Rows are separated by 1 pt lines; the pointer adds
// the 8% hover overlay at once and the row's actions (actions.h) over its top right corner.
//
// A list of ui/kit/list.h; scrolling near the end asks for more.
#import <AppKit/AppKit.h>

#import "render/document.h"
#import "ui/activity/actions.h"
#import "ui/kit/list.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SNActivityListStyle) {
    /// The rail peek: dark surfaces, 12 pt around each row.
    SNActivityListPeek,
    /// The Activity tab in the sidebar column: the theme's colours, 20 pt at the sides.
    SNActivityListSidebar,
};

@interface SNActivityListItem : NSObject
/// The entry's key: what choosing the row opens.
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *sender;
@property (nonatomic, nullable) NSURL *avatarURL;
@property (nonatomic, nullable) NSDate *date;
/// The message; nil while it loads (a placeholder bar shows).
@property (nonatomic, nullable) SNRenderDocument *body;
/// 2, or 1 for a reaction's message.
@property (nonatomic) NSUInteger bodyLines;
/// "Menção em #canal", "Thread em #canal".
@property (nonatomic, copy, nullable) NSString *footer;
/// A reaction's emoji and how many reacted with it.
@property (nonatomic, copy, nullable) NSString *reactionName;
@property (nonatomic) NSInteger reactionCount;
@property (nonatomic) BOOL unread;
/// A thread's unread replies, shown instead of the dot.
@property (nonatomic) NSInteger unreadReplies;
@end

@interface SNActivityListView : SNListView
- (instancetype)initWithStyle:(SNActivityListStyle)style;
@property (nonatomic, readonly) SNActivityListStyle style;
@property (nonatomic, copy) NSArray<SNActivityListItem *> *items;
@property (nonatomic, copy, nullable) void (^chosen)(SNActivityListItem *item);
/// Called when the rows in view come within a few of the last one.
@property (nonatomic, copy, nullable) void (^nearEnd)(void);
/// A hover action was pressed on the row of `item`; `rect` is its button in the list's coordinates.
/// The actions stay while holdsHover is set (their menu is open).
@property (nonatomic, copy, nullable) void (^actionChosen)(SNActivityListItem *item, SNActivityAction action, NSRect rect);
/// The hovered row's actions (tests, snapshots); hidden while no row is hovered.
@property (nonatomic, readonly) SNActivityActionBar *actionBar;
/// The clock times are worded against; now by default.
@property (nonatomic, null_resettable) NSDate *now;
@end

/// The time an Activity row shows (the web client's activity timestamp): "Agora" under a
/// minute, "N min" under an hour, then as list dates (render/format.h SNFormatListDate).
NSString *SNActivityTime(NSDate *date, NSDate *now);

NS_ASSUME_NONNULL_END
