// Owns reading rich_text and mrkdwn into sink calls.
#import "model/json.h"
#import "text/walk.h"

@implementation SNTextSink
- (void)beginBlock:(SNTextBlockKind)kind indent:(NSInteger)indent number:(NSInteger)number {}
- (void)appendText:(NSString *)text style:(SNInlineStyle)style {}
- (void)appendLink:(NSString *)url text:(NSString *)text style:(SNInlineStyle)style {}
- (void)appendUser:(NSString *)userID label:(NSString *)label {}
- (void)appendChannel:(NSString *)channelID label:(NSString *)label style:(SNInlineStyle)style {}
- (void)appendUsergroup:(NSString *)groupID label:(NSString *)label {}
- (void)appendBroadcast:(NSString *)range {}
- (void)appendEmoji:(NSString *)name unicode:(NSString *)unicode style:(SNInlineStyle)style {}
- (void)appendDate:(NSTimeInterval)timestamp format:(NSString *)format link:(NSString *)link fallback:(NSString *)fallback style:(SNInlineStyle)style {}
- (BOOL)knowsEmoji:(NSString *)name { return NO; }
@end

NSString *SNMrkdwnDecode(NSString *text) {
    if (![text containsString:@"&"]) return text;
    return [[[text stringByReplacingOccurrencesOfString:@"&lt;" withString:@"<"] stringByReplacingOccurrencesOfString:@"&gt;" withString:@">"]
        stringByReplacingOccurrencesOfString:@"&amp;"
                                  withString:@"&"];
}

NSString *SNTextFromCodePoints(NSString *codePoints) {
    NSMutableString *text = [NSMutableString new];
    for (NSString *part in [codePoints componentsSeparatedByString:@"-"]) {
        unsigned value = 0;
        if (![[NSScanner scannerWithString:part] scanHexInt:&value] || !value || value > 0x10FFFF) return nil;
        UTF32Char character = value;
        [text appendString:[[NSString alloc] initWithBytes:&character length:4 encoding:NSUTF32LittleEndianStringEncoding] ?: @""];
    }
    return text.length ? text : nil;
}

NSString *SNCodePointsOfText(NSString *text) {
    NSData *data = [text dataUsingEncoding:NSUTF32LittleEndianStringEncoding];
    const uint32_t *scalars = data.bytes;
    NSMutableArray *parts = [NSMutableArray new];
    for (NSUInteger i = 0; i < data.length / 4; i++) [parts addObject:[NSString stringWithFormat:@"%x", scalars[i]]];
    return [parts componentsJoinedByString:@"-"];
}

static BOOL IsSpace(unichar c) { return [NSCharacterSet.whitespaceAndNewlineCharacterSet characterIsMember:c]; }
static BOOL IsWordCharacter(unichar c) { return [NSCharacterSet.alphanumericCharacterSet characterIsMember:c]; }
static BOOL IsEmojiNameCharacter(unichar c) { return IsWordCharacter(c) || c == '_' || c == '-' || c == '+' || c == '\''; }

#pragma mark rich_text

static SNInlineStyle StyleOf(NSDictionary *element) {
    NSDictionary *style = SNJSONObject(element, @"style");
    return (SNJSONBool(style, @"bold") ? SNInlineBold : 0) | (SNJSONBool(style, @"italic") ? SNInlineItalic : 0) |
           (SNJSONBool(style, @"strike") ? SNInlineStrike : 0) | (SNJSONBool(style, @"code") ? SNInlineCode : 0) |
           (SNJSONBool(style, @"underline") ? SNInlineUnderline : 0);
}

