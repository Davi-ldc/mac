// What the store and sync need from the network: Slack Web API calls and the edge API, answered
// on the main thread. SNClient implements it over HTTP; SNFixtureSource answers from files.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SNCallPriority) {
    /// Something the user is waiting for (open, send, react): ahead of everything else.
    SNCallUserFacing,
    /// Prefetch, presence, gap fill: spaced out so they never crowd the user's calls.
    SNCallBackground,
};

extern NSErrorDomain const SNAPIErrorDomain;
typedef NS_ERROR_ENUM(SNAPIErrorDomain, SNAPIError) {
    /// Slack answered ok:false; userInfo[SNAPIErrorNameKey] holds its "error" string.
    SNAPIErrorSlack = 1,
    /// No answer after the retries (offline, timeouts, 5xx).
    SNAPIErrorNetwork,
    /// The method answered unknown_method once and is not called again.
    SNAPIErrorDisabled,
    /// The session is gone (invalid_auth that a refreshed token did not fix).
    SNAPIErrorSignedOut,
    /// Refused without calling: the method changes something in Slack and SN_READONLY is on.
    SNAPIErrorReadOnly,
};
/// The "error" string of an SNAPIErrorSlack ("channel_not_found").
extern NSErrorUserInfoKey const SNAPIErrorNameKey;
NSError *SNAPIMakeError(SNAPIError code, NSString *_Nullable name);
/// The Slack error string, or nil for other errors.
NSString *_Nullable SNAPIErrorName(NSError *_Nullable error);
/// An SNAPIErrorSlack carrying Slack's whole ok:false body (some errors explain themselves in it:
/// too_many_vips' max_vip_limit).
NSError *SNAPISlackError(NSDictionary *body);
/// The ok:false body of an SNAPISlackError, else nil.
NSDictionary *_Nullable SNAPIErrorResponse(NSError *_Nullable error);

/// The whole JSON body when Slack answered ok:true, else nil and the error.
typedef void (^SNAPICompletion)(NSDictionary *_Nullable response, NSError *_Nullable error);

@protocol SNAPI <NSObject>
/// POSTs `method` with `params` as the form body (keys starting with "_x_" go into the query,
/// like the web client's). Values are strings; JSON values go in already encoded.
- (void)call:(NSString *)method
      params:(NSDictionary<NSString *, NSString *> *)params
    priority:(SNCallPriority)priority
  completion:(nullable SNAPICompletion)completion;
/// POSTs `body` as JSON to https://edgeapi.slack.com/cache/<team>/<path> ("users/info").
- (void)callEdge:(NSString *)path
            body:(NSDictionary *)body
        priority:(SNCallPriority)priority
      completion:(nullable SNAPICompletion)completion;
/// POSTs the local `file` to `url` (files.getUploadURL's upload_url) as the web client's upload
/// queue does: a multipart form whose "file" part is named `name` and typed `mimeType`, without
/// cookies. `progress` gets the fraction sent and `completion` the HTTP status (0: no answer,
/// refused or cancelled), both on the main thread. The block returned cancels the upload.
- (dispatch_block_t)upload:(NSURL *)file
                      name:(NSString *)name
                  mimeType:(NSString *)mimeType
                        to:(NSURL *)url
                  progress:(nullable void (^)(double fraction))progress
                completion:(void (^)(NSInteger status))completion;
@end

NS_ASSUME_NONNULL_END
