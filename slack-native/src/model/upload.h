// A file attached to a composer: on its way to Slack, waiting there to be shared with the
// message, or failed. Snapshots: the source replaces one on every change and announces it under
// SNChangeUploads.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SNUploadState) {
    /// Sending its bytes (`progress`), or waiting for the uploads before it: Slack's upload queue
    /// sends one file at a time.
    SNUploadUploading,
    /// Sent; Slack is making the file (until its file_created event).
    SNUploadProcessing,
    /// One of Slack's files (`fileID`), shared with no conversation yet.
    SNUploadReady,
    /// `error` holds Slack's error string, or "upload_failed" when the transfer had no answer.
    SNUploadFailed,
};

@interface SNUpload : NSObject
/// Local, stable for the upload's life ("pending file ID" in Slack's client).
@property (nonatomic, readonly) NSString *uploadID;
/// The local file whose bytes are sent.
@property (nonatomic, readonly) NSURL *fileURL;
@property (nonatomic, readonly) NSString *name, *mimeType;
@property (nonatomic, readonly) long long size;
@property (nonatomic, readonly) SNUploadState state;
/// 0-1 of the bytes sent.
@property (nonatomic, readonly) double progress;
@property (nonatomic, readonly, nullable) NSString *fileID, *error;
/// Pictures the composer shows as thumbnails (image/*, as Slack's client decides).
@property (nonatomic, readonly) BOOL isImage;

+ (instancetype)uploadWithFile:(NSURL *)fileURL name:(NSString *)name mimeType:(NSString *)mimeType size:(long long)size;
- (instancetype)uploadWithState:(SNUploadState)state progress:(double)progress fileID:(nullable NSString *)fileID error:(nullable NSString *)error;
/// The file as a message's "files" item, for the message shown while it is sent: sn_local_url is
/// the local file (SNFile.localURL), the id the upload's until Slack names the file.
@property (nonatomic, readonly) NSDictionary *fileJSON;
@end

/// The MIME type of a local file from its extension (application/octet-stream when unknown).
NSString *SNUploadMIMEType(NSURL *fileURL);

NS_ASSUME_NONNULL_END
