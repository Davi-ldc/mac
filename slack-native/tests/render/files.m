// Files in messages: the real shapes Slack sends for videos, documents, snippets, CSV, audio
// clips and other files (tests/fixtures/conversations.history/C05FILES.json, made-up values),
// what component each is drawn by, and a snippet's preview lines.
#import <CoreText/CoreText.h>

#import "model/message.h"
#import "render/file.h"
#import "render/strings.h"
#import "theme/theme.h"
#import "test.h"

/// The files conversation's files by ID.
static NSDictionary<NSString *, SNFile *> *Files(void) {
    NSURL *url = [SNPublicFixture() URLByAppendingPathComponent:@"conversations.history/C05FILES.json"];
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:url] options:0 error:NULL];
    NSMutableDictionary *files = [NSMutableDictionary new];
    for (NSDictionary *item in json[@"messages"])
        for (SNFile *file in [SNMessage messageWithJSON:item conversationID:@"C05FILES"].files) files[file.fileID] = file;
    return files;
}

SN_TEST(RenderFileShapesDecode) {
    NSDictionary<NSString *, SNFile *> *files = Files();
    SNFile *video = files[@"F10CLIP"], *pdf = files[@"F11REPORT"], *audio = files[@"F15VOICE"], *text = files[@"F13NOTES"];
    SNExpect(video.videoThumbnailURL && video.mp4URL && CGSizeEqualToSize(video.videoThumbnailSize, CGSizeMake(480, 608)), "a video's poster, stream and size");
    SNExpect(fabs(video.duration - 8.274) < 0.001, "duration_ms in seconds");
    SNExpect([video.transcriptionStatus isEqualToString:@"none"], "the transcript status");
    SNExpect(pdf.pdfThumbnailURL && CGSizeEqualToSize(pdf.pdfThumbnailSize, CGSizeMake(935, 1210)), "a PDF's first page and its size");
    SNExpect(audio.waveform.count == 60 && [audio.subtype isEqualToString:@"slack_audio"], "a clip's waveform samples");
    SNExpect([audio.transcriptionPreview hasPrefix:@"Quick update"], "a clip's transcript preview");
    SNExpect(text.lineCount == 212 && text.moreLineCount == 206 && text.previewHighlight.length, "a snippet's line counts and markup");
}

SN_TEST(RenderFilePicksSlacksComponent) {
    NSDictionary<NSString *, SNFile *> *files = Files();
    SNExpect(SNFileStyleOf(files[@"F10CLIP"]) == SNFileStyleVideo, "mp4 with a poster: the video player");
    SNExpect(SNFileStyleOf(files[@"F11REPORT"]) == SNFileStyleDocument, "a PDF with thumb_pdf: the preview card");
    SNExpect(SNFileStyleOf(files[@"F12GREET"]) == SNFileStyleSnippet, "a code snippet");
    SNExpect(SNFileStyleOf(files[@"F14HOURS"]) == SNFileStyleSnippet, "a CSV snippet");
    SNExpect(SNFileStyleOf(files[@"F15VOICE"]) == SNFileStyleAudio, "an audio clip");
    SNExpect(SNFileStyleOf(files[@"F16ASSETS"]) == SNFileStyleCard, "a zip: the plain card");
    SNExpect(SNFileStyleOf(files[@"F17BRIEF"]) == SNFileStyleCard, "a Word document without a preview: the plain card");
    SNFile *tombstone = [SNFile fileWithJSON:@{@"id" : @"F0GONE", @"mode" : @"tombstone", @"mimetype" : @"video/mp4"}];
    SNExpect(SNFileStyleOf(tombstone) == SNFileStyleCard, "a video without poster or stream: the card");
}

SN_TEST(RenderFileDurations) {
    SNExpect([SNFormatDuration(8.274) isEqualToString:@"0:08"], "seconds");
    SNExpect([SNFormatDuration(48.081) isEqualToString:@"0:48"], "under a minute");
    SNExpect([SNFormatDuration(724) isEqualToString:@"12:04"], "minutes");
    SNExpect([SNFormatDuration(3723) isEqualToString:@"1:02:03"], "hours");
}

