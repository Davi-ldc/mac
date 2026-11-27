// What the Files tab and a conversation's "Files and links" list, in the web client's terms: the
// files explorer's request (search.modules.files, whose filters become words of the query) and
// the links shared in a conversation (conversations.searchLinks).
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The explorer's file types (the client's $Z), as the query's type: words name them.
extern NSString *const SNFileTypeImages, *const SNFileTypeVideos, *const SNFileTypeAudio, *const SNFileTypeFolders, *const SNFileTypeLists,
    *const SNFileTypeCanvases, *const SNFileTypeDocuments, *const SNFileTypeSpreadsheets, *const SNFileTypePresentations, *const SNFileTypePDFs,
    *const SNFileTypeSnippets, *const SNFileTypeEmails;
/// The Files tab's "All files": lists, canvases, documents, spreadsheets, presentations, PDFs.
NSArray<NSString *> *SNFileTypesAll(void);
/// What "Created by you" keeps of them: lists, canvases, documents.
NSArray<NSString *> *SNFileTypesCreatedByYou(void);

/// One page request of the files explorer.
@interface SNFileSearch : NSObject <NSCopying>
/// What the user typed; empty browses.
@property (nonatomic, copy) NSString *query;
/// in:<#channel>.
@property (nonatomic, copy, nullable) NSString *conversationID;
/// type: words (any of them) and -type: words.
@property (nonatomic, copy) NSArray<NSString *> *fileTypes, *excludedFileTypes;
/// creator:<@user>.
@property (nonatomic, copy, nullable) NSString *creatorID;
/// from:<@user> words (the Filters dialog's From).
@property (nonatomic, copy) NSArray<NSString *> *fromIDs;
/// "Shared with you": shared_with_you=1, only the user's channels.
@property (nonatomic) BOOL sharedWithYou;
/// Slack's sort parameter ("last_engaged", "timestamp", "score", "last_read") and direction.
@property (nonatomic, copy) NSString *sort;
@property (nonatomic) BOOL ascending;
/// Results per page (Slack's count: 50 unless a list asks for fewer).
@property (nonatomic) NSInteger count;
/// The search_context naming the page ("desktop_files_browser", "desktop_files_channel_tab").
@property (nonatomic, copy) NSString *context;
/// The query Slack is sent: what was typed, then the filters as the client writes them
/// ("in:<#C1|general>", "type:lists", "-type:images", "creator:<@U1>"). `reference` is how the
/// conversation is named in it ("<#C1|general>", a group DM's "<#G1>", a DM's "<@U1>"); nil
/// names it by its ID alone.
- (NSString *)requestQueryWithReference:(nullable NSString *)reference;
@end

/// A link shared in a conversation (conversations.searchLinks).
@interface SNChannelLink : NSObject
@property (nonatomic, readonly) NSURL *url;
@property (nonatomic, readonly, nullable) NSString *title;
/// The site's icon.
@property (nonatomic, readonly, nullable) NSURL *iconURL;
/// When it was shared, in Unix seconds.
@property (nonatomic, readonly) NSTimeInterval timestamp;
+ (nullable instancetype)linkWithJSON:(NSDictionary *)json;
@end

NS_ASSUME_NONNULL_END
