// The generated standard emoji table (emojidata.m, from iamcal/emoji-data); read through
// render/emoji.h, not directly.
#import <Foundation/Foundation.h>

typedef struct {
    /// Slack's short names separated by spaces, the primary one first.
    const char *names;
    /// The emoji as UTF-8 text.
    const char *unicode;
    /// The five skin tones (skin-tone-2 to -6) as UTF-8 separated by '|', or NULL.
    const char *skins;
    /// SNEmojiCategory.
    uint8_t category;
} SNEmojiEntry;

typedef struct {
    const char *name;
    uint16_t index;
} SNEmojiNameEntry;

/// In picker order: by category, then emoji-data's sort order.
extern const SNEmojiEntry SNEmojiTable[];
extern const NSUInteger SNEmojiTableCount;
/// Every short name with its entry, sorted by strcmp for binary search.
extern const SNEmojiNameEntry SNEmojiNameTable[];
extern const NSUInteger SNEmojiNameTableCount;
