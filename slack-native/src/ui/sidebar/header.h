// The top of the Home sidebar: the workspace's name with its menu caret, the sidebar settings and
// new message buttons, and the "find a conversation" field under them (components.json
// sidebar_header, sidebar_filter_input).
#import <AppKit/AppKit.h>

#import "ui/kit/button.h"
#import "ui/kit/filter.h"

NS_ASSUME_NONNULL_BEGIN

/// The row with the title and buttons, then the field: the list starts below both.
static const CGFloat SNSidebarHeaderRowHeight = 49, SNSidebarHeaderHeight = 89;

@interface SNSidebarHeaderView : NSView
@property (nonatomic, copy) NSString *workspaceName;
@property (nonatomic, readonly) SNHoverView *titleButton;
@property (nonatomic, readonly) SNButton *settingsButton, *composeButton;
@property (nonatomic, readonly) SNFilterField *filterField;
@end

NS_ASSUME_NONNULL_END
