// Owns the document's attributes, the typing shortcuts and both conversions (document to
// rich_text + mrkdwn, rich_text or mrkdwn to document).
#import "render/emoji.h"
#import "ui/composer/richtext.h"

NSAttributedStringKey const SNRichStyleAttribute = @"SNInlineStyle";
NSAttributedStringKey const SNRichLinkAttribute = @"SNRichLink";
NSAttributedStringKey const SNRichEntityAttribute = @"SNRichEntity";
NSAttributedStringKey const SNRichBlockAttribute = @"SNRichBlock";

static const unichar kAttachment = 0xFFFC;
NSString *const SNRichCustomEmojiText = @"\uFFFC";

#pragma mark Attributes

@implementation SNRichEntity

+ (instancetype)entityWithKind:(SNRichEntityKind)kind value:(NSString *)value {
    SNRichEntity *entity = [self new];
    entity->_kind = kind;
    entity->_value = [value copy];
    return entity;
}

+ (instancetype)emojiWithName:(NSString *)name unicode:(NSString *)unicode {
    SNRichEntity *entity = [self entityWithKind:SNRichEntityEmoji value:name];
    entity->_unicode = [unicode copy];
    return entity;
}

// Equality stays identity: two mentions or emoji typed side by side are separate attribute runs.
- (id)copyWithZone:(NSZone *)zone { return self; }

@end

@implementation SNRichBlock

+ (instancetype)blockWithKind:(SNRichBlockKind)kind indent:(NSInteger)indent {
    SNRichBlock *block = [self new];
    block->_kind = kind;
    block->_indent = MAX(0, MIN(8, indent));
    return block;
}

- (id)copyWithZone:(NSZone *)zone { return self; }
- (BOOL)isList { return _kind == SNRichBlockBullet || _kind == SNRichBlockOrdered; }

- (BOOL)isEqual:(id)other {
    return [other isKindOfClass:SNRichBlock.class] && ((SNRichBlock *)other).kind == _kind && ((SNRichBlock *)other).indent == _indent;
}

- (NSUInteger)hash { return (NSUInteger)(_kind * 16 + _indent); }

@end

@implementation SNRichMessage

- (instancetype)initWithText:(NSString *)text blocks:(NSArray *)blocks {
    if (!(self = [super init])) return nil;
    _text = [text copy];
    _blocks = [blocks copy];
    return self;
}

@end

NSRange SNRichParagraphRange(NSString *string, NSUInteger location) {
    return [string paragraphRangeForRange:NSMakeRange(MIN(location, string.length), 0)];
}

static SNRichBlock *BlockAt(NSAttributedString *document, NSUInteger index) {
    return index < document.length ? [document attribute:SNRichBlockAttribute atIndex:index effectiveRange:NULL] : nil;
}

static SNInlineStyle StyleAt(NSAttributedString *document, NSUInteger index) {
    return [[document attribute:SNRichStyleAttribute atIndex:index effectiveRange:NULL] unsignedIntegerValue];
}

static void SetBlock(NSMutableAttributedString *document, NSRange paragraph, SNRichBlock *block) {
    if (block) [document addAttribute:SNRichBlockAttribute value:block range:paragraph];
    else [document removeAttribute:SNRichBlockAttribute range:paragraph];
}

void SNRichNormalizeParagraphs(NSMutableAttributedString *document, NSRange edited) {
    NSString *string = document.string;
    if (!string.length) return;
    NSUInteger location = MIN(edited.location, string.length - 1);
    NSRange span = [string paragraphRangeForRange:NSMakeRange(location, MIN(edited.length, string.length - location))];
    [string enumerateSubstringsInRange:span options:NSStringEnumerationByParagraphs | NSStringEnumerationSubstringNotRequired
                            usingBlock:^(NSString *substring, NSRange inner, NSRange paragraph, BOOL *stop) {
        if (paragraph.length) SetBlock(document, paragraph, BlockAt(document, paragraph.location));
    }];
}

#pragma mark Typing shortcuts

static BOOL IsSpace(unichar c) { return [NSCharacterSet.whitespaceAndNewlineCharacterSet characterIsMember:c]; }
static BOOL IsWordCharacter(unichar c) { return [NSCharacterSet.alphanumericCharacterSet characterIsMember:c]; }

static BOOL InEntity(NSAttributedString *document, NSUInteger index) {
    return [document attribute:SNRichEntityAttribute atIndex:index effectiveRange:NULL] != nil;
}

