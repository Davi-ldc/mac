// The list that completes what is being typed after '@' (people, @here/@channel/@everyone),
// '#' (channels) and ':' (emoji), shown above the composer while the caret is in the word. The
// arrows move through it, Return or Tab picks, Escape closes it.
#import <AppKit/AppKit.h>

#import "source/source.h"
#import "ui/composer/richtext.h"

NS_ASSUME_NONNULL_BEGIN

@interface SNComposerAutocomplete : NSObject
- (instancetype)initWithSource:(id<SNSource>)source;
/// The conversation the mentions are for (people in it come first; broadcasts need a channel).
@property (nonatomic, copy, nullable) NSString *conversationID;
/// The thread written to, if any: commands that do not run in threads are left out.
@property (nonatomic, copy, nullable) NSString *threadTS;
/// Shows or updates the list for `query` ("@an", "#gen", ":smi"), typed at `range`, above
/// `rect` in `view`; closes it when nothing matches.
- (void)showQuery:(NSString *)query range:(NSRange)range aboveRect:(NSRect)rect inView:(NSView *)view;
- (void)close;
@property (nonatomic, readonly) BOOL isOpen;
/// moveUp:, moveDown:, insertNewline:, insertTab: and cancelOperation: while open; YES when used.
- (BOOL)performCommand:(SEL)command;
/// Called with the picked entity, its text and the range of the query it replaces.
@property (nonatomic, copy, nullable) void (^choose)(SNRichEntity *entity, NSString *text, NSRange range);
/// The rows' titles, top to bottom, and the highlighted one.
@property (nonatomic, readonly) NSArray<NSString *> *titles;
@property (nonatomic, readonly) NSUInteger highlightedIndex;
@end

NS_ASSUME_NONNULL_END
