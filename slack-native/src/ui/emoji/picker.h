// The emoji picker (components.json emoji_picker, effects.txt [emoji-*], measured live): a
// 363 pt wide #1a1d21 panel with category tabs, a search field, a scrolling grid of 36x32 cells
// (frequently used, Slack's "where work happens" set, the standard categories, the workspace's
// custom emoji) and a footer with the skin tone. It opens and closes in one frame.
#import <AppKit/AppKit.h>

#import "source/source.h"
#import "ui/kit/hoverview.h"
#import "ui/kit/overlay.h"

NS_ASSUME_NONNULL_BEGIN

@interface SNEmojiPicker : NSObject
/// Shows the picker on the `placement` side of `rect` (in `view`'s coordinates), its leading
/// edge on the rect's, closing the one already open. `completion` gets the chosen emoji's name
/// without colons, with the skin tone when one applies ("thumbsup::skin-tone-2"); the picker
/// closes after it.
+ (instancetype)showForRect:(NSRect)rect
                     inView:(NSView *)view
                  placement:(SNPlacement)placement
                     source:(id<SNSource>)source
                 completion:(void (^)(NSString *name))completion;
/// The open picker, if any.
+ (nullable SNEmojiPicker *)current;
/// Called when the picker closes, chosen or not.
@property (nonatomic, copy, nullable) void (^onClose)(void);
- (void)close;
@end

/// The picker's content, SNEmojiPickerSize, for the popover (and for snapshots).
@interface SNEmojiPickerView : NSView
- (instancetype)initWithSource:(id<SNSource>)source;
@property (nonatomic, copy, nullable) void (^completion)(NSString *name);
/// What the search field holds; setting it filters the grid.
@property (nonatomic, copy) NSString *query;
/// The category tabs, left to right.
@property (nonatomic, readonly) NSArray<SNHoverView *> *tabs;
/// The cell under the pointer (or chosen with the arrows): its emoji name, nil for none.
@property (nonatomic, copy, nullable) NSString *highlightedEmoji;
/// Puts the caret in the search field (the picker opens that way).
- (void)focusSearch;
@end

static const NSSize SNEmojiPickerSize = {363, 488.5};

NS_ASSUME_NONNULL_END
