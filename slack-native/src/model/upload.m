// Owns upload snapshots and the file JSON of a message being sent.
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "model/upload.h"

__asm__(".linker_option \"-framework\", \"UniformTypeIdentifiers\"");

NSString *SNUploadMIMEType(NSURL *fileURL) {
    NSString *extension = fileURL.pathExtension;
    UTType *type = extension.length ? [UTType typeWithFilenameExtension:extension] : nil;
    return type.preferredMIMEType ?: @"application/octet-stream";
}

@implementation SNUpload

+ (instancetype)uploadWithFile:(NSURL *)fileURL name:(NSString *)name mimeType:(NSString *)mimeType size:(long long)size {
    SNUpload *upload = [self new];
    upload->_uploadID = NSUUID.UUID.UUIDString;
    upload->_fileURL = fileURL;
    upload->_name = [name copy];
    upload->_mimeType = [mimeType copy];
    upload->_size = size;
    return upload;
}

- (instancetype)uploadWithState:(SNUploadState)state progress:(double)progress fileID:(NSString *)fileID error:(NSString *)error {
    SNUpload *upload = [SNUpload new];
    upload->_uploadID = _uploadID;
    upload->_fileURL = _fileURL;
    upload->_name = _name;
    upload->_mimeType = _mimeType;
    upload->_size = _size;
    upload->_state = state;
    upload->_progress = progress;
    upload->_fileID = [fileID copy];
    upload->_error = [error copy];
    return upload;
}

- (BOOL)isImage { return [self.mimeType hasPrefix:@"image/"]; }

- (NSDictionary *)fileJSON {
    NSString *extension = self.name.pathExtension.lowercaseString;
    NSMutableDictionary *json = [@{@"id" : self.fileID ?: self.uploadID, @"name" : self.name, @"title" : self.name, @"mimetype" : self.mimeType,
                                   @"filetype" : extension.length ? extension : @"binary", @"pretty_type" : extension.length ? extension.uppercaseString : @"Binary",
                                   @"size" : @(self.size), @"mode" : @"hosted", @"sn_local_url" : self.fileURL.absoluteString} mutableCopy];
    if (self.isImage) {
        CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)self.fileURL, NULL);
        NSDictionary *properties = source ? CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL)) : nil;
        if (source) CFRelease(source);
        NSNumber *width = properties[(NSString *)kCGImagePropertyPixelWidth], *height = properties[(NSString *)kCGImagePropertyPixelHeight];
        // EXIF orientations 5-8 turn the picture a quarter.
        BOOL turned = [properties[(NSString *)kCGImagePropertyOrientation] integerValue] >= 5;
        if (width && height) [json addEntriesFromDictionary:@{@"original_w" : turned ? height : width, @"original_h" : turned ? width : height}];
    }
    return json;
}

@end
