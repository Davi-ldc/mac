// Safe JSON extraction, Spotify URI/GID conversion, image selection, and release date formatting.
#import "model/json.h"

#import <string.h>
#import <time.h>

NSDictionary *SPJSONDict(id value) {
    return [value isKindOfClass:NSDictionary.class] ? (NSDictionary *)value : nil;
}

NSArray *SPJSONArray(id value) {
    return [value isKindOfClass:NSArray.class] ? (NSArray *)value : nil;
}

NSString *SPJSONString(id value) {
    return [value isKindOfClass:NSString.class] ? (NSString *)value : nil;
}

NSNumber *SPJSONNumber(id value) {
    return [value isKindOfClass:NSNumber.class] ? (NSNumber *)value : nil;
}

NSInteger SPJSONInt(id value, NSInteger fallback) {
    NSNumber *n = SPJSONNumber(value);
    return n ? n.integerValue : fallback;
}

int64_t SPJSONInt64(id value, int64_t fallback) {
    NSNumber *n = SPJSONNumber(value);
    return n ? n.longLongValue : fallback;
}

double SPJSONDouble(id value, double fallback) {
    NSNumber *n = SPJSONNumber(value);
    return n ? n.doubleValue : fallback;
}

BOOL SPJSONBool(id value, BOOL fallback) {
    NSNumber *n = SPJSONNumber(value);
    return n ? n.boolValue : fallback;
}

double SPParseISO8601Timestamp(NSString *isoString) {
    if (isoString.length < 19) return 0.0;
    const char *s = isoString.UTF8String;
    if (!s) return 0.0;
    int y = 0, mo = 0, d = 0, h = 0, mi = 0, sec = 0;
    if (sscanf(s, "%4d-%2d-%2dT%2d:%2d:%2d", &y, &mo, &d, &h, &mi, &sec) != 6) return 0.0;
    struct tm t;
    memset(&t, 0, sizeof(t));
    t.tm_year = y - 1900;
    t.tm_mon = mo - 1;
    t.tm_mday = d;
    t.tm_hour = h;
    t.tm_min = mi;
    t.tm_sec = sec;
    time_t epoch = timegm(&t);
    return epoch > 0 ? (double)epoch : 0.0;
}

NSString *SPURIIDFromURI(NSString *uri) {
    if (!uri.length) return nil;
    NSArray<NSString *> *parts = [uri componentsSeparatedByString:@":"];
    if (parts.count < 3 || ![parts[0] isEqualToString:@"spotify"]) return nil;
    NSString *last = parts.lastObject;
    return last.length ? last : nil;
}

NSString *SPURIIDFromURIOfKind(NSString *uri, NSString *kind) {
    if (!uri.length || !kind.length) return nil;
    NSArray<NSString *> *parts = [uri componentsSeparatedByString:@":"];
    if (parts.count != 3) return nil;
    if (![parts[0] isEqualToString:@"spotify"] || ![parts[1] isEqualToString:kind]) return nil;
    return parts[2].length ? parts[2] : nil;
}

NSString *SPURITrackIDFromString(NSString *uriOrLink) {
    if (!uriOrLink.length) return nil;
    NSString *trimmed = [uriOrLink stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([trimmed hasPrefix:@"spotify:track:"]) {
        NSString *rest = [trimmed substringFromIndex:@"spotify:track:".length];
        return rest.length ? rest : nil;
    }
    NSRange r = [trimmed rangeOfString:@"open.spotify.com/track/"];
    if (r.location == NSNotFound) return nil;
    NSString *after = [trimmed substringFromIndex:NSMaxRange(r)];
    NSCharacterSet *stops = [NSCharacterSet characterSetWithCharactersInString:@"?/#"];
    NSRange stop = [after rangeOfCharacterFromSet:stops];
    NSString *trackID = stop.location == NSNotFound ? after : [after substringToIndex:stop.location];
    return trackID.length ? trackID : nil;
}

NSString *SPURIWebURL(NSString *uri) {
    if (!uri.length) return nil;
    NSArray<NSString *> *parts = [uri componentsSeparatedByString:@":"];
    if (parts.count != 3 || ![parts[0] isEqualToString:@"spotify"] || !parts[2].length) return nil;
    static NSSet<NSString *> *pagedKinds;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        pagedKinds = [NSSet setWithArray:@[ @"track", @"album", @"artist", @"playlist", @"show", @"episode", @"user" ]];
    });
    if (![pagedKinds containsObject:parts[1]]) return nil;
    return [NSString stringWithFormat:@"https://open.spotify.com/%@/%@", parts[1], parts[2]];
}

static const char kBase62Alphabet[] = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";

NSString *SPBase62ToHexGID(NSString *base62ID) {
    if (!base62ID.length || base62ID.length > 22) return nil;
    uint8_t bytes[16] = {0};
    for (NSUInteger i = 0; i < base62ID.length; i++) {
        unichar ch = [base62ID characterAtIndex:i];
        if (ch > 127) return nil;
        const char *p = strchr(kBase62Alphabet, (int)ch);
        if (!p) return nil;
        int carry = (int)(p - kBase62Alphabet);
        for (int j = 15; j >= 0; j--) {
            int val = (int)bytes[j] * 62 + carry;
            bytes[j] = (uint8_t)(val & 0xFF);
            carry = val >> 8;
        }
        if (carry != 0) return nil;
    }
    char out[33];
    static const char hex[] = "0123456789abcdef";
    for (int j = 0; j < 16; j++) {
        out[j * 2] = hex[(bytes[j] >> 4) & 0xF];
        out[j * 2 + 1] = hex[bytes[j] & 0xF];
    }
    out[32] = '\0';
    return [[NSString alloc] initWithBytes:out length:32 encoding:NSASCIIStringEncoding];
}

