// The workspace menu (effects.txt [A12], measured on the live capture): a 320 pt menu with the
// workspace's icon, name and domain, the plan note, the AI upsell, then "Convidar pessoas...",
// "Preferências", "Ferramentas e configurações", "Baixar o app..." and "Sair" in groups between
// 1 pt lines. Rows highlight #0a77a7 under the pointer or the arrow keys, like SNMenu's; it opens
// and closes in one frame. The rail's workspace tile opens it; the sidebar's title may too.
#import <AppKit/AppKit.h>

#import "source/source.h"
#import "ui/kit/overlay.h"

NS_ASSUME_NONNULL_BEGIN

@interface SNWorkspaceMenu : NSView
/// Shows the menu on the `placement` side of `rect` (in `view`'s coordinates).
+ (instancetype)showForRect:(NSRect)rect inView:(NSView *)view placement:(SNPlacement)placement source:(id<SNSource>)source;
/// The selectable rows' titles, top to bottom (tests).
@property (nonatomic, readonly) NSArray<NSString *> *itemTitles;
/// The highlighted row's index among itemTitles, or NSNotFound.
@property (nonatomic) NSUInteger highlightedIndex;
- (void)close;
@end

NS_ASSUME_NONNULL_END