void SNWalkRichInline(NSArray *elements, SNInlineStyle extra, SNTextSink *sink) {
    for (NSDictionary *element in elements) {
        if (![element isKindOfClass:NSDictionary.class]) continue;
        NSString *type = SNJSONString(element, @"type"), *text = SNJSONString(element, @"text");
        SNInlineStyle style = StyleOf(element) | extra;
        if ([type isEqualToString:@"text"]) {
            [sink appendText:text ?: @"" style:style];
        } else if ([type isEqualToString:@"link"]) {
            NSString *url = SNJSONString(element, @"url");
            if (url.length) [sink appendLink:url text:text.length ? text : nil style:style];
            else [sink appendText:text ?: @"" style:style];
        } else if ([type isEqualToString:@"emoji"]) {
            NSString *name = SNJSONString(element, @"name");
            if (!name.length) continue;
            // Tone 1 is no tone.
            NSInteger tone = SNJSONInteger(element, @"skin_tone");
            if (tone > 1 && ![name containsString:@"::skin-tone-"]) name = [NSString stringWithFormat:@"%@::skin-tone-%ld", name, (long)tone];
            [sink appendEmoji:name unicode:SNJSONString(element, @"unicode") style:style];
        } else if ([type isEqualToString:@"user"]) {
            NSString *userID = SNJSONString(element, @"user_id");
            if (userID) [sink appendUser:userID label:nil];
        } else if ([type isEqualToString:@"usergroup"]) {
            NSString *groupID = SNJSONString(element, @"usergroup_id");
            if (groupID) [sink appendUsergroup:groupID label:nil];
        } else if ([type isEqualToString:@"channel"]) {
            NSString *channelID = SNJSONString(element, @"channel_id");
            if (channelID) [sink appendChannel:channelID label:nil style:style];
        } else if ([type isEqualToString:@"broadcast"]) {
            [sink appendBroadcast:SNJSONString(element, @"range") ?: @"here"];
        } else if ([type isEqualToString:@"date"]) {
            [sink appendDate:SNJSONDouble(element, @"timestamp") format:SNJSONString(element, @"format") link:SNJSONString(element, @"url")
                    fallback:SNJSONString(element, @"fallback")
                       style:style];
        } else if ([type isEqualToString:@"color"]) {
            [sink appendText:SNJSONString(element, @"value") ?: @"" style:style];
        } else if (text) {
            [sink appendText:text style:style];
        }
    }
}

void SNWalkRichText(NSArray *elements, SNTextSink *sink) {
    for (NSDictionary *element in elements) {
        if (![element isKindOfClass:NSDictionary.class]) continue;
        NSString *type = SNJSONString(element, @"type");
        NSArray *children = SNJSONArray(element, @"elements") ?: @[];
        if ([type isEqualToString:@"rich_text_list"]) {
            NSInteger indent = MAX(0, SNJSONInteger(element, @"indent")), number = SNJSONInteger(element, @"offset");
            BOOL ordered = [SNJSONString(element, @"style") isEqualToString:@"ordered"];
            for (NSDictionary *item in children) {
                [sink beginBlock:SNTextListItem indent:indent number:ordered ? ++number : 0];
                SNWalkRichInline(SNJSONArray(item, @"elements") ?: @[], 0, sink);
            }
            continue;
        }
        SNTextBlockKind kind = [type isEqualToString:@"rich_text_section"]       ? SNTextSection
                               : [type isEqualToString:@"rich_text_quote"]        ? SNTextQuote
                               : [type isEqualToString:@"rich_text_preformatted"] ? SNTextCode
                                                                                  : -1;
        if (kind < 0) continue;
        [sink beginBlock:kind indent:0 number:0];
        SNWalkRichInline(children, 0, sink);
    }
}

void SNWalkRichTextBlocks(NSArray *blocks, SNTextSink *sink) {
    for (NSDictionary *block in blocks)
        if ([SNJSONString(block, @"type") isEqualToString:@"rich_text"]) SNWalkRichText(SNJSONArray(block, @"elements") ?: @[], sink);
}

#pragma mark mrkdwn

/// Bold, italic and strike markers open after a space or punctuation, before a non-space.
static BOOL OpensAt(NSString *text, NSUInteger i) {
    if (i + 1 >= text.length || IsSpace([text characterAtIndex:i + 1])) return NO;
    return i == 0 || !IsWordCharacter([text characterAtIndex:i - 1]);
}

/// The closing marker: after a non-space, before a space, punctuation or the end, on the same line.
/// Sets `*lineEnd` when no closing marker exists before the newline or end of text.
static NSUInteger ClosingMarker(NSString *text, NSUInteger open, unichar marker, NSUInteger *lineEnd) {
    NSUInteger length = text.length;
    for (NSUInteger j = open + 2; j < length; j++) {
        unichar c = [text characterAtIndex:j];
        if (c == '\n') {
            if (lineEnd) *lineEnd = j;
            return NSNotFound;
        }
        if (c != marker || IsSpace([text characterAtIndex:j - 1])) continue;
        if (j + 1 == length || !IsWordCharacter([text characterAtIndex:j + 1])) return j;
    }
    if (lineEnd) *lineEnd = length;
    return NSNotFound;
}