static int HexNibble(unichar ch) {
    if (ch >= '0' && ch <= '9') return ch - '0';
    if (ch >= 'a' && ch <= 'f') return ch - 'a' + 10;
    if (ch >= 'A' && ch <= 'F') return ch - 'A' + 10;
    return -1;
}

NSString *SPHexGIDToBase62(NSString *hexGID) {
    if (hexGID.length != 32) return nil;
    uint8_t bytes[16];
    for (NSUInteger i = 0; i < 16; i++) {
        int hi = HexNibble([hexGID characterAtIndex:i * 2]);
        int lo = HexNibble([hexGID characterAtIndex:i * 2 + 1]);
        if (hi < 0 || lo < 0) return nil;
        bytes[i] = (uint8_t)((hi << 4) | lo);
    }
    char digits[32];
    int count = 0;
    for (;;) {
        BOOL nonZero = NO;
        for (int i = 0; i < 16; i++) {
            if (bytes[i] != 0) { nonZero = YES; break; }
        }
        if (!nonZero) break;
        int rem = 0;
        for (int i = 0; i < 16; i++) {
            int acc = (rem << 8) | (int)bytes[i];
            bytes[i] = (uint8_t)(acc / 62);
            rem = acc % 62;
        }
        if (count >= 22) return nil;
        digits[count++] = kBase62Alphabet[rem];
    }
    while (count < 22) digits[count++] = '0';
    char out[23];
    for (int i = 0; i < count; i++) out[i] = digits[count - 1 - i];
    out[count] = '\0';
    return [[NSString alloc] initWithBytes:out length:(NSUInteger)count encoding:NSASCIIStringEncoding];
}

void SPExtractPathfinderImages(NSDictionary *imageDict,
                               NSString **outLargeURL,
                               NSString **outSmallURL) {
    NSArray *sources = SPJSONArray(imageDict[@"sources"]);
    NSString *largeURL = nil;
    NSString *smallURL = nil;
    NSInteger largeSize = -1;
    NSInteger smallSize = NSIntegerMax;

    for (id item in sources) {
        NSDictionary *src = SPJSONDict(item);
        NSString *url = SPJSONString(src[@"url"]);
        if (!url.length) continue;
        NSInteger w = SPJSONInt(src[@"width"], SPJSONInt(src[@"maxWidth"], 0));
        NSInteger h = SPJSONInt(src[@"height"], SPJSONInt(src[@"maxHeight"], 0));
        NSInteger sz = w > 0 ? w : h;
        if (sz >= largeSize) {
            largeSize = sz;
            largeURL = url;
        }
        if ((sz > 0 && sz < smallSize) || !smallURL) {
            if (sz > 0) smallSize = sz;
            smallURL = url;
        }
    }
    if (outLargeURL) *outLargeURL = largeURL;
    if (outSmallURL) *outSmallURL = smallURL ?: largeURL;
}

void SPExtractSpclientImages(NSArray *images,
                             NSString **outLargeURL,
                             NSString **outSmallURL) {
    NSString *largeURL = nil;
    NSString *smallURL = nil;
    NSInteger largeSize = -1;
    NSInteger smallSize = NSIntegerMax;

    for (id item in images) {
        NSDictionary *img = SPJSONDict(item);
        NSString *fileID = SPJSONString(img[@"file_id"]);
        if (!fileID.length) continue;
        NSString *url = [NSString stringWithFormat:@"https://i.scdn.co/image/%@", fileID];
        NSInteger w = SPJSONInt(img[@"width"], 0);
        NSInteger h = SPJSONInt(img[@"height"], 0);
        NSInteger sz = w > 0 ? w : h;
        if (sz >= largeSize) {
            largeSize = sz;
            largeURL = url;
        }
        if ((sz > 0 && sz < smallSize) || !smallURL) {
            if (sz > 0) smallSize = sz;
            smallURL = url;
        }
    }
    if (outLargeURL) *outLargeURL = largeURL;
    if (outSmallURL) *outSmallURL = smallURL ?: largeURL;
}

NSString *SPFormatPathfinderReleaseDate(NSDictionary *dateDict) {
    if (!dateDict) return nil;
    NSString *iso = SPJSONString(dateDict[@"isoString"]);
    NSNumber *yearNum = SPJSONNumber(dateDict[@"year"]);
    NSNumber *monthNum = SPJSONNumber(dateDict[@"month"]);
    NSNumber *dayNum = SPJSONNumber(dateDict[@"day"]);
    NSString *precision = SPJSONString(dateDict[@"precision"]);

    NSString *fullDay = nil;
    if (iso.length) {
        NSRange tRange = [iso rangeOfString:@"T"];
        fullDay = tRange.location == NSNotFound ? iso : [iso substringToIndex:tRange.location];
    } else if (yearNum && monthNum && dayNum) {
        fullDay = [NSString stringWithFormat:@"%04ld-%02ld-%02ld",
                   (long)yearNum.integerValue, (long)monthNum.integerValue, (long)dayNum.integerValue];
    }

    if (!fullDay.length) {
        return yearNum ? [NSString stringWithFormat:@"%ld", (long)yearNum.integerValue] : nil;
    }
    if ([precision isEqualToString:@"YEAR"] && fullDay.length >= 4) {
        return [fullDay substringToIndex:4];
    }
    if ([precision isEqualToString:@"MONTH"] && fullDay.length >= 7) {
        return [fullDay substringToIndex:7];
    }
    return fullDay;
}

NSString *SPNormalizePlaylistDescription(NSString *raw) {
    if (!raw.length) return nil;
    NSString *trimmed = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!trimmed.length || [trimmed isEqualToString:@"null"]) return nil;
    return trimmed;
}
