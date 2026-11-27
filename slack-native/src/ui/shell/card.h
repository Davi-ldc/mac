// The content card: the rounded panel right of the rail and under the top bar, 4 pt from the
// window's right and bottom edges (components.json window_background, effects.txt [L3]), split
// into the sidebar, the conversation and the thread column with resizers between them.
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

static const CGFloat SNCardInset = 4;
/// Slack's narrowest sidebar and narrowest conversation (components.json sidebar_container,
/// thread_pane_flexpane), and the thread column's limits.
static const CGFloat SNSidebarMinimumWidth = 180, SNPrimaryMinimumWidth = 300;
static const CGFloat SNSecondaryMinimumWidth = 300, SNSecondaryMaximumWidth = 1000;

/// A primary column view whose header spans the primary and secondary columns, as Slack's
/// conversation header does over an open thread (design/ref/live/click/t_thread_open.png). The
/// card lays the header out across both, at its intrinsic height, the way NSScrollView tiles its
/// table's header view; the columns start under it.
@protocol SNCardHeaderProvider <NSObject>
@property (nonatomic, readonly) NSView *cardHeaderView;
@end

@interface SNContentCard : NSView
/// The primary view may provide a header (SNCardHeaderProvider).
@property (nonatomic, nullable) NSView *sidebarView, *primaryView, *secondaryView;
/// The sidebar column's width, without the 1 pt divider; kept within the limits on layout.
@property (nonatomic) CGFloat sidebarWidth;
@property (nonatomic) CGFloat secondaryWidth;
@property (nonatomic) BOOL secondaryVisible;
@property (nonatomic) CGFloat sidebarMinimumWidth;
/// Collapsing animates the sidebar's width (240 ms, cubic-bezier(.1,1,.2,1)).
@property (nonatomic) BOOL sidebarCollapsed;
- (void)setSidebarCollapsed:(BOOL)collapsed animated:(BOOL)animated;
/// Called after the user drags a resizer.
@property (nonatomic, copy, nullable) void (^widthsChanged)(void);
@end

NS_ASSUME_NONNULL_END
