// The Files tab's page in the conversation column (UnifiedFilesExplorer with
// useUnifiedFilesExplorer): the 50 pt view header with the page's title and New, the search
// field, the controls (All / Created by you / Shared with you, the file types on All files, the
// sort and Filters) and the files 50 a page with Slack's pager: framed rows with the type icon
// or picture, the name, and who made it and when it was last viewed or updated. Each visit asks
// for the first page again.
#import <AppKit/AppKit.h>

#import "source/source.h"
#import "ui/shell/pane.h"

NS_ASSUME_NONNULL_BEGIN

@interface SNFilesBrowserView : NSView
- (instancetype)initWithSource:(id<SNSource>)source navigator:(id<SNNavigator>)navigator;
/// Shows SNPageFiles, SNPageFilesCanvases or SNPageFilesLists from its first page, the filters
/// back to the page's own.
- (void)showPage:(NSString *)page;
- (void)focusSearch;
/// Submits a search (Return in the field).
- (void)search:(NSString *)query;
/// "all", "created" or "shared".
@property (nonatomic, copy) NSString *filter;
/// Slack's sort: "last_engaged" (Recently viewed), "timestamp" (Last updated), "score".
@property (nonatomic, copy) NSString *sort;
/// The file types searched (SNFileType...).
@property (nonatomic, copy) NSArray<NSString *> *fileTypes;
/// The Filters dialog's From and In.
- (void)setFromUserIDs:(NSArray<NSString *> *)userIDs inConversations:(NSArray<NSString *> *)conversationIDs;
- (void)showPageNumber:(NSInteger)page;
/// What the page shows: its files and pages.
@property (nonatomic, readonly) NSArray<SNFile *> *files;
@property (nonatomic, readonly) NSInteger pageNumber, pageCount;
/// The rows, controls and fillers under the field, top to bottom, for tests.
@property (nonatomic, readonly) NSArray<NSView *> *items;
@end

NS_ASSUME_NONNULL_END
