// Owns loading and looking up the bundled strings tables.
#import "render/strings.h"

static NSString *language = @"en";
static NSDictionary<NSString *, NSString *> *current, *english;

/// Every module's table for the locale, merged; nil when the bundle has none for it.
static NSDictionary *Tables(NSString *locale) {
    NSURL *folder = [NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:[@"strings" stringByAppendingPathComponent:locale]];
    NSArray<NSURL *> *files = [NSFileManager.defaultManager contentsOfDirectoryAtURL:folder includingPropertiesForKeys:nil options:0 error:nil];
    if (!files.count) return nil;
    NSMutableDictionary *merged = [NSMutableDictionary new];
    for (NSURL *file in files) {
        NSDictionary *table = [NSDictionary dictionaryWithContentsOfURL:file];
        if (table) [merged addEntriesFromDictionary:table];
    }
    return merged;
}

static NSDictionary<NSString *, NSString *> *EnglishTables(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ english = Tables(@"en") ?: @{}; });
    return english;
}

void SNSetLanguage(NSString *locale) {
    NSString *base = [locale componentsSeparatedByString:@"-"].firstObject;
    if ([locale isEqualToString:@"en"] || ([locale hasPrefix:@"en-"] && !Tables(locale))) {
        language = @"en";
        current = EnglishTables();
        return;
    }
    if ([locale isEqualToString:language] && current) return;
    NSDictionary *table = Tables(locale);
    // Slack's "pt-BR" may only exist as "pt", and the reverse.
    if (!table && base) {
        if ([base isEqualToString:@"en"]) {
            language = @"en";
            current = EnglishTables();
            return;
        }
        table = Tables(base);
        locale = base;
    }
    language = table ? locale : @"en";
    current = table ?: EnglishTables();
}

NSString *SNLanguage(void) { return language; }

NSString *SNLocalized(NSString *key) {
    return current[key] ?: EnglishTables()[key] ?: key;
}

NSString *SNLocalizedFormat(NSString *key, ...) {
    va_list arguments;
    va_start(arguments, key);
    NSString *text = [[NSString alloc] initWithFormat:SNLocalized(key) arguments:arguments];
    va_end(arguments);
    return text;
}
