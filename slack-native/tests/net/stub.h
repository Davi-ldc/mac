// Test doubles for the network: an NSURLProtocol that answers every request of a session made
// with SNStubURLSession() from a handler (nothing reaches the network), and a run-loop wait.
#import <Foundation/Foundation.h>

#import "net/api.h"

NS_ASSUME_NONNULL_BEGIN

/// An answer: status, headers and body; a nil answer fails the request like a lost connection.
@interface SNStubAnswer : NSObject
+ (instancetype)status:(NSInteger)status headers:(nullable NSDictionary<NSString *, NSString *> *)headers json:(nullable id)json;
@property (nonatomic, readonly) NSInteger status;
@property (nonatomic, readonly) NSDictionary<NSString *, NSString *> *headers;
@property (nonatomic, readonly) NSData *body;
@end

/// A request as the stub saw it, body included (URLSession hands it over as a stream).
@interface SNStubRequest : NSObject
@property (nonatomic, readonly) NSURLRequest *request;
@property (nonatomic, readonly) NSData *body;
/// The form body's fields, decoded.
@property (nonatomic, readonly) NSDictionary<NSString *, NSString *> *form;
/// The URL's query fields, decoded.
@property (nonatomic, readonly) NSDictionary<NSString *, NSString *> *query;
/// The last path component ("chat.postMessage").
@property (nonatomic, readonly) NSString *method;
@end

typedef SNStubAnswer *_Nullable (^SNStubHandler)(SNStubRequest *request);

/// A session whose requests all go to `handler` (called on a background thread).
NSURLSession *SNStubURLSession(SNStubHandler handler);
/// Requests the stub answered since the session was made, oldest first.
NSArray<SNStubRequest *> *SNStubRequests(void);

/// A fake API: answers calls from a block on the next run loop turn and records them.
@interface SNTestAPI : NSObject <SNAPI>
/// nil answers fail like a lost connection and ok:false ones as Slack's error (as SNClient
/// hands them over); unset answers {ok: true}.
@property (nonatomic, copy, nullable) NSDictionary *_Nullable (^answer)(NSString *method, NSDictionary *params);
/// Answers for edge API paths ("users/info"), as `answer`.
@property (nonatomic, copy, nullable) NSDictionary *_Nullable (^edgeAnswer)(NSString *path, NSDictionary *body);
/// @[method or path, params or body], oldest first.
@property (nonatomic, readonly) NSMutableArray<NSArray *> *calls;
@property (nonatomic, readonly) NSArray<NSString *> *methods;
/// The HTTP status an upload gets (unset: 200); uploads are recorded in `calls` as
/// @["upload", @{url, name, mimeType}].
@property (nonatomic, copy, nullable) NSInteger (^uploadStatus)(NSURL *url, NSString *name);
/// Holds web API answers in `held` until the test runs them (to order them against events).
@property (nonatomic) BOOL holds;
@property (nonatomic, readonly) NSMutableArray<dispatch_block_t> *held;
@end

/// Runs the main run loop until `condition` holds or `timeout` passes; returns the condition.
BOOL SNWaitUntil(NSTimeInterval timeout, BOOL (^condition)(void));

NS_ASSUME_NONNULL_END
