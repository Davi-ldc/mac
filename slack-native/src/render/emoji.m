// Owns looking up standard emoji in the generated table and the workspace's custom emoji.
#import "render/emoji.h"
#import "render/emojidata.h"

NSNotificationName const SNCustomEmojiDidChangeNotification = @"SNCustomEmojiDidChangeNotification";

@interface SNEmoji ()
- (instancetype)initWithEntry:(const SNEmojiEntry *)entry;
@end

@implementation SNEmoji {
    const SNEmojiEntry *_entry;
    NSArray<NSString *> *_skins;
}

- (instancetype)initWithEntry:(const SNEmojiEntry *)entry {
    if (!(self = [super init])) return nil;
    _entry = entry;
    _names = [@(entry->names) componentsSeparatedByString:@" "];
    _name = _names.firstObject;
    _unicode = @(entry->unicode);
    _category = (SNEmojiCategory)entry->category;
    return self;
}

- (BOOL)hasSkinTones { return _entry->skins != NULL; }

- (NSString *)unicodeWithSkinTone:(NSInteger)tone {
    if (tone < 2 || tone > 6 || !_entry->skins) return self.unicode;
    if (!_skins) _skins = [@(_entry->skins) componentsSeparatedByString:@"|"];
    return _skins[(NSUInteger)tone - 2];
}

@end

/// Emoji objects are made on first use and kept: the picker and every message share them.
static SNEmoji *EmojiAtIndex(NSUInteger index) {
    static NSMutableDictionary<NSNumber *, SNEmoji *> *made;
    if (!made) made = [NSMutableDictionary new];
    SNEmoji *emoji = made[@(index)];
    if (!emoji) {
        emoji = [[SNEmoji alloc] initWithEntry:&SNEmojiTable[index]];
        made[@(index)] = emoji;
    }
    return emoji;
}

static int CompareName(const void *key, const void *element) { return strcmp(key, ((const SNEmojiNameEntry *)element)->name); }

static NSString *const kSkinSuffix = @"::skin-tone-";

NSString *SNEmojiBaseName(NSString *name) {
    NSRange suffix = [name rangeOfString:kSkinSuffix];
    return suffix.location == NSNotFound ? name : [name substringToIndex:suffix.location];
}

NSInteger SNEmojiSkinTone(NSString *name) {
    NSRange suffix = [name rangeOfString:kSkinSuffix];
    // "skin-tone-2-4" (two people) takes the first tone.
    return suffix.location == NSNotFound ? 0 : [name substringFromIndex:NSMaxRange(suffix)].integerValue;
}

SNEmoji *SNEmojiNamed(NSString *name) {
    const SNEmojiNameEntry *found = bsearch(SNEmojiBaseName(name).UTF8String, SNEmojiNameTable, SNEmojiNameTableCount,
                                            sizeof *SNEmojiNameTable, CompareName);
    return found ? EmojiAtIndex(found->index) : nil;
}

static NSDictionary<NSString *, NSString *> *custom;
/// Sorted once per emoji.list: autocomplete and the picker ask on every keystroke.
static NSArray<NSString *> *customNames;

/// Where a custom name's alias chain ends: a URL string or a name that is not custom.
static NSString *ResolveCustom(NSString *name) {
    NSString *value = name;
    for (int hops = 0; hops < 8; hops++) {
        NSString *next = custom[value];
        if (!next) return value;
        if (![next hasPrefix:@"alias:"]) return next;
        value = [next substringFromIndex:6];
    }
    return nil;
}

NSString *SNEmojiUnicode(NSString *name) {
    SNEmoji *emoji = SNEmojiNamed(name);
    if (!emoji && custom[SNEmojiBaseName(name)]) {
        NSString *target = ResolveCustom(SNEmojiBaseName(name));
        emoji = target && ![target containsString:@"/"] ? SNEmojiNamed(target) : nil;
    }
    return [emoji unicodeWithSkinTone:SNEmojiSkinTone(name)];
}

NSArray<SNEmoji *> *SNEmojiInCategory(SNEmojiCategory category) {
    NSMutableArray *list = [NSMutableArray new];
    for (NSUInteger i = 0; i < SNEmojiTableCount; i++)
        if (SNEmojiTable[i].category == category) [list addObject:EmojiAtIndex(i)];
    return list;
}

NSArray<SNEmoji *> *SNEmojiMatching(NSString *query, NSUInteger limit) {
    const char *needle = query.lowercaseString.UTF8String;
    if (!needle || !*needle) return @[];
    NSMutableArray *prefixed = [NSMutableArray new], *containing = [NSMutableArray new];
    for (NSUInteger i = 0; i < SNEmojiTableCount; i++) {
        if (SNEmojiTable[i].category == SNEmojiCategoryComponent) continue;
        const char *names = SNEmojiTable[i].names;
        const char *hit = strstr(names, needle);
        if (!hit) continue;
        // A prefix of any of the names (they are separated by spaces).
        BOOL prefix = NO;
        for (const char *at = hit; at && !prefix; at = strstr(at + 1, needle)) prefix = at == names || at[-1] == ' ';
        [prefix ? prefixed : containing addObject:EmojiAtIndex(i)];
    }
    [prefixed addObjectsFromArray:containing];
    return limit && prefixed.count > limit ? [prefixed subarrayWithRange:NSMakeRange(0, limit)] : prefixed;
}

void SNSetCustomEmoji(NSDictionary<NSString *, NSString *> *emoji) {
    custom = [emoji copy];
    customNames = nil;
    [NSNotificationCenter.defaultCenter postNotificationName:SNCustomEmojiDidChangeNotification object:nil];
}

NSURL *SNCustomEmojiURL(NSString *name) {
    NSString *target = custom[SNEmojiBaseName(name)] ? ResolveCustom(SNEmojiBaseName(name)) : nil;
    if (![target hasPrefix:@"http"]) return nil;
    return [NSURL URLWithString:target];
}

NSArray<NSString *> *SNCustomEmojiNames(void) {
    if (!customNames && custom.count) customNames = [custom.allKeys sortedArrayUsingSelector:@selector(compare:)];
    return customNames ?: @[];
}