/// "- ", "* ", "• ", "1. " and "> " at the start of a plain paragraph; ``` at the start of any
/// paragraph that is not code yet.
static NSUInteger BlockShortcut(NSMutableAttributedString *document, NSUInteger last, SNRichBlock **made) {
    NSString *string = document.string;
    NSRange paragraph = SNRichParagraphRange(string, last);
    NSString *typed = [string substringWithRange:NSMakeRange(paragraph.location, last + 1 - paragraph.location)];
    SNRichBlock *current = BlockAt(document, paragraph.location);
    SNRichBlock *block = nil;
    NSUInteger prefix = typed.length;
    if ([typed isEqualToString:@"```"] && current.kind != SNRichBlockCode) {
        block = [SNRichBlock blockWithKind:SNRichBlockCode indent:0];
    } else if (!current && [typed hasSuffix:@" "]) {
        NSString *marker = [typed substringToIndex:typed.length - 1];
        if ([@[ @"-", @"*", @"•" ] containsObject:marker]) block = [SNRichBlock blockWithKind:SNRichBlockBullet indent:0];
        else if ([marker isEqualToString:@">"]) block = [SNRichBlock blockWithKind:SNRichBlockQuote indent:0];
        else if (marker.length >= 2 && [marker hasSuffix:@"."] &&
                 [[marker substringToIndex:marker.length - 1] rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location == NSNotFound)
            block = [SNRichBlock blockWithKind:SNRichBlockOrdered indent:0];
    }
    if (!block) return NSNotFound;
    [document deleteCharactersInRange:NSMakeRange(paragraph.location, prefix)];
    NSRange rest = SNRichParagraphRange(document.string, paragraph.location);
    if (rest.length) SetBlock(document, rest, block);
    *made = block;
    return paragraph.location;
}

/// *bold*, _italic_, ~strike~ and `code` once the closing marker is typed: the opening marker is
/// the nearest one before it in the paragraph, at the start of a word, with text between that
/// neither starts nor ends with a space.
static NSUInteger InlineShortcut(NSMutableAttributedString *document, NSUInteger last) {
    NSString *string = document.string;
    unichar marker = [string characterAtIndex:last];
    SNInlineStyle style = marker == '*' ? SNInlineBold : marker == '_' ? SNInlineItalic : marker == '~' ? SNInlineStrike : marker == '`' ? SNInlineCode : 0;
    if (!style) return NSNotFound;
    NSRange paragraph = SNRichParagraphRange(string, last);
    if (BlockAt(document, last).kind == SNRichBlockCode || InEntity(document, last)) return NSNotFound;
    if (marker != '`' && (StyleAt(document, last) & SNInlineCode)) return NSNotFound;
    NSUInteger open = NSNotFound;
    for (NSUInteger i = last; i > paragraph.location; i--)
        if ([string characterAtIndex:i - 1] == marker) {
            open = i - 1;
            break;
        }
    if (open == NSNotFound || last - open < 2 || InEntity(document, open)) return NSNotFound;
    if (IsSpace([string characterAtIndex:open + 1]) || IsSpace([string characterAtIndex:last - 1])) return NSNotFound;
    if (open > paragraph.location) {
        unichar before = [string characterAtIndex:open - 1];
        if (IsWordCharacter(before) || before == marker) return NSNotFound;
    }
    if (marker != '`' && (StyleAt(document, open) & SNInlineCode)) return NSNotFound;
    [document deleteCharactersInRange:NSMakeRange(last, 1)];
    [document deleteCharactersInRange:NSMakeRange(open, 1)];
    NSRange content = NSMakeRange(open, last - open - 1);
    [document enumerateAttribute:SNRichStyleAttribute inRange:content options:0 usingBlock:^(NSNumber *value, NSRange range, BOOL *stop) {
        SNInlineStyle merged = style == SNInlineCode ? SNInlineCode : (value.unsignedIntegerValue | style);
        [document addAttribute:SNRichStyleAttribute value:@(merged) range:range];
    }];
    return NSMaxRange(content);
}

/// :name: once the closing colon is typed, for a standard or custom emoji the client knows.
static NSUInteger EmojiShortcut(NSMutableAttributedString *document, NSUInteger last) {
    NSString *string = document.string;
    if ([string characterAtIndex:last] != ':' || BlockAt(document, last).kind == SNRichBlockCode || (StyleAt(document, last) & SNInlineCode)) return NSNotFound;
    NSRange paragraph = SNRichParagraphRange(string, last);
    static NSRegularExpression *pattern;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        pattern = [NSRegularExpression regularExpressionWithPattern:@":([a-z0-9_+'-]+(?:::skin-tone-[2-6])?):$" options:0 error:nil];
    });
    NSRange searched = NSMakeRange(paragraph.location, last + 1 - paragraph.location);
    // ":skin-tone-N:" right after an emoji typed without one gives it that tone.
    NSRange tone = [string rangeOfString:@":skin-tone-" options:NSBackwardsSearch range:searched];
    if (tone.location != NSNotFound && tone.location > paragraph.location && last == tone.location + 12 && [string characterAtIndex:last - 1] >= '2' &&
        [string characterAtIndex:last - 1] <= '6') {
        NSRange emojiRange;
        SNRichEntity *emoji = [document attribute:SNRichEntityAttribute atIndex:tone.location - 1 effectiveRange:&emojiRange];
        if (emoji.kind == SNRichEntityEmoji && ![emoji.value containsString:@"::"]) {
            NSString *name = [NSString stringWithFormat:@"%@::skin-tone-%C", emoji.value, [string characterAtIndex:last - 1]];
            NSString *unicode = SNEmojiUnicode(name);
            if (unicode) {
                NSRange whole = NSMakeRange(emojiRange.location, last + 1 - emojiRange.location);
                NSMutableDictionary *attributes = [[document attributesAtIndex:emojiRange.location effectiveRange:NULL] mutableCopy];
                attributes[SNRichEntityAttribute] = [SNRichEntity emojiWithName:name unicode:SNCodePointsOfText(unicode)];
                [document replaceCharactersInRange:whole withAttributedString:[[NSAttributedString alloc] initWithString:unicode attributes:attributes]];
                return emojiRange.location + unicode.length;
            }
        }
    }
    NSTextCheckingResult *match = [pattern firstMatchInString:string options:0 range:searched];
    if (!match) return NSNotFound;
    NSRange whole = match.range;
    if (whole.location > paragraph.location) {
        unichar before = [string characterAtIndex:whole.location - 1];
        if (!IsSpace(before) && before != '(') return NSNotFound;
    }
    for (NSUInteger i = whole.location; i <= last; i++)
        if (InEntity(document, i)) return NSNotFound;
    NSString *name = [string substringWithRange:[match rangeAtIndex:1]];
    NSString *unicode = SNEmojiUnicode(name);
    if (!unicode && !SNCustomEmojiURL(name)) return NSNotFound;
    NSString *text = unicode ?: SNRichCustomEmojiText;
    NSMutableDictionary *attributes = [[document attributesAtIndex:whole.location effectiveRange:NULL] mutableCopy];
    [attributes removeObjectForKey:SNRichLinkAttribute];
    attributes[SNRichEntityAttribute] = [SNRichEntity emojiWithName:name unicode:unicode ? SNCodePointsOfText(unicode) : nil];
    [document replaceCharactersInRange:whole withAttributedString:[[NSAttributedString alloc] initWithString:text attributes:attributes]];
    return whole.location + text.length;
}

