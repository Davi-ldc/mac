// Owns turning pasteboards into files to attach.
#import "ui/composer/pasteboard.h"

NSArray<NSPasteboardType> *SNComposerFileTypes(void) { return @[ NSPasteboardTypeFileURL, NSPasteboardTypePNG, NSPasteboardTypeTIFF ]; }

NSArray<NSURL *> *SNComposerFilesFromPasteboard(NSPasteboard *pasteboard) {
    NSArray<NSURL *> *files = [pasteboard readObjectsForClasses:@[ NSURL.class ] options:@{NSPasteboardURLReadingFileURLsOnlyKey : @YES}];
    if (files.count) return files;
    // Copied text often carries a picture of itself (a spreadsheet's cells): the text wins.
    if ([pasteboard availableTypeFromArray:@[ NSPasteboardTypeString ]]) return @[];
    NSData *png = [pasteboard dataForType:NSPasteboardTypePNG];
    if (!png) {
        NSData *tiff = [pasteboard dataForType:NSPasteboardTypeTIFF];
        png = tiff ? [[NSBitmapImageRep imageRepWithData:tiff] representationUsingType:NSBitmapImageFileTypePNG properties:@{}] : nil;
    }
    if (!png) return @[];
    NSURL *folder = [NSFileManager.defaultManager.temporaryDirectory URLByAppendingPathComponent:[@"sn-paste-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSURL *file = [folder URLByAppendingPathComponent:@"image.png"];
    BOOL written = [NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:nil] && [png writeToURL:file atomically:YES];
    return written ? @[ file ] : @[];
}
