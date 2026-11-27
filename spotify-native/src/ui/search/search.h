// Instant global search results view: <1 ms local matches + streaming 80 ms debounced searchDesktop & suggestions.
#import <AppKit/AppKit.h>

#import "model/search.h"
#import "store/store.h"
#import "ui/kit/controls.h"
#import "ui/kit/nav.h"

NS_ASSUME_NONNULL_BEGIN

@interface SPSearchView : NSView <SPChangeObserver>
@property (nonatomic, weak, nullable) id<SPNavigator> navigator;
@property (nonatomic, strong, nullable) SPSearchResults *results;
@property (nonatomic, readonly) SPTrackListView *songsList;

- (instancetype)initWithFrame:(NSRect)frame store:(SPStore *)store navigator:(nullable id<SPNavigator>)navigator;
- (void)applyResults:(nullable SPSearchResults *)results;
@end

NS_ASSUME_NONNULL_END
