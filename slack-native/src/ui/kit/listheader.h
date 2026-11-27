// The title row of the DMs and Activity lists (components.json sidebar_header, effects.txt
// [A12] [A13]): an 18 pt black title, optionally with a caret, whose button takes the 8% overlay
// on hover; the unreads switch and an optional compose button at the right. The peek's compact
// row is 44 pt with a 15 pt title and a hairline under it.
#import <AppKit/AppKit.h>

#import "ui/kit/button.h"
#import "ui/kit/toggle.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SNListHeaderStyle) {
    /// The sidebar column's 49 pt header.
    SNListHeaderPage,
    /// The rail peek's 44 pt header.
    SNListHeaderPeek,
};

@interface SNListHeader : NSView
- (instancetype)initWithTitle:(NSString *)title style:(SNListHeaderStyle)style caret:(BOOL)caret compose:(BOOL)compose;
@property (nonatomic, readonly) SNHoverView *titleButton;
@property (nonatomic, readonly) SNUnreadsToggle *unreadsToggle;
@property (nonatomic, readonly, nullable) SNButton *composeButton;
@property (nonatomic, readonly) CGFloat height;
@end

NS_ASSUME_NONNULL_END
