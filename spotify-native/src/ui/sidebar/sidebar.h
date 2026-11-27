// Native macOS translucent sidebar matching Spotifly 1:1 (Main nav, Library section, Profile + Settings footer).
#import <AppKit/AppKit.h>

#import "store/store.h"
#import "ui/kit/nav.h"

NS_ASSUME_NONNULL_BEGIN

@interface SPSidebarView : NSView <SPChangeObserver>
@property (nonatomic, weak, nullable) id<SPNavigator> navigator;
@property (nonatomic, strong, nullable) SPRoute *activeRoute;

- (instancetype)initWithFrame:(NSRect)frame store:(SPStore *)store navigator:(nullable id<SPNavigator>)navigator;
- (void)reloadItems;
@end

NS_ASSUME_NONNULL_END
