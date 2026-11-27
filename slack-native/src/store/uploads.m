// Owns attached files: the upload queue as Slack's web client runs it (files.getUploadURL, the
// POST to the upload URL, files.completeUpload, then file_created), and sharing a message's
// files with files.share once they are all on Slack.
#import "model/json.h"
#import "store/internal.h"

// Implements part of SNSource, which the primary class adopts (see internal.h).
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

/// Slack's _x_reason for the queue's calls.
static NSString *const SNUploadReason = @"upload-queue";
/// Without file_created this long after files.completeUpload, files.list is asked: first after
/// 7.5 s, then at doubling intervals up to 30 s, for 10 minutes.
static const NSTimeInterval SNProcessingTimeout = 60, SNPollFirst = 7.5, SNPollLongest = 30, SNPollGiveUp = 600;

/// Errors a second attempt cannot fix (the web client's canRetry).
static BOOL SNUploadErrorIsFinal(NSString *error) {
    static NSSet<NSString *> *final;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        final = [NSSet setWithArray:@[
            @"file_uploads_disabled", @"file_uploads_except_images_disabled", @"slack_connect_file_link_sharing_blocked", @"slack_connect_blocked_file_type",
            @"slack_connect_file_upload_sharing_blocked", @"malware_detected", @"files_upload_has_exceeded_limit",
            @"slack_connect_canvas_contain_file_sharing_blocked", @"slack_connect_list_contain_file_sharing_blocked", @"file_not_found_on_device",
            @"dlp_user_warning", @"dlp_processing", @"blocked_file_type", @"canvas_header_image_unsupported_file_type", @"file_upload_size_restricted",
            @"file_upload_quota_exceeded", @"filestore_auth_error", @"filestore_disabled", @"filestore_misconfigured"
        ]];
    });
    return [final containsObject:error];
}

@implementation SNStore (Uploads)

#pragma mark Composer files

static NSString *UploadKey(NSString *conversationID, NSString *threadTS) { return threadTS ? SNThreadKey(conversationID, threadTS) : conversationID; }

- (NSArray<SNUpload *> *)uploadsInConversation:(NSString *)conversationID threadTS:(NSString *)threadTS {
    NSMutableArray *uploads = [NSMutableArray new];
    for (NSString *uploadID in self.attachedUploads[UploadKey(conversationID, threadTS)])
        if (self.uploads[uploadID]) [uploads addObject:self.uploads[uploadID]];
    return uploads;
}

/// The composer an upload is attached to; nil once its message took it.
- (NSString *)composerOfUpload:(NSString *)uploadID {
    for (NSString *key in self.attachedUploads)
        if ([self.attachedUploads[key] containsObject:uploadID]) return key;
    return nil;
}

- (void)setUpload:(SNUpload *)upload {
    self.uploads[upload.uploadID] = upload;
    NSString *key = [self composerOfUpload:upload.uploadID];
    if (key) [self changed:SNChangeUploads value:key];
}

- (void)attachFiles:(NSArray<NSURL *> *)files inConversation:(NSString *)conversationID threadTS:(NSString *)threadTS {
    NSString *key = UploadKey(conversationID, threadTS);
    [self performChanges:^{
        for (NSURL *file in files) {
            NSNumber *size = [file resourceValuesForKeys:@[ NSURLFileSizeKey ] error:nil][NSURLFileSizeKey];
            SNUpload *upload = [SNUpload uploadWithFile:file name:file.lastPathComponent mimeType:SNUploadMIMEType(file) size:size.longLongValue];
            NSMutableArray *attached = self.attachedUploads[key] ?: (self.attachedUploads[key] = [NSMutableArray new]);
            [attached addObject:upload.uploadID];
            [self.uploadQueue addObject:upload.uploadID];
            [self setUpload:upload];
        }
    }];
    [self startNextUpload];
}

- (void)removeUpload:(SNUpload *)upload {
    NSString *uploadID = upload.uploadID;
    SNUpload *held = self.uploads[uploadID];
    if (!held) return;
    NSString *key = [self composerOfUpload:uploadID];
    [self performChanges:^{
        [self.attachedUploads[key] removeObject:uploadID];
        if (key) [self changed:SNChangeUploads value:key];
        [self.uploads removeObjectForKey:uploadID];
    }];
    [self.uploadQueue removeObject:uploadID];
    [self.retriedUploads removeObject:uploadID];
    BOOL active = [self.activeUpload isEqualToString:uploadID];
    if (active && self.cancelTransfer) self.cancelTransfer();
    // Once files.completeUpload made it, the file is Slack's: a draft's file is deleted with it.
    if (held.fileID && (held.state == SNUploadProcessing || held.state == SNUploadReady)) {
        NSString *reason = held.state == SNUploadReady ? @"delete_draft_file" : @"upload-queue-cancel";
        NSMutableDictionary *params = [@{@"file" : held.fileID, @"_x_reason" : reason} mutableCopy];
        if (held.state == SNUploadReady) params[@"is_draft"] = @"true";
        [self request:@"files.delete" params:params priority:SNCallUserFacing completion:nil];
    }
    if (active) [self finishActiveUpload];
}

