// The keys Slack's client files a message's collapsible items under (its getExpandableKey), which
// the source keeps the user's collapse and expand choices by (SNSource expandedStateOfItem:): one
// for a message's files together, one per legacy attachment with a picture, video or audio, one
// per Block Kit picture. `viewContext` is the client's name for the column showing the message,
// so a choice made in one column does not change the other.
#import <Foundation/Foundation.h>

#import "source/source.h"

NS_ASSUME_NONNULL_BEGIN

/// The client's view contexts for the conversation column ("Channel") and the thread ("Thread").
extern NSString *const SNViewContextChannel, *const SNViewContextThread;

/// "inline_files_msg_<ts with _ for .><file IDs joined by _><viewContext>".
NSString *SNExpandableFilesKey(SNMessage *message, NSString *viewContext);
/// "img_msg_<ts><id or image_url><viewContext>" (vid_msg_, aud_msg_ for video_html, audio_html);
/// nil for an attachment with none of them.
NSString *_Nullable SNExpandableAttachmentKey(NSDictionary *attachment, NSString *ts, NSString *viewContext);
/// "block_image_<ts>_<block_id>": Block Kit pictures are kept alike in every column.
NSString *SNExpandableBlockImageKey(NSString *ts, NSString *blockID);
/// Every key of the message, as /collapse and /expand set them: its files' when it has files,
/// else its attachments' (with the pictures in their blocks), else its blocks' pictures.
NSArray<NSString *> *SNExpandableKeysOfMessage(SNMessage *message, NSString *viewContext);

/// Whether the message's files show, the user's choice first: else they do unless one is a picture
/// and the preferences hide pictures uploaded to Slack (expand_internal_inline_imgs; until the
/// preferences are known, Slack's default shows them).
BOOL SNFilesAreExpanded(SNMessage *message, NSString *viewContext, id<SNSource> source);
/// isAttachmentExpanded: a link preview's or Block Kit picture, the user's choice first: else it
/// shows unless the preferences hide pictures from linked websites (expand_inline_imgs) or it is
/// over 20 MB with obey_inline_img_limit on. `bytes` 0 when unknown.
BOOL SNMediaIsExpanded(NSString *key, long long bytes, id<SNSource> source);

NS_ASSUME_NONNULL_END
