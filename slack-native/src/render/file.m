// Owns what a message's file shows as and a snippet's preview.
#import <CoreText/CoreText.h>

#import "render/file.h"
#import "render/strings.h"
#import "theme/theme.h"

/// Slack's fileIsHosted: its bytes are on Slack (Salesforce files count).
static BOOL Hosted(SNFile *file) { return !file.isExternal || [file.externalType isEqualToString:@"salesforce"]; }

static BOOL Matches(NSString *_Nullable value, NSArray<NSString *> *values) { return value && [values containsObject:value]; }

BOOL SNFileIsAudioClip(SNFile *file) { return Matches(file.subtype, @[ @"slack_audio", @"audio_story", @"slack_name_pronunciation" ]); }

/// The client's fileIsPlayableVideo and fileIsPlayableAudio, then snippets and documents with a
/// first page; anything else is a card.
SNFileStyle SNFileStyleOf(SNFile *file) {
    if ([file.mode isEqualToString:@"tombstone"]) return SNFileStyleCard;
    NSString *mime = file.mimeType ?: @"", *type = file.fileType.lowercaseString;
    if ([mime hasPrefix:@"image/"] && (file.thumbnailURLs.count || file.localURL)) return SNFileStyleImage;
    BOOL audioClip = SNFileIsAudioClip(file), videoClip = Matches(file.subtype, @[ @"slack_video", @"video_story" ]);
    if (!audioClip && (videoClip || (Hosted(file) && (Matches(type, @[ @"mp4", @"mov", @"webm" ]) || ([mime hasPrefix:@"video"] && file.mp4URL)))))
        return SNFileStyleVideo;
    if (Hosted(file) && (Matches(type, @[ @"m4a", @"mp3", @"wav" ]) || [file.subtype isEqualToString:@"audio_story"])) return SNFileStyleAudio;
    // Hosted text files carry previews too, but only snippets show them.
    if ([file.mode isEqualToString:@"snippet"]) return SNFileStyleSnippet;
    if (file.pdfThumbnailURL) return SNFileStyleDocument;
    return SNFileStyleCard;
}

/// getFileTypeDescription: the server's pretty_type, Google's own names for Drive files.
NSString *SNFileDescription(SNFile *file) {
    NSString *pretty = file.prettyType.length ? file.prettyType : nil;
    if (file.isExternal && [file.externalType isEqualToString:@"gdrive"]) {
        NSDictionary *google = @{@"gsheet" : @"render.file.gsheet", @"gdoc" : @"render.file.gdoc", @"gpres" : @"render.file.gpres", @"gdraw" : @"render.file.gdraw"};
        NSString *key = google[file.fileType ?: @""];
        if (key) return SNLocalized(key);
        return pretty ? [NSString stringWithFormat:SNLocalized(@"render.file.google"), pretty] : SNLocalized(@"render.file.generic");
    }
    if ([pretty isEqualToString:@"WebM"]) return SNLocalized(@"render.file.clip");
    return pretty ?: SNLocalized(@"render.file.generic");
}

NSString *SNFormatDuration(NSTimeInterval seconds) {
    long total = (long)floor(MAX(0, seconds));
    long hours = total / 3600, minutes = total / 60 % 60, rest = total % 60;
    return hours ? [NSString stringWithFormat:@"%ld:%02ld:%02ld", hours, minutes, rest] : [NSString stringWithFormat:@"%ld:%02ld", minutes, rest];
}

#pragma mark - Snippet preview

/// The code's type: Roboto Mono 13 on 19.5 pt lines (CodeMirror-code in the snippet card).
static const CGFloat kCodeSize = 13;

/// Roboto Mono has no italic face; browsers slant the upright one, as this does.
static NSFont *MonoFont(BOOL italic, BOOL bold) {
    NSFont *font = SNMonoFont(kCodeSize, bold ? SNFontWeightBold : SNFontWeightRegular);
    if (!italic) return font;
    static NSMutableDictionary<NSNumber *, NSFont *> *slanted;
    if (!slanted) slanted = [NSMutableDictionary new];
    NSFont *cached = slanted[@(bold)];
    if (cached) return cached;
    CGAffineTransform skew = CGAffineTransformMake(1, 0, 0.25, 1, 0, 0);
    cached = (__bridge_transfer NSFont *)CTFontCreateCopyWithAttributes((__bridge CTFontRef)font, kCodeSize, &skew, NULL);
    slanted[@(bold)] = cached;
    return cached;
}

