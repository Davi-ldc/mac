// UI text in the user's Slack language. Each module keeps its strings beside its code as
// <locale>.strings ("en.strings", "pt-BR.strings"), with keys prefixed by the module
// ("shell.search.placeholder"); the Makefile gathers them into the bundle.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Slack's locale for the user ("pt-BR"); English until set.
void SNSetLanguage(NSString *locale);
NSString *SNLanguage(void);
/// The key's text in the current language, else in English, else the key itself.
NSString *SNLocalized(NSString *key);
/// The localized format with %@ arguments filled in.
NSString *SNLocalizedFormat(NSString *key, ...);

NS_ASSUME_NONNULL_END
