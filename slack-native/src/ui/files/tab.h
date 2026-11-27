// A conversation's "Files and links" tab (files_tab_view with useChannelAttachmentsExplorer): the
// search field 20 pt under the tab bar, then a list 968 pt wide at most: the attachment type
// (All, Files, Media, Links) and the sort (Newest, Oldest; Most relevant while searching); on All
// the "Photos and videos" strip with See all, then files and links as one list by when they were
// shared and a card per kind that has more ("More results by type"); one kind at a time with
// Load More. Skeleton rows while it loads and Slack's empty states.
#import <AppKit/AppKit.h>

#import "ui/files/attachments.h"

NS_ASSUME_NONNULL_BEGIN

@interface SNConversationFilesView : NSView
- (instancetype)initWithSource:(id<SNSource>)source;
/// The conversation's lists (shared with the tab's peek); each visit reloads them.
@property (nonatomic, nullable) SNConversationAttachments *attachments;
/// Re-reads the attachments after they changed.
- (void)update;
@property (nonatomic) SNAttachmentKind kind;
- (void)search:(NSString *)query;
- (void)focusSearch;
/// What the list shows, top to bottom (rows, tiles, sections, buttons), for tests.
@property (nonatomic, readonly) NSArray<NSView *> *items;
@end

NS_ASSUME_NONNULL_END