- (void)retryUpload:(SNUpload *)upload {
    SNUpload *held = self.uploads[upload.uploadID];
    if (held.state != SNUploadFailed) return;
    [self.retriedUploads removeObject:held.uploadID];
    [self performChanges:^{ [self setUpload:[held uploadWithState:SNUploadUploading progress:0 fileID:nil error:nil]]; }];
    [self.uploadQueue addObject:held.uploadID];
    [self startNextUpload];
}

#pragma mark The queue

- (void)startNextUpload {
    while (!self.activeUpload && self.uploadQueue.count) {
        NSString *uploadID = self.uploadQueue.firstObject;
        [self.uploadQueue removeObjectAtIndex:0];
        if (self.uploads[uploadID].state == SNUploadUploading) [self begin:uploadID];
    }
}

- (void)begin:(NSString *)uploadID {
    self.activeUpload = uploadID;
    SNUpload *upload = self.uploads[uploadID];
    NSDictionary *params = @{@"filename" : upload.name, @"length" : @(upload.size).stringValue, @"_x_reason" : SNUploadReason};
    [self request:@"files.getUploadURL" params:params priority:SNCallUserFacing completion:^(NSDictionary *response, NSError *error) {
        if (![self.activeUpload isEqualToString:uploadID]) return;
        NSString *fileID = SNJSONString(response, @"file");
        NSURL *url = SNJSONURL(response, @"upload_url");
        if (!fileID || !url) return [self failActive:SNAPIErrorName(error)];
        SNUpload *now = self.uploads[uploadID];
        [self performChanges:^{ [self setUpload:[now uploadWithState:SNUploadUploading progress:0 fileID:fileID error:nil]]; }];
        [self transfer:uploadID to:url];
    }];
}

- (void)transfer:(NSString *)uploadID to:(NSURL *)url {
    SNUpload *upload = self.uploads[uploadID];
    if (!self.api) return [self failActive:nil];
    __weak SNStore *weakSelf = self;
    self.cancelTransfer = [self.api upload:upload.fileURL name:upload.name mimeType:upload.mimeType to:url progress:^(double fraction) {
        SNStore *store = weakSelf;
        SNUpload *now = store.uploads[uploadID];
        // Slack's client redraws at whole percents.
        if (![store.activeUpload isEqualToString:uploadID] || floor(fraction * 100) == floor(now.progress * 100)) return;
        [store performChanges:^{ [store setUpload:[now uploadWithState:SNUploadUploading progress:fraction fileID:now.fileID error:nil]]; }];
    } completion:^(NSInteger status) {
        SNStore *store = weakSelf;
        if (![store.activeUpload isEqualToString:uploadID]) return;
        store.cancelTransfer = nil;
        if (status != 200) return [store failActive:nil];
        [store complete:uploadID];
    }];
}

- (void)complete:(NSString *)uploadID {
    SNUpload *upload = self.uploads[uploadID];
    NSDictionary *params = @{@"files" : SNJSONText(@[ @{@"id" : upload.fileID, @"title" : upload.name} ]), @"_x_reason" : SNUploadReason};
    [self request:@"files.completeUpload" params:params priority:SNCallUserFacing completion:^(NSDictionary *response, NSError *error) {
        if (![self.activeUpload isEqualToString:uploadID]) return;
        if (error) return [self failActive:SNAPIErrorName(error)];
        SNUpload *now = self.uploads[uploadID];
        [self performChanges:^{ [self setUpload:[now uploadWithState:SNUploadProcessing progress:1 fileID:now.fileID error:nil]]; }];
        // file_created ends the wait; without the websocket Slack's client asks files.list at once.
        if (self.connectionState != SNConnectionConnected) [self poll:uploadID after:SNPollFirst until:[NSDate dateWithTimeIntervalSinceNow:SNPollGiveUp]];
        else
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SNProcessingTimeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if ([self isProcessing:uploadID]) [self poll:uploadID after:SNPollFirst until:[NSDate dateWithTimeIntervalSinceNow:SNPollGiveUp]];
            });
    }];
}

- (BOOL)isProcessing:(NSString *)uploadID {
    return [self.activeUpload isEqualToString:uploadID] && self.uploads[uploadID].state == SNUploadProcessing;
}

- (void)poll:(NSString *)uploadID after:(NSTimeInterval)delay until:(NSDate *)deadline {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (![self isProcessing:uploadID]) return;
        NSString *fileID = self.uploads[uploadID].fileID;
        NSDictionary *params = @{@"files" : fileID, @"_x_reason" : @"upload-queue-poll-for-file-processing"};
        [self request:@"files.list" params:params priority:SNCallBackground completion:^(NSDictionary *response, NSError *error) {
            if (![self isProcessing:uploadID]) return;
            for (NSDictionary *file in SNJSONArray(response, @"files"))
                if ([SNJSONString(file, @"id") isEqualToString:fileID]) return [self applyFileCreated:fileID];
            if (deadline.timeIntervalSinceNow < 0) return [self failActive:@"processing_timeout"];
            [self poll:uploadID after:MIN(delay * 2, SNPollLongest) until:deadline];
        }];
    });
}

