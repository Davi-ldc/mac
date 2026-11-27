// Slack's file URLs from the file views: what a video or audio clip streams from, a snippet's
// whole text and where the Download action saves to. All need the session's cookies and user
// agent, as the image fetcher sends them; the signed-in launch installs them.
#import <AVFoundation/AVFoundation.h>

#import "model/message.h"

NS_ASSUME_NONNULL_BEGIN

/// `cookies` is asked on every use (Slack rotates them); nil or never installed (fixture runs)
/// leaves media unplayable and downloads failing, without reaching the network.
void SNSetFileCredentials(NSArray<NSHTTPCookie *> *_Nullable (^_Nullable cookies)(void), NSString *_Nullable userAgent);
/// Loads AVFoundation lazily (returns the dlopen handle, or NULL on failure).
void *_Nullable SNLoadAVFoundation(void);
/// An asset streaming `url` with the credentials; nil without them.
AVURLAsset *_Nullable SNFileAsset(NSURL *url);
/// The file's bytes (url_private) as text, for a snippet expanded in place; nil when it could not
/// be read.
void SNFetchFileText(SNFile *file, void (^completion)(NSString *_Nullable text));
/// Saves the file into ~/Downloads under a name not taken yet and bounces the Dock's Downloads
/// stack; `completion` (main thread) gets where it landed, or nil.
void SNDownloadFile(SNFile *file, void (^_Nullable completion)(NSURL *_Nullable saved));

NS_ASSUME_NONNULL_END