/// Slack's dark code theme (cm-s-yonce over CodeMirror's default) for a token's classes.
static NSDictionary *TokenAttributes(NSString *classes) {
    static NSMutableDictionary<NSString *, NSDictionary *> *cache;
    if (!cache) cache = [NSMutableDictionary new];
    NSDictionary *cached = cache[classes];
    if (cached) return cached;
    NSSet<NSString *> *names = [NSSet setWithArray:[classes componentsSeparatedByString:@" "]];
    BOOL (^has)(NSString *) = ^BOOL(NSString *name) { return [names containsObject:[@"cm-" stringByAppendingString:name]]; };
    SNColorToken color = SNLegacyPrimaryForeground;
    BOOL italic = NO, bold = NO, underline = NO, strike = NO;
    if (has(@"def") && (has(@"type") || has(@"property"))) color = 0xfc4384ff, underline = has(@"type");
    else if (has(@"tag") && has(@"bracket")) color = SNLegacyPrimaryForeground;
    else if (has(@"comment")) color = 0x696d70ff, italic = YES;
    else if (has(@"keyword")) color = 0x00a7aaff;
    else if (has(@"atom") || has(@"string-2")) color = 0xf39b35ff;
    else if (has(@"number") || has(@"type") || has(@"variable-3") || has(@"attribute")) color = 0xa06fcaff;
    else if (has(@"def") || has(@"hr")) color = 0x98e342ff;
    else if (has(@"variable-2")) color = 0xda7daeff, italic = YES;
    else if (has(@"property") || has(@"variable")) italic = YES;
    else if (has(@"callee") || has(@"operator") || has(@"qualifier") || has(@"tag") || has(@"builtin")) color = 0xfc4384ff;
    else if (has(@"string")) color = 0xe6db74ff;
    else if (has(@"header")) color = 0xda7daeff, bold = YES;
    else if (has(@"bracket")) color = 0x999977ff;
    else if (has(@"quote")) color = 0x009900ff;
    else if (has(@"link")) color = 0x696d70ff, italic = YES;
    else if (has(@"error")) color = 0xff0000ff;
    else if (has(@"negative")) color = 0xdd4444ff;
    else if (has(@"positive")) color = 0x229922ff;
    italic = italic || has(@"em");
    bold = bold || has(@"strong");
    strike = has(@"strikethrough");
    NSMutableDictionary *attributes = [@{NSFontAttributeName : MonoFont(italic, bold),
                                         (__bridge NSString *)kCTForegroundColorAttributeName : (__bridge id)SNCGColor(color)} mutableCopy];
    if (underline) attributes[NSUnderlineStyleAttributeName] = @(NSUnderlineStyleSingle);
    if (strike) attributes[NSStrikethroughStyleAttributeName] = @(NSUnderlineStyleSingle);
    cache[classes] = attributes;
    return attributes;
}

static NSString *DecodeEntities(NSString *text) {
    if (![text containsString:@"&"]) return text;
    NSMutableString *out = [NSMutableString stringWithCapacity:text.length];
    NSScanner *scanner = [NSScanner scannerWithString:text];
    scanner.charactersToBeSkipped = nil;
    while (!scanner.isAtEnd) {
        NSString *chunk;
        if ([scanner scanUpToString:@"&" intoString:&chunk]) [out appendString:chunk];
        if (scanner.isAtEnd) break;
        NSUInteger start = scanner.scanLocation;
        NSString *entity;
        scanner.scanLocation = start + 1;
        if (![scanner scanUpToString:@";" intoString:&entity] || scanner.isAtEnd || entity.length > 10) {
            [out appendString:@"&"];
            scanner.scanLocation = start + 1;
            continue;
        }
        scanner.scanLocation++;
        static NSDictionary *named;
        if (!named) named = @{@"lt" : @"<", @"gt" : @">", @"amp" : @"&", @"quot" : @"\"", @"apos" : @"'", @"nbsp" : @" "};
        NSString *value = named[entity];
        if (!value && [entity hasPrefix:@"#"]) {
            BOOL hex = [entity hasPrefix:@"#x"] || [entity hasPrefix:@"#X"];
            unsigned long code = strtoul([entity substringFromIndex:hex ? 2 : 1].UTF8String, NULL, hex ? 16 : 10);
            UTF32Char character = (UTF32Char)code;
            value = code ? [[NSString alloc] initWithBytes:&character length:4 encoding:NSUTF32LittleEndianStringEncoding] : nil;
        }
        [out appendString:value ?: [NSString stringWithFormat:@"&%@;", entity]];
    }
    return out;
}

@implementation SNSnippetPreview

