// Always-active global search controller: <1 ms local library results + 80 ms debounced searchDesktop & searchSuggestions
// with generation counter and immediate NSURLSessionDataTask cancellation of stale in-flight requests.
#import <Foundation/Foundation.h>

#import "model/search.h"
#import "net/client.h"
#import "store/store.h"

NS_ASSUME_NONNULL_BEGIN

@class SPSearchController;

@protocol SPSearchControllerDelegate <NSObject>
- (void)searchController:(SPSearchController *)controller didUpdateResults:(SPSearchResults *)results;
@optional
- (void)searchController:(SPSearchController *)controller didFailRemoteWithError:(NSError *)error forQuery:(NSString *)query;
@end

@interface SPSearchController : NSObject
@property (nonatomic, weak, nullable) id<SPSearchControllerDelegate> delegate;
@property (nonatomic, readonly, copy) NSString *currentQuery;
@property (nonatomic, readonly, nullable) SPSearchResults *currentResults;
@property (nonatomic, readonly) uint64_t generation;
/// Default 0.080 (80 ms).
@property (nonatomic) NSTimeInterval debounceInterval;
@property (nonatomic) NSInteger remoteLimit;

- (instancetype)initWithStore:(SPStore *)store client:(SPNetClient *)client NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Called on every keystroke. Publishes local results immediately (<1 ms), cancels stale in-flight tasks,
/// and schedules debounced `searchDesktop` + `searchSuggestions` network calls.
- (void)updateQuery:(NSString *)query;

/// Cancels any pending debounce timer and in-flight network requests.
- (void)cancel;
@end

NS_ASSUME_NONNULL_END
