// Owns the explorer's request words and the link decoder.
#import "model/files.h"
#import "model/json.h"

NSString *const SNFileTypeImages = @"images", *const SNFileTypeVideos = @"videos", *const SNFileTypeAudio = @"audio", *const SNFileTypeFolders = @"folder",
                *const SNFileTypeLists = @"lists", *const SNFileTypeCanvases = @"quip", *const SNFileTypeDocuments = @"documents",
                *const SNFileTypeSpreadsheets = @"spreadsheets", *const SNFileTypePresentations = @"presentations", *const SNFileTypePDFs = @"pdfs",
                *const SNFileTypeSnippets = @"snippets", *const SNFileTypeEmails = @"emails";

NSArray<NSString *> *SNFileTypesAll(void) {
    return @[ SNFileTypeLists, SNFileTypeCanvases, SNFileTypeDocuments, SNFileTypeSpreadsheets, SNFileTypePresentations, SNFileTypePDFs ];
}

NSArray<NSString *> *SNFileTypesCreatedByYou(void) { return @[ SNFileTypeLists, SNFileTypeCanvases, SNFileTypeDocuments ]; }

@implementation SNFileSearch

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _query = @"";
    _fileTypes = @[];
    _excludedFileTypes = @[];
    _fromIDs = @[];
    _sort = @"timestamp";
    _count = 50;
    _context = @"desktop_files_browser";
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    SNFileSearch *copy = [SNFileSearch new];
    copy.query = _query;
    copy.conversationID = _conversationID;
    copy.fileTypes = _fileTypes;
    copy.excludedFileTypes = _excludedFileTypes;
    copy.creatorID = _creatorID;
    copy.fromIDs = _fromIDs;
    copy.sharedWithYou = _sharedWithYou;
    copy.sort = _sort;
    copy.ascending = _ascending;
    copy.count = _count;
    copy.context = _context;
    return copy;
}

// querySuggestionFromQueryAndFilter: the typed words first, then from, in, type, -type and
// creator tokens in that order.
- (NSString *)requestQueryWithReference:(NSString *)reference {
    NSMutableArray<NSString *> *words = [NSMutableArray new];
    NSString *typed = [_query stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (typed.length) [words addObject:typed];
    for (NSString *userID in _fromIDs) [words addObject:[NSString stringWithFormat:@"from:<@%@>", userID]];
    if (_conversationID) [words addObject:[@"in:" stringByAppendingString:reference ?: [NSString stringWithFormat:@"<#%@>", _conversationID]]];
    for (NSString *type in _fileTypes) [words addObject:[@"type:" stringByAppendingString:type]];
    for (NSString *type in _excludedFileTypes) [words addObject:[@"-type:" stringByAppendingString:type]];
    if (_creatorID) [words addObject:[NSString stringWithFormat:@"creator:<@%@>", _creatorID]];
    return [words componentsJoinedByString:@" "];
}

@end

@implementation SNChannelLink

+ (instancetype)linkWithJSON:(NSDictionary *)json {
    NSURL *url = SNJSONURL(json, @"url");
    if (!url.host.length) return nil;
    SNChannelLink *link = [self new];
    link->_url = url;
    NSString *title = SNJSONString(json, @"title");
    link->_title = title.length ? title : nil;
    link->_iconURL = SNJSONURL(json, @"icon_url");
    link->_timestamp = SNJSONDouble(json, @"timestamp");
    return link;
}

@end
