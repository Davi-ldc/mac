// Spotifly 1:1 Startpage: Recently Played, Your Top Tracks (4 Weeks / 6 Months / 1 Year grid),
// Your Top Artists (circular row), and Your Playlists (with Show All).
#import <AppKit/AppKit.h>

#import "store/store.h"
#import "ui/kit/nav.h"

NS_ASSUME_NONNULL_BEGIN

@interface SPHomeView : NSView <SPChangeObserver>
@property (nonatomic, weak, nullable) id<SPNavigator> navigator;
@property (nonatomic, readonly) NSUInteger shelfCount;
@property (nonatomic, copy) NSString *selectedRangeKey;

- (instancetype)initWithFrame:(NSRect)frame store:(SPStore *)store navigator:(nullable id<SPNavigator>)navigator;
- (void)reloadShelves;
- (void)setTopTracks:(NSArray<SPTrack *> *)tracks topArtists:(NSArray<SPArtist *> *)artists forRange:(NSString *)rangeKey;
@end

NS_ASSUME_NONNULL_END