SN_TEST(RenderSnippetPreviewLines) {
    NSDictionary<NSString *, SNFile *> *files = Files();
    SNSnippetPreview *code = [SNSnippetPreview previewOfFile:files[@"F12GREET"]];
    SNExpect(code.lines.count == 11 && !code.rows, "one line per <pre>");
    SNExpect([code.lines[1].string isEqualToString:@"    \"\"\"Say hello.\"\"\""], "entities decoded, indentation kept");
    NSAttributedString *first = code.lines[0];
    NSString *color = (__bridge NSString *)kCTForegroundColorAttributeName;
    id keyword = [first attribute:color atIndex:0 effectiveRange:NULL];
    id plain = [first attribute:color atIndex:[first.string rangeOfString:@"("].location effectiveRange:NULL];
    SNExpect(keyword == (__bridge id)SNCGColor(0x00a7aaff), "keywords in the yonce theme's teal");
    SNExpect(plain == (__bridge id)SNCGColor(SNLegacyPrimaryForeground), "untokenised text in the primary foreground");
    SNExpect([[first attribute:NSFontAttributeName atIndex:0 effectiveRange:NULL] isEqual:SNMonoFont(13, SNFontWeightRegular)], "Roboto Mono 13");
    SNSnippetPreview *csv = [SNSnippetPreview previewOfFile:files[@"F14HOURS"]];
    SNExpect(csv.rows.count == 4 && csv.rows[0].count == 5, "CSV rows of cells");
    SNExpect([csv.rows[2][3] isEqualToString:@"7.5"] && [csv.numericCells[2] containsIndex:3] && ![csv.numericCells[0] containsIndex:3], "numbers marked");
    SNFile *plainOnly = [SNFile fileWithJSON:@{@"id" : @"F0PLAIN", @"mode" : @"snippet", @"preview" : @"a\nb&c"}];
    SNExpect([[SNSnippetPreview previewOfFile:plainOnly].lines[1].string isEqualToString:@"b&c"], "the plain preview, not markup");
}

SN_TEST(RenderSnippetExpandsWithTheWholeText) {
    NSDictionary<NSString *, SNFile *> *files = Files();
    SNSnippetPreview *code = [SNSnippetPreview previewOfFile:files[@"F12GREET"]];
    NSString *text = [[code.lines valueForKey:@"string"] componentsJoinedByString:@"\n"];
    SNSnippetPreview *whole = [code previewWithContent:[text stringByAppendingString:@"\nprint(\"done\")\n"] maximumLines:500];
    SNExpect(whole.lines.count == 12 && !whole.truncated, "the lines after the preview are added");
    SNExpect(whole.lines[0] == code.lines[0], "matching lines keep the server's highlighting");
    SNSnippetPreview *cut = [code previewWithContent:text maximumLines:5];
    SNExpect(cut.lines.count == 5 && cut.truncated, "500 lines at most, then the truncation line");
    SNSnippetPreview *csv = [[SNSnippetPreview previewOfFile:files[@"F14HOURS"]] previewWithContent:@"a,b\n\"x, y\",2\n\"say \"\"hi\"\"\",3.5\n" maximumLines:500];
    SNExpect(csv.rows.count == 3 && [csv.rows[1][0] isEqualToString:@"x, y"] && [csv.rows[2][0] isEqualToString:@"say \"hi\""], "CSV quotes");
    SNExpect([csv.numericCells[2] containsIndex:1] && ![csv.numericCells[0] containsIndex:1], "numbers right-aligned");
}

SN_TEST(RenderFileDescriptions) {
    NSDictionary<NSString *, SNFile *> *files = Files();
    SNExpect([SNFileDescription(files[@"F17BRIEF"]) isEqualToString:@"Word Document"], "pretty_type, no size");
    SNFile *drive = [SNFile fileWithJSON:@{@"id" : @"F0DRIVE", @"is_external" : @YES, @"external_type" : @"gdrive", @"filetype" : @"gsheet", @"pretty_type" : @"GSheet"}];
    SNExpect([SNFileDescription(drive) isEqualToString:SNLocalized(@"render.file.gsheet")], "Google's own names for Drive files");
    SNFile *bare = [SNFile fileWithJSON:@{@"id" : @"F0BARE"}];
    SNExpect([SNFileDescription(bare) isEqualToString:SNLocalized(@"render.file.generic")], "File without a type");
    SNFile *hostedText = [SNFile fileWithJSON:@{@"id" : @"F0TXT", @"mode" : @"hosted", @"filetype" : @"text", @"preview" : @"hello"}];
    SNExpect(SNFileStyleOf(hostedText) == SNFileStyleCard, "a hosted text file is a card: only snippets preview");
    SNFile *external = [SNFile fileWithJSON:@{@"id" : @"F0EXT", @"is_external" : @YES, @"external_type" : @"dropbox", @"filetype" : @"mp4", @"mimetype" : @"video/mp4"}];
    SNExpect(SNFileStyleOf(external) == SNFileStyleCard, "a video on another service is a card");
}