/// Where the entity opening at `open` closes: Slack escapes every other '<', so an entity is '<'
/// and a non-space, up to the first '>' with no '<' before it.
static NSUInteger EntityEnd(NSString *text, NSUInteger open) {
    if (open + 1 >= text.length || IsSpace([text characterAtIndex:open + 1])) return NSNotFound;
    for (NSUInteger j = open + 1; j < text.length; j++) {
        unichar c = [text characterAtIndex:j];
        if (c == '<') return NSNotFound;
        if (c == '>') return j > open + 1 ? j : NSNotFound;
    }
    return NSNotFound;
}

static void WalkEntity(NSString *entity, SNInlineStyle style, SNTextSink *sink) {
    NSRange bar = [entity rangeOfString:@"|"];
    NSString *value = bar.location == NSNotFound ? entity : [entity substringToIndex:bar.location];
    NSString *label = bar.location == NSNotFound ? nil : SNMrkdwnDecode([entity substringFromIndex:NSMaxRange(bar)]);
    if ([value hasPrefix:@"@"]) {
        [sink appendUser:[value substringFromIndex:1] label:label];
    } else if ([value hasPrefix:@"#"]) {
        [sink appendChannel:[value substringFromIndex:1] label:label style:style];
    } else if ([value hasPrefix:@"!subteam^"]) {
        [sink appendUsergroup:[value substringFromIndex:9] label:label];
    } else if ([value hasPrefix:@"!date^"]) {
        NSArray<NSString *> *parts = [[value substringFromIndex:6] componentsSeparatedByString:@"^"];
        [sink appendDate:parts.firstObject.doubleValue format:parts.count > 1 ? parts[1] : nil link:parts.count > 2 ? parts[2] : nil fallback:label style:style];
    } else if ([value isEqualToString:@"!here"] || [value isEqualToString:@"!channel"] || [value isEqualToString:@"!everyone"]) {
        [sink appendBroadcast:[value substringFromIndex:1]];
    } else if ([value hasPrefix:@"!"]) {
        [sink appendText:label ?: [value substringFromIndex:1] style:style];
    } else {
        [sink appendLink:SNMrkdwnDecode(value) text:label.length ? label : nil style:style];
    }
}

