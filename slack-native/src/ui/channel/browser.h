// Slack's channel browser (/open alone: the Directories page on its Channels tab), in the
// conversation column: "Search for channels" (Return searches), the sort menu, and the channels a
// page at a time (search.modules.channels) as rows with their name, "Joined", members and purpose;
// under the pointer a row says "View channel" and offers Join, or Leave for a channel the user is
// in, and a click opens the channel. Slack's People and other tabs, its filters and Create Channel
// are not here.
#import <AppKit/AppKit.h>

#import "source/source.h"
#import "ui/shell/pane.h"

NS_ASSUME_NONNULL_BEGIN

@interface SNChannelBrowserView : NSView
- (instancetype)initWithSource:(id<SNSource>)source navigator:(id<SNNavigator>)navigator;
/// Asks for the first page again (each time the page opens).
- (void)reload;
- (void)focusSearch;
/// What was searched (Return in the field), the sort in Slack's words and the page (tests).
- (void)search:(NSString *)query;
@property (nonatomic, readonly, copy) NSString *sort;
- (void)sortBy:(NSString *)sort ascending:(BOOL)ascending;
@property (nonatomic, readonly) NSArray<SNConversation *> *channels;
@property (nonatomic, readonly) NSInteger page, pageCount;
@property (nonatomic, readonly) BOOL showsError;
- (void)showPage:(NSInteger)page;
/// A row's Join or Leave, and a click on the row (tests).
- (void)toggleMembershipOfChannelAtIndex:(NSUInteger)index;
- (void)openChannelAtIndex:(NSUInteger)index;
@end

NS_ASSUME_NONNULL_END
