// Owns reading the generated time zone tables (model/timezonedata.m).
#import "model/timezone.h"
#import "model/timezonedata.h"

NSArray<NSArray<NSString *> *> *SNTimeZoneChoices(NSString *locale) {
    const SNTimeZoneList *list = &SNTimeZoneLists[0];
    for (NSUInteger i = 1; i < SNTimeZoneListCount; i++)
        if (locale && strcmp(SNTimeZoneLists[i].locale, locale.UTF8String) == 0) list = &SNTimeZoneLists[i];
    NSMutableArray *choices = [NSMutableArray arrayWithCapacity:list->count];
    for (NSUInteger i = 0; i < list->count; i++) [choices addObject:@[ @(list->entries[i].label), @(list->entries[i].zone) ]];
    return choices;
}

NSString *SNTimeZoneChoiceForZone(NSTimeZone *zone) {
    const SNTimeZoneList *list = &SNTimeZoneLists[0];
    const char *name = zone.name.UTF8String;
    for (NSUInteger i = 0; i < list->count; i++)
        if (strcmp(list->entries[i].zone, name) == 0) return zone.name;
    for (NSUInteger i = 0; i < SNTimeZoneAliasCount; i++)
        if (strcmp(SNTimeZoneAliases[i].zone, name) == 0) return @(SNTimeZoneAliases[i].choice);
    // Zones newer than the client's tables (America/Nuuk); the client falls back on probing
    // offsets, as this does.
    NSDate *now = NSDate.date, *later = [now dateByAddingTimeInterval:183 * 86400];
    for (NSUInteger i = 0; i < list->count; i++) {
        NSTimeZone *candidate = [NSTimeZone timeZoneWithName:@(list->entries[i].zone)];
        if (candidate && [candidate secondsFromGMTForDate:now] == [zone secondsFromGMTForDate:now] &&
            [candidate secondsFromGMTForDate:later] == [zone secondsFromGMTForDate:later])
            return @(list->entries[i].zone);
    }
    return nil;
}
