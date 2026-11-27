// The people picker of Slack's add-people dialogs (a MultiSelect of size large): the people chosen
// as chips (c-token--large: 32 pt on surf-hgl-1, radius 4, the square picture at the left, the
// bold name and its x) wrapping in a 44 pt box with the typing field after them, and the people
// matching what is typed in a list under it (a 20 pt picture, the bold name, presence, the other
// name; a row that cannot be chosen says why at the right, dimmed). Up and Down move through the
// list, Return or a click adds the person, Backspace in an empty field takes the last chip away.
#import <AppKit/AppKit.h>

#import "source/source.h"

NS_ASSUME_NONNULL_BEGIN

@interface SNPeoplePicker : NSView
/// `rowHeight` is the list's: 32 in the channel dialog, 28 in the group DM one.
- (instancetype)initWithSource:(id<SNSource>)source placeholder:(NSString *)placeholder rowHeight:(CGFloat)rowHeight;
/// The people chosen, in order.
@property (nonatomic, copy) NSArray<NSString *> *userIDs;
/// Who the list offers; unset, people: no apps, no one deactivated, not the user.
@property (nonatomic, copy, nullable) BOOL (^offers)(SNUser *user);
/// Why a person cannot be chosen ("Already in this conversation"), or nil.
@property (nonatomic, copy, nullable) NSString *_Nullable (^unavailableReason)(SNUser *user);
/// How many people the list offers at most (Slack's searcher limit).
@property (nonatomic) NSUInteger limit;
/// How many may be chosen (0: any).
@property (nonatomic) NSUInteger maximum;
/// After the chips changed, and after the box's height did.
@property (nonatomic, copy, nullable) void (^changed)(void);
@property (nonatomic, copy, nullable) void (^heightChanged)(void);
/// The box's height for its chips at its width.
@property (nonatomic, readonly) CGFloat preferredHeight;
- (void)focus;
/// Types `query` as the user would (tests); the list's rows, and choosing one.
- (void)typeQuery:(NSString *)query;
@property (nonatomic, readonly) NSArray<NSString *> *suggestionTitles;
- (void)chooseSuggestionAtIndex:(NSUInteger)index;
@end

NS_ASSUME_NONNULL_END
