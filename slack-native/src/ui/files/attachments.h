// What a conversation's "Files and links" tab and its peek list (useChannelAttachmentsExplorer):
// three explorers over the conversation, its photos and videos, its other files (folders left
// out) and the links shared in it, each a page of 50 at a time, searched and sorted together.
// The tab and the peek share one, as the client's browser instances are shared.
#import <Foundation/Foundation.h>

#import "source/source.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SNAttachmentKind) {
    SNAttachmentAll,
    SNAttachmentFiles,
    SNAttachmentMedia,
    SNAttachmentLinks,
};

typedef NS_ENUM(NSInteger, SNAttachmentSort) {
    SNAttachmentNewest,
    SNAttachmentOldest,
    /// Only while searching.
    SNAttachmentRelevant,
};

/// An entry of the mixed list: a file or a link, and when it was shared.
@interface SNAttachment : NSObject
@property (nonatomic, readonly, nullable) SNFile *file;
@property (nonatomic, readonly, nullable) SNChannelLink *link;
@property (nonatomic, readonly) NSTimeInterval timestamp;
@end

@interface SNConversationAttachments : NSObject
- (instancetype)initWithSource:(id<SNSource>)source conversationID:(NSString *)conversationID;
@property (nonatomic, readonly) NSString *conversationID;
/// Setting either asks for the first pages again.
@property (nonatomic, copy) NSString *query;
@property (nonatomic) SNAttachmentSort sort;
/// Asks for the first pages again.
- (void)reload;
/// Asks for them unless they were asked for already.
- (void)loadIfNeeded;
@property (nonatomic, readonly) NSArray<SNFile *> *media, *files;
@property (nonatomic, readonly) NSArray<SNChannelLink *> *links;
/// A request of that explorer is out.
- (BOOL)isLoading:(SNAttachmentKind)kind;
/// Slack has pages after the last one loaded.
- (BOOL)hasMore:(SNAttachmentKind)kind;
/// The next page of one explorer (files, media or links).
- (void)loadMore:(SNAttachmentKind)kind;
/// getChannelAttachmentsMixedRows: the files and links (and the media with them while
/// searching), one list by when they were shared, newest first unless sorted oldest first.
- (NSArray<SNAttachment *> *)mixedIncludingMedia:(BOOL)media;
/// After every answer.
@property (nonatomic, copy, nullable) void (^changed)(void);
@end

NS_ASSUME_NONNULL_END