void SNWalkMrkdwnInline(NSString *source, SNInlineStyle style, SNTextSink *sink) {
    NSUInteger i = 0, length = source.length;
    __block NSUInteger plainStart = 0;
    // Remember when a marker has no closing match up to the next newline (or end of text for '`'),
    // preventing O(N^2) rescans on unclosed runs of '*', '_', '~', or '`'.
    NSUInteger noCloseUntil[3] = {0, 0, 0};
    BOOL noMoreBacktick = NO;
    void (^flush)(NSUInteger) = ^(NSUInteger end) {
        if (end > plainStart) [sink appendText:SNMrkdwnDecode([source substringWithRange:NSMakeRange(plainStart, end - plainStart)]) style:style];
    };
    while (i < length) {
        unichar c = [source characterAtIndex:i];
        if (c == '<') {
            NSUInteger close = EntityEnd(source, i);
            if (close != NSNotFound) {
                flush(i);
                WalkEntity([source substringWithRange:NSMakeRange(i + 1, close - i - 1)], style, sink);
                i = plainStart = close + 1;
                continue;
            }
        } else if (c == '`' && !(style & SNInlineCode) && !noMoreBacktick) {
            NSRange close = i + 1 < length ? [source rangeOfString:@"`" options:0 range:NSMakeRange(i + 1, length - i - 1)] : NSMakeRange(NSNotFound, 0);
            if (close.location == NSNotFound) {
                noMoreBacktick = YES;
            } else if (close.location > i + 1) {
                flush(i);
                [sink appendText:SNMrkdwnDecode([source substringWithRange:NSMakeRange(i + 1, close.location - i - 1)]) style:style | SNInlineCode];
                i = plainStart = NSMaxRange(close);
                continue;
            }
        } else if ((c == '*' || c == '_' || c == '~') && OpensAt(source, i)) {
            int slot = c == '*' ? 0 : c == '_' ? 1 : 2;
            if (i >= noCloseUntil[slot]) {
                NSUInteger lineEnd = 0;
                NSUInteger close = ClosingMarker(source, i, c, &lineEnd);
                if (close != NSNotFound) {
                    flush(i);
                    SNInlineStyle added = c == '*' ? SNInlineBold : c == '_' ? SNInlineItalic : SNInlineStrike;
                    SNWalkMrkdwnInline([source substringWithRange:NSMakeRange(i + 1, close - i - 1)], style | added, sink);
                    i = plainStart = close + 1;
                    continue;
                }
                noCloseUntil[slot] = lineEnd;
            }
        } else if (c == ':') {
            NSUInteger j = i + 1;
            while (j < length && j - i < 100 && IsEmojiNameCharacter([source characterAtIndex:j])) j++;
            // "thumbsup::skin-tone-2" continues past the first closing colon.
            if (j + 11 < length && [[source substringWithRange:NSMakeRange(j, 12)] isEqualToString:@"::skin-tone-"]) {
                j += 12;
                while (j < length && IsEmojiNameCharacter([source characterAtIndex:j])) j++;
            }
            if (j < length && j > i + 1 && [source characterAtIndex:j] == ':') {
                NSString *name = [source substringWithRange:NSMakeRange(i + 1, j - i - 1)];
                if ([sink knowsEmoji:name]) {
                    flush(i);
                    [sink appendEmoji:name unicode:nil style:style];
                    i = plainStart = j + 1;
                    continue;
                }
            }
        }
        i++;
    }
    flush(length);
}

void SNWalkMrkdwn(NSString *source, SNInlineStyle style, SNTextSink *sink) {
    NSMutableArray<NSString *> *fenced = [[source componentsSeparatedByString:@"```"] mutableCopy];
    // An unclosed fence stays text.
    if (fenced.count % 2 == 0) {
        NSString *rest = fenced.lastObject;
        [fenced removeLastObject];
        fenced[fenced.count - 1] = [NSString stringWithFormat:@"%@```%@", fenced.lastObject, rest];
    }
    for (NSUInteger part = 0; part < fenced.count; part++) {
        NSString *chunk = fenced[part];
        if (part > 0 && [chunk hasPrefix:@"\n"]) chunk = [chunk substringFromIndex:1];
        if (part + 1 < fenced.count && [chunk hasSuffix:@"\n"]) chunk = [chunk substringToIndex:chunk.length - 1];
        // Odd parts sit between fences.
        if (part % 2 == 1) {
            [sink beginBlock:SNTextCode indent:0 number:0];
            [sink appendText:SNMrkdwnDecode(chunk) style:0];
            continue;
        }
        NSMutableArray<NSString *> *plain = [NSMutableArray new], *quoted = [NSMutableArray new];
        void (^flushPlain)(void) = ^{
            NSString *joined = [plain componentsJoinedByString:@"\n"];
            if ([joined stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet].length) {
                [sink beginBlock:SNTextSection indent:0 number:0];
                SNWalkMrkdwnInline(joined, style, sink);
            }
            [plain removeAllObjects];
        };
        void (^flushQuote)(void) = ^{
            if (quoted.count) {
                [sink beginBlock:SNTextQuote indent:0 number:0];
                SNWalkMrkdwnInline([quoted componentsJoinedByString:@"\n"], style, sink);
            }
            [quoted removeAllObjects];
        };
        for (NSString *line in [chunk componentsSeparatedByString:@"\n"]) {
            NSString *quote = [line hasPrefix:@"&gt;"] ? [line substringFromIndex:4] : [line hasPrefix:@">"] ? [line substringFromIndex:1] : nil;
            if (quote) {
                flushPlain();
                [quoted addObject:[quote hasPrefix:@" "] ? [quote substringFromIndex:1] : quote];
            } else {
                flushQuote();
                [plain addObject:line];
            }
        }
        flushQuote();
        flushPlain();
    }
}
