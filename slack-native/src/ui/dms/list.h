// The DMs tab's list (components.json dm_list_row, effects.txt [L4] [A20]), also used by the DMs
// peek: full-width rows with a 36 pt picture, a bold name, the date at the right and up to two
// lines of preview, a 1 pt hairline under each. Rows are 73 pt with one line of preview, 22 pt
// more with two and 68 pt with none. The current row and the hovered one get the 8% overlay,
// instantly; hovering the current row changes nothing. A list of ui/kit/list.h.
#import <AppKit/AppKit.h>

#import "render/document.h"
#import "ui/kit/avatar.h"
#import "ui/kit/list.h"

NS_ASSUME_NONNULL_BEGIN

@interface SNDMListItem : NSObject
/// What choosing the row opens: a conversation ID, or the Activity item's key.
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, nullable) NSURL *avatarURL;
@property (nonatomic) SNAvatarPresence presence;
@property (nonatomic) BOOL doNotDisturb;
@property (nonatomic, nullable) NSDate *date;
@property (nonatomic, nullable) SNRenderDocument *preview;
/// Bold name and date, and in the Activity feed the unread dot.
@property (nonatomic) BOOL unread;
/// A section header instead of a row (Slack's non_collapsible_header: "VIP unreads", "Everything
/// else"): the title alone, 13 pt bold, 24 pt in, 8 pt above and below; `rule` draws the 1 pt line
/// over it (border_top). Not chosen.
@property (nonatomic) BOOL header, rule;
@end

@interface SNDMListView : SNListView
@property (nonatomic, copy) NSArray<SNDMListItem *> *items;
/// The current row's identifier.
@property (nonatomic, copy, nullable) NSString *selectedIdentifier;
@property (nonatomic, copy, nullable) void (^chosen)(SNDMListItem *item);
/// The clock dates are worded against; now by default.
@property (nonatomic, null_resettable) NSDate *now;
@end

NS_ASSUME_NONNULL_END
