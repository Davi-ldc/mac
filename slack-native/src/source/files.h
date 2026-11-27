// The Files tab and a conversation's "Files and links".
#import <Foundation/Foundation.h>

#import "model/files.h"

NS_ASSUME_NONNULL_BEGIN

@protocol SNFilesSource <NSObject>
/// One page (from 1) of Slack's files explorer (search.modules.files): `completion` gets the
/// files and how many pages there are, or Slack's error name ("" without an answer).
- (void)searchFiles:(SNFileSearch *)search
               page:(NSInteger)page
         completion:(void (^)(NSArray<SNFile *> *_Nullable files, NSInteger pages, NSString *_Nullable error))completion;
/// One page (from 1) of the links shared in a conversation (conversations.searchLinks), newest
/// first unless `oldestFirst`, by relevance while `query` is not empty.
- (void)searchLinksInConversation:(NSString *)conversationID
                            query:(NSString *)query
                      oldestFirst:(BOOL)oldestFirst
                             page:(NSInteger)page
                       completion:(void (^)(NSArray<SNChannelLink *> *_Nullable links, NSInteger pages, NSString *_Nullable error))completion;
/// The files the user opened here, most recent first (the Files tab's "Recently viewed", which
/// Slack's client keeps on the device: at most 10); a change announces SNChangeRecentFiles.
@property (nonatomic, readonly) NSArray<SNFile *> *recentFiles;
- (void)noteFileViewed:(SNFile *)file;
- (void)forgetRecentFile:(NSString *)fileID;
@end

NS_ASSUME_NONNULL_END
