// Slack's time zones as its client offers and saves them (users.prefs "tz"): a list of its own,
// labelled per locale, and the one of them it saves for the zone it detects.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The Preferences choices for `locale` ("pt-BR", "en-GB"; any other gets the client's English
/// list): @[label, tz] pairs in the client's order, @[@"(UTC-03:00) Brasília", @"America/Sao_Paulo"].
NSArray<NSArray<NSString *> *> *SNTimeZoneChoices(NSString *_Nullable locale);
/// The tz the client saves for `zone` (the Mac's): the zone itself when listed, else the listed
/// one its tables give, else the first listed zone keeping the same time now and in six months;
/// nil when none does.
NSString *_Nullable SNTimeZoneChoiceForZone(NSTimeZone *zone);

NS_ASSUME_NONNULL_END