+ (instancetype)previewOfFile:(SNFile *)file {
    // Layout and drawing both ask; the markup is parsed once per file and version of it.
    static NSCache<NSString *, id> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSCache new];
        cache.countLimit = 64;
    });
    NSString *key = [NSString stringWithFormat:@"%@/%lu/%lu", file.fileID, (unsigned long)file.previewHighlight.hash, (unsigned long)file.preview.hash];
    id cached = [cache objectForKey:key];
    if (cached) return cached == NSNull.null ? nil : cached;
    SNSnippetPreview *preview = [self parsedFile:file];
    [cache setObject:preview ?: NSNull.null forKey:key];
    return preview;
}

+ (instancetype)parsedFile:(SNFile *)file {
    SNSnippetPreview *preview = [self new];
    if (file.previewHighlight.length) [preview parseHighlight:file.previewHighlight];
    if (!preview->_lines.count && !preview->_rows.count && file.preview.length) {
        if ([file.fileType isEqualToString:@"csv"] || [file.fileType isEqualToString:@"tsv"]) {
            BOOL more = NO;
            preview->_rows = DelimitedRows(file.preview, [file.fileType isEqualToString:@"tsv"] ? '\t' : ',', NSUIntegerMax, &more);
            preview->_numericCells = NumericCells(preview->_rows);
        } else {
            [preview takePlainText:file.preview];
        }
    }
    return preview->_lines.count || preview->_rows.count ? preview : nil;
}

- (void)takePlainText:(NSString *)text {
    NSMutableArray *lines = [NSMutableArray new];
    for (NSString *line in [text componentsSeparatedByString:@"\n"])
        [lines addObject:[[NSAttributedString alloc] initWithString:line attributes:TokenAttributes(@"")]];
    _lines = lines;
}

/// The cells of CSV or TSV text, quotes and doubled quotes honoured; at most `maximum` rows.
static NSArray<NSArray<NSString *> *> *DelimitedRows(NSString *text, unichar separator, NSUInteger maximum, BOOL *more) {
    NSMutableArray *rows = [NSMutableArray new];
    NSMutableArray *row = [NSMutableArray new];
    NSMutableString *cell = [NSMutableString new];
    BOOL quoted = NO;
    NSUInteger length = text.length;
    for (NSUInteger i = 0; i <= length; i++) {
        unichar c = i < length ? [text characterAtIndex:i] : '\n';
        if (quoted) {
            if (c == '"' && i + 1 < length && [text characterAtIndex:i + 1] == '"') [cell appendString:@"\""], i++;
            else if (c == '"') quoted = NO;
            else [cell appendFormat:@"%C", c];
        } else if (c == '"' && !cell.length) {
            quoted = YES;
        } else if (c == separator) {
            [row addObject:[cell copy]];
            [cell setString:@""];
        } else if (c == '\n' || c == '\r') {
            if (c == '\r' && i + 1 < length && [text characterAtIndex:i + 1] == '\n') i++;
            if (row.count || cell.length) {
                [row addObject:[cell copy]];
                if (rows.count == maximum) {
                    *more = YES;
                    break;
                }
                [rows addObject:row];
            }
            row = [NSMutableArray new];
            [cell setString:@""];
        } else {
            [cell appendFormat:@"%C", c];
        }
    }
    return rows;
}

/// CodeMirror's csv mode marks plain numbers (cm-num), which Slack right-aligns.
static NSArray<NSIndexSet *> *NumericCells(NSArray<NSArray<NSString *> *> *rows) {
    static NSRegularExpression *number;
    if (!number) number = [NSRegularExpression regularExpressionWithPattern:@"^-?[0-9]+(\\.[0-9]+)?$" options:0 error:NULL];
    NSMutableArray *numeric = [NSMutableArray new];
    for (NSArray<NSString *> *row in rows) {
        NSMutableIndexSet *set = [NSMutableIndexSet new];
        [row enumerateObjectsUsingBlock:^(NSString *cell, NSUInteger i, BOOL *stop) {
            if ([number firstMatchInString:cell options:0 range:NSMakeRange(0, cell.length)]) [set addIndex:i];
        }];
        [numeric addObject:set];
    }
    return numeric;
}

