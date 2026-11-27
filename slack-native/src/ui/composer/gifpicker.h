// The GIF picker /gif opens over the composer's emoji button (Slack's p-gif_picker on its GIFs tab,
// here without the emoji tab beside it): "Search all GIFs on Giphy" with what followed /gif, the
// results three to a row (gif.search, searched again 360 ms after typing stops; gif.featured
// without words), Slack's empty and unavailable states. Picking one hands the composer the
// attachment Slack sends it as (an image block titled "GIF"); nothing is sent until the message is.
// The tiles show each GIF's first frame.
#import <AppKit/AppKit.h>

#import "source/source.h"

NS_ASSUME_NONNULL_BEGIN

@interface SNGifPicker : NSView
+ (nullable instancetype)showForRect:(NSRect)rect
                              inView:(NSView *)view
                              source:(id<SNSource>)source
                               query:(NSString *)query
                              picked:(void (^)(NSDictionary *attachment, NSURL *preview))picked;
+ (nullable SNGifPicker *)current;
@property (nonatomic, readonly) NSArray<NSDictionary *> *gifs;
- (void)search:(NSString *)query;
- (void)pickAtIndex:(NSUInteger)index;
- (void)close;
@end

/// chat.postMessage's attachment for a gif of the picker (zYJF): one image block.
NSDictionary *SNGifAttachment(NSDictionary *gif);

NS_ASSUME_NONNULL_END
