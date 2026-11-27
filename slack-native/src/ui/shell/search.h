// The search modal (components.json search_autocomplete, effects.txt [A3], measured live): a 640
// pt panel (642 with its ring) 35 pt wider than the top bar's field on each side, 4 pt below the
// window's top, opened on mouse-down in one frame and closed by Escape or an outside click. The
// 48 pt query row, the Slack AI note, then "Locais recentes" (recent places) or, while typing,
// people and channels matching the query under a row that searches messages; the selected row
// takes #222429 and an "Enter" hint. Up/Down move the selection, Return opens it, and the
// message search's results replace the rows.
#import <AppKit/AppKit.h>

#import "source/source.h"
#import "ui/shell/pane.h"

NS_ASSUME_NONNULL_BEGIN

@interface SNSearchModal : NSView
/// Opens over `field` (the top bar's search field). `recent` is the conversations visited last,
/// newest first.
+ (instancetype)showOverField:(NSView *)field
                       source:(id<SNSource>)source
                    navigator:(id<SNNavigator>)navigator
                       recent:(NSArray<NSString *> *)recent;
/// The open modal, if any.
+ (nullable SNSearchModal *)current;
@property (nonatomic, readonly) NSTextField *queryField;
/// The rows' titles, top to bottom, and the selected one (tests).
@property (nonatomic, readonly) NSArray<NSString *> *rowTitles;
@property (nonatomic) NSUInteger selectedIndex;
/// Opens the selected row (Return).
- (void)openSelection;
/// Types `query` and searches messages for it; nil types the last query searched this session and
/// lists its suggestions.
- (void)runQuery:(nullable NSString *)query;
- (void)close;
@end

NS_ASSUME_NONNULL_END