- (instancetype)previewWithContent:(NSString *)content maximumLines:(NSUInteger)maximum {
    SNSnippetPreview *full = [SNSnippetPreview new];
    if (_rows) {
        BOOL more = NO;
        unichar separator = [content rangeOfString:@"\t"].location != NSNotFound && [content rangeOfString:@","].location == NSNotFound ? '\t' : ',';
        full->_rows = DelimitedRows(content, separator, maximum, &more);
        full->_numericCells = NumericCells(full->_rows);
        full->_truncated = more;
        full->_lines = @[];
        return full;
    }
    NSMutableArray<NSString *> *texts = [[content componentsSeparatedByString:@"\n"] mutableCopy];
    if (texts.count > 1 && !texts.lastObject.length) [texts removeLastObject];
    full->_truncated = texts.count > maximum;
    NSMutableArray<NSAttributedString *> *lines = [NSMutableArray new];
    for (NSUInteger i = 0; i < MIN(texts.count, maximum); i++) {
        NSString *text = [texts[i] stringByReplacingOccurrencesOfString:@"\r" withString:@""];
        // The server's highlighting where it covers the same line, plain text after it.
        BOOL highlighted = i < _lines.count && [_lines[i].string isEqualToString:text];
        [lines addObject:highlighted ? _lines[i] : [[NSAttributedString alloc] initWithString:text attributes:TokenAttributes(@"")]];
    }
    full->_lines = lines;
    return full;
}

/// Reads the server's CodeMirror markup: a <pre> per line with <span class="cm-..."> tokens, or
/// for CSV/TSV a "cm-row" <div> per row holding a "cm-col" <div> per cell.
- (void)parseHighlight:(NSString *)html {
    NSMutableArray<NSAttributedString *> *lines = [NSMutableArray new];
    NSMutableArray<NSArray<NSString *> *> *rows = [NSMutableArray new];
    NSMutableArray<NSIndexSet *> *numeric = [NSMutableArray new];
    NSMutableAttributedString *line;
    NSMutableArray<NSString *> *row;
    NSMutableIndexSet *rowNumeric;
    NSMutableString *cell;
    NSMutableArray<NSString *> *spans = [NSMutableArray new];
    // What each open <div> was, so its end closes the right thing.
    NSMutableArray<NSString *> *divs = [NSMutableArray new];
    NSScanner *scanner = [NSScanner scannerWithString:html];
    scanner.charactersToBeSkipped = nil;
    while (!scanner.isAtEnd) {
        NSString *text;
        if ([scanner scanUpToString:@"<" intoString:&text]) {
            text = DecodeEntities(text);
            if (cell) [cell appendString:text];
            else if (line) [line appendAttributedString:[[NSAttributedString alloc] initWithString:text attributes:TokenAttributes(spans.lastObject ?: @"")]];
        }
        if (scanner.isAtEnd) break;
        NSString *tag;
        scanner.scanLocation++;
        if (![scanner scanUpToString:@">" intoString:&tag]) tag = @"";
        if (!scanner.isAtEnd) scanner.scanLocation++;
        BOOL closing = [tag hasPrefix:@"/"];
        NSString *name = [[[tag substringFromIndex:closing] componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet].firstObject lowercaseString];
        NSString *classes = @"";
        NSRange classRange = [tag rangeOfString:@"class=\""];
        if (classRange.location != NSNotFound) {
            NSUInteger start = NSMaxRange(classRange);
            NSRange end = [tag rangeOfString:@"\"" options:0 range:NSMakeRange(start, tag.length - start)];
            if (end.location != NSNotFound) classes = [tag substringWithRange:NSMakeRange(start, end.location - start)];
        }
        NSArray<NSString *> *classList = [classes componentsSeparatedByString:@" "];
        if ([name isEqualToString:@"pre"]) {
            if (!closing) line = [NSMutableAttributedString new];
            else if (line) {
                [lines addObject:line];
                line = nil;
            }
        } else if ([name isEqualToString:@"span"]) {
            if (closing) [spans removeLastObject];
            else [spans addObject:classes];
        } else if ([name isEqualToString:@"br"] && line) {
            [line appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"]];
        } else if ([name isEqualToString:@"div"]) {
            if (!closing) {
                NSString *kind = [classList containsObject:@"cm-row"] ? @"row" : [classList containsObject:@"cm-col"] ? @"col" : @"";
                [divs addObject:kind];
                if ([kind isEqualToString:@"row"]) {
                    row = [NSMutableArray new];
                    rowNumeric = [NSMutableIndexSet new];
                } else if ([kind isEqualToString:@"col"] && row) {
                    if ([classList containsObject:@"cm-num"]) [rowNumeric addIndex:row.count];
                    cell = [NSMutableString new];
                }
            } else {
                NSString *kind = divs.lastObject;
                if (divs.count) [divs removeLastObject];
                if ([kind isEqualToString:@"col"] && cell) {
                    [row addObject:cell];
                    cell = nil;
                } else if ([kind isEqualToString:@"row"] && row) {
                    [rows addObject:row];
                    [numeric addObject:rowNumeric];
                    row = nil;
                }
            }
        }
    }
    _lines = lines;
    if (rows.count) {
        _rows = rows;
        _numericCells = numeric;
    }
}

@end
