// A user's or workspace's picture as Slack draws it: a rounded square whose radius follows
// clamp(4, 22.222% of the size, 12), with an optional presence glyph cut into its bottom-right
// corner (components.json avatar_and_presence: notch centred at 88.9% with radius 20.8%).
#import <AppKit/AppKit.h>

#import "source/source.h"

#import "theme/theme.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SNAvatarPresence) {
    SNAvatarPresenceNone,
    SNAvatarPresenceActive,
    SNAvatarPresenceAway,
};

/// How Slack marks a person's picture: nothing for apps and bots (or no one), the green dot while
/// active, the away ring otherwise (also while their presence is not known yet).
SNAvatarPresence SNAvatarPresenceOfUser(SNUser *_Nullable user, id<SNSource> source);

@interface SNAvatarView : NSView
/// Held at the view's pixel size (render/images.h); nil shows the placeholder fill, and so does a
/// new URL until its picture arrives.
@property (nonatomic, nullable) NSURL *imageURL;
/// The picture shown now: the one for imageURL once it arrived.
@property (nonatomic, readonly, nullable) CGImageRef image;
@property (nonatomic) SNAvatarPresence presence;
/// Do Not Disturb: the presence glyph becomes an open ring with a 'z'.
@property (nonatomic) BOOL doNotDisturb;
/// Active is green (#3daa7c); away takes this colour, #ababad by default (the sidebar uses its
/// text colour).
@property (nonatomic) SNColorToken awayColor;
@property (nonatomic) SNColorToken placeholderColor;
@end

NS_ASSUME_NONNULL_END
