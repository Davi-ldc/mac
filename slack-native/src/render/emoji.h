// Emoji by Slack name: the standard set (iamcal/emoji-data, generated into emojidata.m by
// emojidata.py) and the workspace's custom emoji. A name has no colons; a skin tone is a suffix,
// "thumbsup::skin-tone-2" (2 lightest to 6 darkest), as reactions and rich_text name them.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The picker's sections, in its order.
typedef NS_ENUM(NSInteger, SNEmojiCategory) {
    SNEmojiCategorySmileys,
    SNEmojiCategoryPeople,
    SNEmojiCategoryNature,
    SNEmojiCategoryFood,
    SNEmojiCategoryTravel,
    SNEmojiCategoryActivities,
    SNEmojiCategoryObjects,
    SNEmojiCategorySymbols,
    SNEmojiCategoryFlags,
    /// The skin tone swatches themselves; not a picker section.
    SNEmojiCategoryComponent,
};

/// A standard emoji. Instances are shared: the same name always gives the same object.
@interface SNEmoji : NSObject
/// Slack's primary short name ("+1").
@property (nonatomic, readonly) NSString *name;
/// Every short name, the primary one first ("+1", "thumbsup").
@property (nonatomic, readonly) NSArray<NSString *> *names;
/// The emoji's text without a skin tone.
@property (nonatomic, readonly) NSString *unicode;
@property (nonatomic, readonly) SNEmojiCategory category;
@property (nonatomic, readonly) BOOL hasSkinTones;
/// The text with skin tone 2-6; 0 or 1, or an emoji without tones, gives `unicode`.
- (NSString *)unicodeWithSkinTone:(NSInteger)tone;
@end

/// The standard emoji a name (with or without a skin tone suffix) refers to.
SNEmoji *_Nullable SNEmojiNamed(NSString *name);
/// The text of a standard emoji name (or a custom alias of one), with its skin tone applied; nil
/// for unknown names and custom images.
NSString *_Nullable SNEmojiUnicode(NSString *name);
/// "thumbsup::skin-tone-3" -> "thumbsup" and 3; a name without a tone gives itself and 0.
NSString *SNEmojiBaseName(NSString *name);
NSInteger SNEmojiSkinTone(NSString *name);
/// A category's emoji in picker order.
NSArray<SNEmoji *> *SNEmojiInCategory(SNEmojiCategory category);
/// Emoji with a name starting with `query`, then those containing it, in picker order; at most
/// `limit` (0 for all).
NSArray<SNEmoji *> *SNEmojiMatching(NSString *query, NSUInteger limit);

/// The workspace's custom emoji, as emoji.list's "emoji" object: name -> image URL or
/// "alias:<other name>". The core calls it after emoji.list and on emoji_changed.
void SNSetCustomEmoji(NSDictionary<NSString *, NSString *> *emoji);
/// A custom emoji's image, following alias chains; nil for standard and unknown names and for
/// aliases of standard emoji.
NSURL *_Nullable SNCustomEmojiURL(NSString *name);
/// Custom names (aliases included), sorted.
NSArray<NSString *> *SNCustomEmojiNames(void);
/// Posted on the main thread after SNSetCustomEmoji.
extern NSNotificationName const SNCustomEmojiDidChangeNotification;

NS_ASSUME_NONNULL_END
