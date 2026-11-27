// The explorer's controls and fillers shared by the Files tab and a conversation's "Files and
// links" (client-boot-styles: p-explorer_controls__button, searchFilterSingleSelectButton,
// p-explorer_section, c-empty_state, ExplorerLoadMoreButton, MoreResultsByType).
#import <AppKit/AppKit.h>

#import "ui/kit/button.h"

NS_ASSUME_NONNULL_BEGIN

/// The controls row's height (28 pt buttons) and what it leaves under it.
static const CGFloat SNExplorerControlHeight = 28, SNExplorerControlsBottom = 8;

/// p-explorer_controls__button: 28 pt, 13 pt bold content-pry on ctr-pry, a 1 pt
/// rgba(foreground, .3) border, radius 4, 11 pt in; active, content-hgl-1 under the inverted
/// foreground. An optional 18 pt icon 2 pt before the title and a 18 pt caret 4 pt after it.
@interface SNExplorerPill : SNHoverView
- (instancetype)initWithTitle:(NSString *)title;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy, nullable) NSString *icon;
@property (nonatomic) BOOL caret, active;
@property (nonatomic, readonly) CGFloat fittingWidth;
@end

@interface SNExplorerOption : NSObject
+ (instancetype)optionWithTitle:(NSString *)title value:(NSString *)value;
@property (nonatomic, readonly, copy) NSString *title, *value;
/// Shown before the title in a menu (the Types checklist).
@property (nonatomic, copy, nullable) NSString *icon;
@end

/// SearchFilterSingleSelect: the chosen option's label and a 16 pt caret on a 28 pt button with
/// a 1 pt otl-sec border (blue while not the default); a click opens a 280 pt menu of the options
/// with the chosen one checked.
@interface SNExplorerSelect : SNHoverView
@property (nonatomic, copy) NSArray<SNExplorerOption *> *options;
@property (nonatomic, copy) NSString *value;
@property (nonatomic, copy, nullable) NSString *defaultValue;
@property (nonatomic, copy, nullable) void (^changed)(NSString *value);
@property (nonatomic, readonly) CGFloat fittingWidth;
/// Opens the menu (the click).
- (void)open;
@end

/// The radiogroup of pills ("expanded" selects): All / Created by you / Shared with you, or All /
/// Files / Media / Links; 4 pt apart.
@interface SNExplorerSegments : NSView
@property (nonatomic, copy) NSArray<SNExplorerOption *> *options;
@property (nonatomic, copy) NSString *value;
@property (nonatomic, copy, nullable) void (^changed)(NSString *value);
@property (nonatomic, readonly) NSArray<SNExplorerPill *> *pills;
@property (nonatomic, readonly) CGFloat fittingWidth;
@end

/// p-explorer_section: a 13 pt bold content-sec label 16 pt under what precedes it and 8 pt over
/// what follows, with an optional button at its right ("See all").
@interface SNExplorerSection : NSView
- (instancetype)initWithTitle:(NSString *)title action:(nullable NSString *)action;
@property (nonatomic, readonly, nullable) SNButton *button;
@end

/// p-explorer_empty_state: c-empty_state centred in 200 pt (380 pt wide at most): the 18 pt black
/// title, the description 8 pt under it and an optional outline button 8 pt under that.
@interface SNExplorerEmptyState : NSView
- (instancetype)initWithTitle:(NSString *)title description:(nullable NSString *)description action:(nullable NSString *)action;
@property (nonatomic, readonly, nullable) SNButton *button;
@property (nonatomic, readonly) CGFloat preferredHeight;
@end

/// ExplorerLoadMoreButton: "Load More", an outline medium button centred 4 pt under the list.
SNButton *SNExplorerLoadMoreButton(void);

/// MoreResultsByType: "More results by type" (15 pt bold, 36 pt above, 20 under) and a card per
/// kind with more pages (42 pt, radius 12, the 16 pt icon, the 13 pt bold label, a caret).
@interface SNExplorerMoreByType : NSView
/// `kinds` are @[title, icon, value].
- (instancetype)initWithKinds:(NSArray<NSArray<NSString *> *> *)kinds chosen:(void (^)(NSString *value))chosen;
@property (nonatomic, readonly) CGFloat preferredHeight;
@property (nonatomic, readonly) NSArray<SNHoverView *> *cards;
@end

NS_ASSUME_NONNULL_END