// The event may come before files.completeUpload's answer, which is then ignored.
- (void)applyFileCreated:(NSString *)fileID {
    NSString *uploadID = self.activeUpload;
    SNUpload *upload = uploadID ? self.uploads[uploadID] : nil;
    if (!fileID || ![upload.fileID isEqualToString:fileID]) return;
    [self performChanges:^{ [self setUpload:[upload uploadWithState:SNUploadReady progress:1 fileID:fileID error:nil]]; }];
    [self finishActiveUpload];
}

/// The first failure of an upload sends it again by itself; the second, or an error that cannot
/// change, leaves it failed. `error` nil: the transfer got no good answer.
- (void)failActive:(NSString *)error {
    NSString *uploadID = self.activeUpload;
    SNUpload *upload = self.uploads[uploadID];
    if (!upload) return;
    self.cancelTransfer = nil;
    NSString *name = error ?: @"upload_failed";
    if (!SNUploadErrorIsFinal(name) && ![self.retriedUploads containsObject:uploadID]) {
        [self.retriedUploads addObject:uploadID];
        [self performChanges:^{ [self setUpload:[upload uploadWithState:SNUploadUploading progress:0 fileID:nil error:nil]]; }];
        [self begin:uploadID];
        return;
    }
    [self performChanges:^{ [self setUpload:[upload uploadWithState:SNUploadFailed progress:0 fileID:nil error:name]]; }];
    [self finishActiveUpload];
}

- (void)finishActiveUpload {
    self.activeUpload = nil;
    self.cancelTransfer = nil;
    for (SNMessage *message in self.waitingShares.allValues) [self shareWhenUploaded:message];
    [self startNextUpload];
}

#pragma mark Sharing

- (void)shareWhenUploaded:(SNMessage *)message {
    NSString *identifier = message.identifier;
    // Sending (Retry, or Send with a failed file) uploads failed files again; a share already
    // waiting is only checked.
    if (!self.waitingShares[identifier])
        for (NSString *uploadID in SNJSONStrings(message.json, @"sn_uploads"))
            if (self.uploads[uploadID].state == SNUploadFailed) [self retryUpload:self.uploads[uploadID]];
    [self.waitingShares removeObjectForKey:identifier];
    if ([self heldSend:message].sendState != SNMessagePending) return;
    NSMutableArray<NSString *> *fileIDs = [NSMutableArray new];
    for (NSString *uploadID in SNJSONStrings(message.json, @"sn_uploads")) {
        SNUpload *upload = self.uploads[uploadID];
        if (!upload || upload.state == SNUploadFailed) return [self failSend:message];
        if (upload.state != SNUploadReady) {
            self.waitingShares[identifier] = message;
            return;
        }
        [fileIDs addObject:upload.fileID];
    }
    [self.sending addObject:identifier];
    NSMutableDictionary *params = [@{@"files" : [fileIDs componentsJoinedByString:@","], @"channel" : message.conversationID, @"client_msg_id" : identifier,
                                     @"broadcast" : [message.subtype isEqualToString:@"thread_broadcast"] ? @"true" : @"false", @"unfurl" : @"[]",
                                     @"resharing_aware" : @"true", @"skip_dlp_user_warning" : @"false", @"from_share_modal" : @"false",
                                     @"_x_reason" : @"send_message_with_files"} mutableCopy];
    if (message.blocks.count) params[@"blocks"] = SNJSONText(message.blocks);
    if (message.threadTS) params[@"thread_ts"] = message.threadTS;
    [self request:@"files.share" params:params priority:SNCallUserFacing completion:^(NSDictionary *response, NSError *error) {
        [self.sending removeObject:identifier];
        if (error) return [self failSend:message];
        for (NSString *uploadID in SNJSONStrings(message.json, @"sn_uploads")) {
            [self.uploads removeObjectForKey:uploadID];
            [self.retriedUploads removeObject:uploadID];
        }
        // The message arrives on the websocket (with this client_msg_id). Slack's client fetches
        // the conversation after 5 s when its connection is down; so does this, when nothing came.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if ([self heldSend:message].sendState != SNMessagePending) return;
            if (message.threadTS) [self refreshThread:message.threadTS inConversation:message.conversationID];
            if (!message.isReply) [self refreshConversation:message.conversationID priority:SNCallUserFacing];
        });
    }];
}

- (void)failSend:(SNMessage *)message {
    [self performChanges:^{
        [self updateMessage:message.ts inConversation:message.conversationID threadTS:message.threadTS transform:^SNMessage *(SNMessage *copy) {
            return copy.sendState == SNMessagePending ? [copy messageWithSendState:SNMessageFailed] : copy;
        }];
    }];
}

@end
