// The generated time zone tables (timezonedata.m, from the official client's TimezoneDetector);
// read through model/timezone.h, not directly.
#import <Foundation/Foundation.h>

typedef struct {
    /// "(UTC-03:00) Brasília".
    const char *label;
    const char *zone;
} SNTimeZoneEntry;

typedef struct {
    /// NULL for the client's default (English) list.
    const char *locale;
    const SNTimeZoneEntry *entries;
    NSUInteger count;
} SNTimeZoneList;

typedef struct {
    /// A zone the lists leave out, and the listed one the client saves for it.
    const char *zone;
    const char *choice;
} SNTimeZoneAlias;

/// The default list first; every list offers the same zones, each in its locale's order.
extern const SNTimeZoneList SNTimeZoneLists[];
extern const NSUInteger SNTimeZoneListCount;
/// In the order the client looks them up (its manual, equivalent and fallback tables).
extern const SNTimeZoneAlias SNTimeZoneAliases[];
extern const NSUInteger SNTimeZoneAliasCount;