/// [text](url) once the closing parenthesis is typed.
static NSUInteger LinkShortcut(NSMutableAttributedString *document, NSUInteger last) {
    NSString *string = document.string;
    if ([string characterAtIndex:last] != ')' || BlockAt(document, last).kind == SNRichBlockCode) return NSNotFound;
    NSRange paragraph = SNRichParagraphRange(string, last);
    NSRange middle = [string rangeOfString:@"](" options:NSBackwardsSearch range:NSMakeRange(paragraph.location, last - paragraph.location)];
    if (middle.location == NSNotFound) return NSNotFound;
    NSRange open = [string rangeOfString:@"[" options:NSBackwardsSearch range:NSMakeRange(paragraph.location, middle.location - paragraph.location)];
    if (open.location == NSNotFound || middle.location - open.location < 2) return NSNotFound;
    NSString *url = [string substringWithRange:NSMakeRange(NSMaxRange(middle), last - NSMaxRange(middle))];
    if (!url.length || [url rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound) return NSNotFound;
    if (![url containsString:@"."] && ![url containsString:@":"]) return NSNotFound;
    if (![url containsString:@"://"] && ![url hasPrefix:@"mailto:"]) url = [@"http://" stringByAppendingString:url];
    [document deleteCharactersInRange:NSMakeRange(middle.location, last + 1 - middle.location)];
    [document deleteCharactersInRange:NSMakeRange(open.location, 1)];
    NSRange text = NSMakeRange(open.location, middle.location - open.location - 1);
    [document addAttribute:SNRichLinkAttribute value:url range:text];
    return NSMaxRange(text);
}

NSUInteger SNApplyTypingShortcuts(NSMutableAttributedString *document, NSRange inserted, SNRichBlock **block) {
    if (!inserted.length || NSMaxRange(inserted) > document.length) return NSNotFound;
    NSUInteger last = NSMaxRange(inserted) - 1;
    SNRichBlock *made = nil;
    NSUInteger caret = BlockShortcut(document, last, &made);
    if (caret == NSNotFound) caret = InlineShortcut(document, last);
    if (caret == NSNotFound) caret = LinkShortcut(document, last);
    if (caret == NSNotFound) caret = EmojiShortcut(document, last);
    if (caret != NSNotFound && block) *block = made ?: BlockAt(document, MIN(caret, document.length ? document.length - 1 : 0));
    return caret;
}

#pragma mark Document to message

static NSDictionary *StyleJSON(SNInlineStyle style) {
    NSMutableDictionary *json = [NSMutableDictionary new];
    if (style & SNInlineBold) json[@"bold"] = @YES;
    if (style & SNInlineItalic) json[@"italic"] = @YES;
    if (style & SNInlineStrike) json[@"strike"] = @YES;
    if (style & SNInlineCode) json[@"code"] = @YES;
    if (style & SNInlineUnderline) json[@"underline"] = @YES;
    return json;
}

static NSString *Escaped(NSString *text) {
    return [[[text stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"] stringByReplacingOccurrencesOfString:@"<" withString:@"&lt;"]
        stringByReplacingOccurrencesOfString:@">"
                                  withString:@"&gt;"];
}

/// The mrkdwn markers around `text`, with its leading and trailing spaces kept outside them
/// (mrkdwn only closes a marker that follows a non-space).
static NSString *Marked(NSString *text, SNInlineStyle style) {
    if (!style) return text;
    NSRange core = [text rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet.invertedSet];
    if (core.location == NSNotFound) return text;
    NSRange end = [text rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet.invertedSet options:NSBackwardsSearch];
    NSString *inner = [text substringWithRange:NSMakeRange(core.location, NSMaxRange(end) - core.location)];
    NSMutableString *open = [NSMutableString new], *close = [NSMutableString new];
    for (NSArray *pair in @[ @[ @(SNInlineCode), @"`" ], @[ @(SNInlineStrike), @"~" ], @[ @(SNInlineItalic), @"_" ], @[ @(SNInlineBold), @"*" ] ])
        if (style & [pair[0] unsignedIntegerValue]) {
            [open appendString:pair[1]];
            [close insertString:pair[1] atIndex:0];
        }
    return [NSString stringWithFormat:@"%@%@%@%@%@", [text substringToIndex:core.location], open, inner, close, [text substringFromIndex:NSMaxRange(end)]];
}

static NSRegularExpression *URLPattern(void) {
    static NSRegularExpression *pattern;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        pattern = [NSRegularExpression regularExpressionWithPattern:@"\\b(?:https?://|www\\.)[^\\s<>]+[^\\s<>.,;:!?\"')\\]]" options:NSRegularExpressionCaseInsensitive error:nil];
    });
    return pattern;
}

void SNRichEnumerateBareLinks(NSString *string, NSRange range, void (^block)(NSRange link)) {
    [URLPattern() enumerateMatchesInString:string options:0 range:range usingBlock:^(NSTextCheckingResult *match, NSMatchingFlags flags, BOOL *stop) {
        block(match.range);
    }];
}

/// Builds the inline elements of a range and their mrkdwn at once.
@interface SNInlineWriter : NSObject
- (instancetype)initFindingLinks:(BOOL)findsLinks;
@property (nonatomic, readonly) NSMutableArray<NSDictionary *> *elements;
@property (nonatomic, readonly) NSMutableString *mrkdwn;
@end

@implementation SNInlineWriter {
    BOOL _findsLinks;
}

- (instancetype)initFindingLinks:(BOOL)findsLinks {
    if (!(self = [super init])) return nil;
    _findsLinks = findsLinks;
    _elements = [NSMutableArray new];
    _mrkdwn = [NSMutableString new];
    return self;
}

- (void)addText:(NSString *)text style:(SNInlineStyle)style {
    if (!text.length) return;
    NSDictionary *previous = _elements.lastObject;
    NSDictionary *styleJSON = StyleJSON(style);
    if ([previous[@"type"] isEqualToString:@"text"] && [(previous[@"style"] ?: @{}) isEqualToDictionary:styleJSON]) {
        NSMutableDictionary *merged = [previous mutableCopy];
        merged[@"text"] = [previous[@"text"] stringByAppendingString:text];
        _elements[_elements.count - 1] = merged;
    } else {
        NSMutableDictionary *element = [@{@"type" : @"text", @"text" : text} mutableCopy];
        if (styleJSON.count) element[@"style"] = styleJSON;
        [_elements addObject:element];
    }
    [_mrkdwn appendString:Marked(Escaped(text), style)];
}

- (void)addLink:(NSString *)url text:(nullable NSString *)text style:(SNInlineStyle)style {
    NSMutableDictionary *element = [@{@"type" : @"link", @"url" : url} mutableCopy];
    if (text.length && ![text isEqualToString:url]) element[@"text"] = text;
    NSDictionary *styleJSON = StyleJSON(style);
    if (styleJSON.count) element[@"style"] = styleJSON;
    [_elements addObject:element];
    NSString *link = element[@"text"] ? [NSString stringWithFormat:@"<%@|%@>", Escaped(url), Escaped(text)] : [NSString stringWithFormat:@"<%@>", Escaped(url)];
    [_mrkdwn appendString:Marked(link, style & ~SNInlineCode)];
}

/// Plain text with its bare URLs as links when sending (the web client links them then); a
/// draft keeps them as typed text.
- (void)addTextFindingLinks:(NSString *)text style:(SNInlineStyle)style {
    if (!_findsLinks || (style & SNInlineCode)) return [self addText:text style:style];
    __block NSUInteger done = 0;
    SNRichEnumerateBareLinks(text, NSMakeRange(0, text.length), ^(NSRange link) {
        [self addText:[text substringWithRange:NSMakeRange(done, link.location - done)] style:style];
        NSString *found = [text substringWithRange:link];
        NSString *url = [found.lowercaseString hasPrefix:@"www."] ? [@"http://" stringByAppendingString:found] : found;
        [self addLink:url text:[url isEqualToString:found] ? nil : found style:style];
        done = NSMaxRange(link);
    });
    [self addText:[text substringFromIndex:done] style:style];
}

- (void)addEntity:(SNRichEntity *)entity text:(NSString *)text style:(SNInlineStyle)style {
    switch (entity.kind) {
    case SNRichEntityUser:
        [_elements addObject:@{@"type" : @"user", @"user_id" : entity.value}];
        [_mrkdwn appendFormat:@"<@%@>", entity.value];
        break;
    case SNRichEntityChannel:
        [_elements addObject:@{@"type" : @"channel", @"channel_id" : entity.value}];
        [_mrkdwn appendFormat:@"<#%@>", entity.value];
        break;
    case SNRichEntityUsergroup:
        [_elements addObject:@{@"type" : @"usergroup", @"usergroup_id" : entity.value}];
        [_mrkdwn appendFormat:@"<!subteam^%@>", entity.value];
        break;
    case SNRichEntityBroadcast:
        [_elements addObject:@{@"type" : @"broadcast", @"range" : entity.value}];
        [_mrkdwn appendFormat:@"<!%@>", entity.value];
        break;
    case SNRichEntityEmoji: {
        // Emoji typed side by side may share one entity run when pasted; each composed character
        // (or attachment) is one emoji.
        NSUInteger count = 0;
        for (NSUInteger i = 0; i < text.length; i += [text rangeOfComposedCharacterSequenceAtIndex:i].length) count++;
        // A custom emoji is one attachment character.
        if (!entity.unicode) count = 1;
        NSArray *parts = [entity.value componentsSeparatedByString:@"::skin-tone-"];
        NSMutableDictionary *element = [@{@"type" : @"emoji", @"name" : parts[0]} mutableCopy];
        if (entity.unicode) element[@"unicode"] = entity.unicode;
        if (parts.count > 1) element[@"skin_tone"] = @([parts[1] integerValue]);
        NSDictionary *styleJSON = StyleJSON(style & ~SNInlineCode);
        if (styleJSON.count) element[@"style"] = styleJSON;
        for (NSUInteger i = 0; i < MAX(1u, count); i++) {
            [_elements addObject:element];
            [_mrkdwn appendFormat:@":%@:", entity.value];
        }
        break;
    }
    }
}

- (void)writeRange:(NSRange)range of:(NSAttributedString *)document {
    [document enumerateAttributesInRange:range options:0 usingBlock:^(NSDictionary<NSAttributedStringKey, id> *attributes, NSRange run, BOOL *stop) {
        NSString *text = [document.string substringWithRange:run];
        SNInlineStyle style = [attributes[SNRichStyleAttribute] unsignedIntegerValue];
        SNRichEntity *entity = attributes[SNRichEntityAttribute];
        NSString *link = attributes[SNRichLinkAttribute];
        if (entity) [self addEntity:entity text:text style:style];
        else if (link) [self addLink:link text:text style:style];
        else [self addTextFindingLinks:[text stringByReplacingOccurrencesOfString:[NSString stringWithCharacters:&kAttachment length:1] withString:@""] style:style];
    }];
}

@end

static NSString *ListMarker(SNRichBlock *block, NSInteger number) {
    if (block.kind == SNRichBlockOrdered) return [NSString stringWithFormat:@"%ld. ", (long)number];
    NSArray *bullets = @[ @"•", @"◦", @"▪︎" ];
    return [NSString stringWithFormat:@"%@ ", bullets[(NSUInteger)block.indent % bullets.count]];
}

/// One paragraph of the message: its block and its text without the newline.
typedef struct {
    __unsafe_unretained SNRichBlock *block;
    NSRange line;
} SNParagraph;

/// The document's rich_text block and mrkdwn. A message leaves out blank lines at either end and
/// the first line's indentation and links bare URLs; a draft keeps everything as typed.
static SNRichMessage *Write(NSAttributedString *document, BOOL draft) {
    NSString *string = document.string;
    NSCharacterSet *blank = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    NSRange first = [string rangeOfCharacterFromSet:blank.invertedSet];
    if (first.location == NSNotFound) return nil;
    NSRange used = NSMakeRange(0, string.length);
    if (!draft) {
        NSRange last = [string rangeOfCharacterFromSet:blank.invertedSet options:NSBackwardsSearch];
        // Indentation stays in code.
        NSUInteger start = BlockAt(document, first.location).kind == SNRichBlockCode ? SNRichParagraphRange(string, first.location).location : first.location;
        used = NSMakeRange(start, NSMaxRange(last) - start);
    }

    NSMutableData *storage = [NSMutableData new];
    [string enumerateSubstringsInRange:used options:NSStringEnumerationByParagraphs | NSStringEnumerationSubstringNotRequired
                            usingBlock:^(NSString *substring, NSRange line, NSRange paragraph, BOOL *stop) {
        SNParagraph item = {BlockAt(document, paragraph.location), line};
        [storage appendBytes:&item length:sizeof item];
    }];
    // The empty line after a final newline, which the enumeration leaves out; it has no
    // character to hold a block.
    if (draft && [NSCharacterSet.newlineCharacterSet characterIsMember:[string characterAtIndex:string.length - 1]]) {
        SNParagraph item = {nil, NSMakeRange(string.length, 0)};
        [storage appendBytes:&item length:sizeof item];
    }
    const SNParagraph *paragraphs = storage.bytes;
    NSUInteger count = storage.length / sizeof(SNParagraph);
    SNInlineWriter * (^newWriter)(void) = ^{ return [[SNInlineWriter alloc] initFindingLinks:!draft]; };

    NSMutableArray *elements = [NSMutableArray new];
    NSMutableArray<NSString *> *lines = [NSMutableArray new];
    // Ordered items written so far per indent in the current run of lists, so a list resuming
    // after deeper items keeps counting ("offset").
    NSMutableDictionary<NSNumber *, NSNumber *> *numbers = [NSMutableDictionary new];
    for (NSUInteger i = 0; i < count;) {
        SNRichBlock *block = paragraphs[i].block;
        NSUInteger end = i + 1;
        while (end < count && (block ? [paragraphs[end].block isEqual:block] : !paragraphs[end].block)) end++;

        if (!block.isList) [numbers removeAllObjects];
        for (NSNumber *indent in numbers.allKeys)
            if (indent.integerValue > block.indent) [numbers removeObjectForKey:indent];
        if (block.kind == SNRichBlockBullet) [numbers removeObjectForKey:@(block.indent)];

        NSMutableDictionary *element = [NSMutableDictionary new];
        NSMutableArray *children = [NSMutableArray new];
        SNInlineWriter *writer = newWriter();
        for (NSUInteger p = i; p < end; p++) {
            NSRange line = paragraphs[p].line;
            SNInlineWriter *lineWriter = newWriter();
            if (block.kind == SNRichBlockCode) {
                [lineWriter.mrkdwn appendString:Escaped([string substringWithRange:line])];
                if (p > i) [writer addText:@"\n" style:0];
                [writer addText:[string substringWithRange:line] style:0];
            } else if (block.isList) {
                SNInlineWriter *item = newWriter();
                [item writeRange:line of:document];
                [children addObject:@{@"type" : @"rich_text_section", @"elements" : item.elements}];
                [lineWriter writeRange:line of:document];
            } else {
                if (p > i) [writer addText:@"\n" style:0];
                [writer writeRange:line of:document];
                [lineWriter writeRange:line of:document];
            }

            NSString *mrkdwn = lineWriter.mrkdwn;
            if (block.isList) {
                NSInteger number = numbers[@(block.indent)].integerValue + 1;
                if (block.kind == SNRichBlockOrdered) numbers[@(block.indent)] = @(number);
                NSString *indent = [@"" stringByPaddingToLength:(NSUInteger)block.indent * 4 withString:@" " startingAtIndex:0];
                mrkdwn = [NSString stringWithFormat:@"%@%@%@", indent, ListMarker(block, number), mrkdwn];
            } else if (block.kind == SNRichBlockQuote) {
                mrkdwn = [@"&gt; " stringByAppendingString:mrkdwn];
            } else if (block.kind == SNRichBlockCode) {
                mrkdwn = [NSString stringWithFormat:@"%@%@%@", p == i ? @"```" : @"", mrkdwn, p + 1 == end ? @"```" : @""];
            }
            [lines addObject:mrkdwn];
        }

        if (!block) {
            element[@"type"] = @"rich_text_section";
            // SNRichDocumentFromBlocks, like Slack, reads a section's final newline as the break
            // before the next block, so an empty last line before one needs another.
            if (end < count && !paragraphs[end - 1].line.length) [writer addText:@"\n" style:0];
        } else if (block.isList) {
            element[@"type"] = @"rich_text_list";
            element[@"style"] = block.kind == SNRichBlockOrdered ? @"ordered" : @"bullet";
            element[@"indent"] = @(block.indent);
            NSInteger written = numbers[@(block.indent)].integerValue - (NSInteger)(end - i);
            if (block.kind == SNRichBlockOrdered && written > 0) element[@"offset"] = @(written);
            element[@"border"] = @0;
        } else if (block.kind == SNRichBlockQuote) {
            element[@"type"] = @"rich_text_quote";
        } else {
            element[@"type"] = @"rich_text_preformatted";
            element[@"border"] = @0;
        }
        element[@"elements"] = block.isList ? children : writer.elements;
        [elements addObject:element];
        i = end;
    }
    NSString *text = [lines componentsJoinedByString:@"\n"];
    return [[SNRichMessage alloc] initWithText:text blocks:@[ @{@"type" : @"rich_text", @"elements" : elements} ]];
}

SNRichMessage *SNRichMessageFromDocument(NSAttributedString *document) { return Write(document, NO); }

// Slack's test: a slash (or a full-width one) and then neither another nor a space.
BOOL SNRichStartsWithCommand(NSAttributedString *document) {
    NSString *string = document.string;
    if (string.length < 2 || ([string characterAtIndex:0] != '/' && [string characterAtIndex:0] != 0xff0f)) return NO;
    unichar next = [string characterAtIndex:1];
    if (next == '/' || next == 0xff0f || [NSCharacterSet.whitespaceAndNewlineCharacterSet characterIsMember:next]) return NO;
    return BlockAt(document, 0).kind != SNRichBlockCode && !(StyleAt(document, 0) & SNInlineCode);
}

NSString *SNRichDraftFromDocument(NSAttributedString *document) {
    NSArray *blocks = Write(document, YES).blocks;
    NSData *json = blocks ? [NSJSONSerialization dataWithJSONObject:blocks options:0 error:nil] : nil;
    return json ? [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] : nil;
}

NSMutableAttributedString *SNRichDocumentFromDraft(NSString *draft, NSString * (^name)(SNRichEntityKind, NSString *)) {
    id blocks = [NSJSONSerialization JSONObjectWithData:[draft dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    // Anything else is not a draft this client wrote: it is shown as the text it is.
    if (![blocks isKindOfClass:NSArray.class]) return [[NSMutableAttributedString alloc] initWithString:draft];
    return SNRichDocumentFromBlocks(blocks, name);
}

#pragma mark Slack's text to document

/// Builds a document from what the walker reads. A paragraph ends with a newline carrying its
/// block once the next one starts, unless a section's own final newline already ended it (Slack
/// writes the break before the next block that way). An empty list item is a paragraph like any
/// other.
@interface SNDocumentWriter : SNTextSink
@end

@implementation SNDocumentWriter {
  @public
    NSMutableAttributedString *_document;
    NSString * (^_name)(SNRichEntityKind, NSString *);
    SNRichBlock *_block;
    BOOL _open, _section;
    NSUInteger _start;
}

/// A section that ended with its own newline needs no other before the next paragraph.
- (void)endSection {
    if (!_section || _document.length <= _start || ![_document.string hasSuffix:@"\n"]) return;
    [_document removeAttribute:SNRichStyleAttribute range:NSMakeRange(_document.length - 1, 1)];
    _open = NO;
}

- (void)beginBlock:(SNTextBlockKind)kind indent:(NSInteger)indent number:(NSInteger)number {
    [self endSection];
    if (_open) [_document appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:_block ? @{SNRichBlockAttribute : _block} : @{}]];
    _open = YES;
    _section = kind == SNTextSection;
    _block = kind == SNTextListItem ? [SNRichBlock blockWithKind:number ? SNRichBlockOrdered : SNRichBlockBullet indent:indent]
           : kind == SNTextQuote    ? [SNRichBlock blockWithKind:SNRichBlockQuote indent:0]
           : kind == SNTextCode     ? [SNRichBlock blockWithKind:SNRichBlockCode indent:0]
                                    : nil;
    _start = _document.length;
}

- (void)append:(NSString *)text style:(SNInlineStyle)style extra:(NSDictionary *)extra {
    if (!text.length) return;
    NSMutableDictionary *attributes = [extra mutableCopy] ?: [NSMutableDictionary new];
    if (_block) attributes[SNRichBlockAttribute] = _block;
    if (style) attributes[SNRichStyleAttribute] = @(style);
    [_document appendAttributedString:[[NSAttributedString alloc] initWithString:text attributes:attributes]];
}

- (void)appendText:(NSString *)text style:(SNInlineStyle)style { [self append:text style:style extra:nil]; }

- (void)appendLink:(NSString *)url text:(NSString *)text style:(SNInlineStyle)style {
    [self append:text ?: url style:style extra:@{SNRichLinkAttribute : url}];
}

- (void)appendEntity:(SNRichEntityKind)kind value:(NSString *)value text:(NSString *)text {
    [self append:text style:0 extra:@{SNRichEntityAttribute : [SNRichEntity entityWithKind:kind value:value]}];
}

- (NSString *)nameOf:(SNRichEntityKind)kind value:(NSString *)value label:(NSString *)label prefix:(NSString *)prefix {
    NSString *name = (_name ? _name(kind, value) : nil) ?: ([label hasPrefix:prefix] ? [label substringFromIndex:prefix.length] : label) ?: value;
    return [prefix stringByAppendingString:name];
}

- (void)appendUser:(NSString *)userID label:(NSString *)label {
    [self appendEntity:SNRichEntityUser value:userID text:[self nameOf:SNRichEntityUser value:userID label:label prefix:@"@"]];
}

- (void)appendChannel:(NSString *)channelID label:(NSString *)label style:(SNInlineStyle)style {
    [self appendEntity:SNRichEntityChannel value:channelID text:[self nameOf:SNRichEntityChannel value:channelID label:label prefix:@"#"]];
}

- (void)appendUsergroup:(NSString *)groupID label:(NSString *)label {
    [self appendEntity:SNRichEntityUsergroup value:groupID text:[self nameOf:SNRichEntityUsergroup value:groupID label:label prefix:@"@"]];
}

- (void)appendBroadcast:(NSString *)range { [self appendEntity:SNRichEntityBroadcast value:range text:[@"@" stringByAppendingString:range]]; }

- (void)appendEmoji:(NSString *)name unicode:(NSString *)unicode style:(SNInlineStyle)style {
    NSString *glyph = SNEmojiUnicode(name);
    NSString *codePoints = unicode ?: (glyph ? SNCodePointsOfText(glyph) : nil);
    NSString *text = (codePoints ? SNTextFromCodePoints(codePoints) : nil) ?: SNRichCustomEmojiText;
    [self append:text style:style & ~SNInlineCode extra:@{SNRichEntityAttribute : [SNRichEntity emojiWithName:name unicode:codePoints]}];
}

- (void)appendDate:(NSTimeInterval)timestamp format:(NSString *)format link:(NSString *)link fallback:(NSString *)fallback style:(SNInlineStyle)style {
    [self appendText:fallback ?: @"" style:style];
}

- (BOOL)knowsEmoji:(NSString *)name { return SNEmojiUnicode(name) || SNCustomEmojiURL(name); }

@end

static SNDocumentWriter *Writer(NSString * (^name)(SNRichEntityKind, NSString *)) {
    SNDocumentWriter *writer = [SNDocumentWriter new];
    writer->_document = [NSMutableAttributedString new];
    writer->_name = name;
    return writer;
}

NSMutableAttributedString *SNRichDocumentFromMrkdown(NSString *mrkdwn, NSString * (^name)(SNRichEntityKind, NSString *)) {
    SNDocumentWriter *writer = Writer(name);
    SNWalkMrkdwn([mrkdwn stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"], 0, writer);
    [writer endSection];
    return writer->_document;
}

NSMutableAttributedString *SNRichDocumentFromBlocks(NSArray<NSDictionary *> *blocks, NSString * (^name)(SNRichEntityKind, NSString *)) {
    SNDocumentWriter *writer = Writer(name);
    SNWalkRichTextBlocks(blocks, writer);
    [writer endSection];
    return writer->_document;
}
