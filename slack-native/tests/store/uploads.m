// Attached files in the requests the web client's upload queue sends (read from its static JS;
// values made up): files.getUploadURL, the multipart POST, files.completeUpload, file_created,
// one file at a time, one automatic retry, removal, and files.share with the message's blocks.
#import "../net/stub.h"
#import "model/json.h"
#import "net/client.h"
#import "store/store.h"
#import "test.h"

static SNStore *UploadStore(id<SNAPI> api) {
    SNStore *store = [[SNStore alloc] initWithDatabase:nil api:api];
    [store performChanges:^{
        [store applyWorkspace:@{@"id" : @"T0NORTHWND", @"name" : @"Northwind Studio", @"domain" : @"northwind-studio"}];
        [store applySelfUserID:@"U01ALEX"];
        [store applyUsers:@[ @{@"id" : @"U01ALEX", @"name" : @"alex", @"profile" : @{@"real_name" : @"Alex Rivera"}} ]];
        [store applyConversations:@[ @{@"id" : @"C01GENERAL", @"name" : @"general", @"is_channel" : @YES, @"is_member" : @YES} ]];
    }];
    store.connectionState = SNConnectionConnected;
    return store;
}

static NSURL *LocalFile(NSString *name, NSString *contents) {
    NSURL *folder = [NSFileManager.defaultManager.temporaryDirectory URLByAppendingPathComponent:@"slack-native-tests/uploads" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *url = [folder URLByAppendingPathComponent:name];
    [contents writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return url;
}

/// files.getUploadURL answers a new file ID each time, as Slack does.
static SNTestAPI *UploadAPI(void) {
    SNTestAPI *api = [SNTestAPI new];
    __block NSInteger files = 0;
    api.answer = ^NSDictionary *(NSString *method, NSDictionary *params) {
        if ([method isEqualToString:@"files.getUploadURL"]) {
            files++;
            return @{@"ok" : @YES, @"file" : [NSString stringWithFormat:@"F0UPLOAD%ld", (long)files],
                     @"upload_url" : [NSString stringWithFormat:@"https://files.slack.com/upload/v1/CwABAAAAXQoAAZ%ld", (long)files]};
        }
        return @{@"ok" : @YES};
    };
    return api;
}

static NSArray<NSArray *> *Calls(SNTestAPI *api, NSString *method) {
    return [api.calls filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSArray *call, NSDictionary *bindings) { return [call[0] isEqualToString:method]; }]];
}

static id JSON(NSString *text) { return [NSJSONSerialization JSONObjectWithData:[text ?: @"" dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil]; }

SN_TEST(StoreUploadsAttachedFilesOneAtATime) {
    SNTestAPI *api = UploadAPI();
    SNStore *store = UploadStore(api);
    [store attachFiles:@[ LocalFile(@"notes.txt", @"twelve bytes"), LocalFile(@"plan.csv", @"a,b") ] inConversation:@"C01GENERAL" threadTS:nil];
    NSArray<SNUpload *> *uploads = [store uploadsInConversation:@"C01GENERAL" threadTS:nil];
    SNExpect(uploads.count == 2 && [uploads[0].name isEqualToString:@"notes.txt"] && [uploads[0].mimeType isEqualToString:@"text/plain"] && uploads[0].size == 12,
             "attached files are listed on their composer at once, in order, with name, type and size");
    SNExpect([store uploadsInConversation:@"C01GENERAL" threadTS:@"1795400000.000100"].count == 0, "a thread's composer has its own files");
    SNWaitUntil(2, ^BOOL { return [store uploadsInConversation:@"C01GENERAL" threadTS:nil][0].state == SNUploadProcessing; });
    NSDictionary *asked = Calls(api, @"files.getUploadURL").firstObject[1];
    SNExpect([asked[@"filename"] isEqualToString:@"notes.txt"] && [asked[@"length"] isEqualToString:@"12"] && [asked[@"_x_reason"] isEqualToString:@"upload-queue"],
             "files.getUploadURL with the file's name and length");
    NSDictionary *posted = Calls(api, @"upload").firstObject[1];
    SNExpect([posted[@"url"] isEqualToString:@"https://files.slack.com/upload/v1/CwABAAAAXQoAAZ1"] && [posted[@"name"] isEqualToString:@"notes.txt"] &&
                 [posted[@"mimeType"] isEqualToString:@"text/plain"],
             "the bytes go to the upload URL Slack answered");
    NSArray *completed = JSON(Calls(api, @"files.completeUpload").firstObject[1][@"files"]);
    NSArray *named = @[ @{@"id" : @"F0UPLOAD1", @"title" : @"notes.txt"} ];
    SNExpect([completed isEqualToArray:named], "files.completeUpload names the file and its title as JSON");
    SNExpect(Calls(api, @"files.getUploadURL").count == 1, "the next file waits until Slack made this one");
    [store applyEvent:@{@"type" : @"file_created", @"file_id" : @"F0UPLOAD1", @"file" : @{@"id" : @"F0UPLOAD1"}}];
    SNExpect([store uploadsInConversation:@"C01GENERAL" threadTS:nil][0].state == SNUploadReady, "file_created makes it ready to share");
    SNWaitUntil(2, ^BOOL { return [store uploadsInConversation:@"C01GENERAL" threadTS:nil][1].state == SNUploadProcessing; });
    SNExpect(Calls(api, @"files.getUploadURL").count == 2 && [store uploadsInConversation:@"C01GENERAL" threadTS:nil][1].fileID, "then the next one goes");
}

SN_TEST(StoreRetriesAFailedUploadOnceByItself) {
    SNTestAPI *api = UploadAPI();
    __block NSInteger posts = 0;
    api.uploadStatus = ^NSInteger(NSURL *url, NSString *name) { return ++posts <= 2 ? 500 : 200; };
    SNStore *store = UploadStore(api);
    [store attachFiles:@[ LocalFile(@"notes.txt", @"twelve bytes") ] inConversation:@"C01GENERAL" threadTS:nil];
    SNWaitUntil(2, ^BOOL { return [store uploadsInConversation:@"C01GENERAL" threadTS:nil][0].state == SNUploadFailed; });
    SNUpload *failed = [store uploadsInConversation:@"C01GENERAL" threadTS:nil][0];
    SNExpect(failed.state == SNUploadFailed && posts == 2 && Calls(api, @"files.getUploadURL").count == 2 && !Calls(api, @"files.completeUpload").count,
             "the first failure starts over with a new upload URL; the second leaves the file failed");
    [store sendText:@"" blocks:nil uploads:@[ failed ] inConversation:@"C01GENERAL" threadTS:nil broadcast:NO];
    SNExpect(SNWaitUntil(2, ^BOOL { return Calls(api, @"files.completeUpload").count == 1; }) && posts == 3, "sending it uploads it again, as Slack's client does");
}

SN_TEST(StoreRemovesAttachedFiles) {
    SNTestAPI *api = UploadAPI();
    SNStore *store = UploadStore(api);
    [store attachFiles:@[ LocalFile(@"a.txt", @"a"), LocalFile(@"b.txt", @"b") ] inConversation:@"C01GENERAL" threadTS:nil];
    SNWaitUntil(2, ^BOOL { return [store uploadsInConversation:@"C01GENERAL" threadTS:nil][0].state == SNUploadProcessing; });
    [store applyEvent:@{@"type" : @"file_created", @"file_id" : @"F0UPLOAD1"}];
    SNUpload *ready = [store uploadsInConversation:@"C01GENERAL" threadTS:nil][0];
    [store removeUpload:ready];
    NSDictionary *deleted = Calls(api, @"files.delete").lastObject[1];
    SNExpect([deleted[@"file"] isEqualToString:@"F0UPLOAD1"] && [deleted[@"is_draft"] isEqualToString:@"true"] && [deleted[@"_x_reason"] isEqualToString:@"delete_draft_file"],
             "a file already on Slack is deleted as a draft's file");
    SNUpload *going = [store uploadsInConversation:@"C01GENERAL" threadTS:nil][0];
    [store removeUpload:going];
    SNSettle(0.2);
    SNExpect([store uploadsInConversation:@"C01GENERAL" threadTS:nil].count == 0, "removed files leave the composer");
    SNExpect(Calls(api, @"files.delete").count == 1 + (going.state == SNUploadReady), "one still uploading is only stopped");
}

SN_TEST(StoreSharesFilesWithTheirMessage) {
    SNTestAPI *api = UploadAPI();
    SNStore *store = UploadStore(api);
    [store applyNewestHistory:@{@"messages" : @[ @{@"type" : @"message", @"ts" : @"1795400000.000100", @"user" : @"U01ALEX", @"text" : @"parent"} ], @"has_more" : @NO}
               inConversation:@"C01GENERAL"];
    [store attachFiles:@[ LocalFile(@"notes.txt", @"twelve bytes") ] inConversation:@"C01GENERAL" threadTS:@"1795400000.000100"];
    NSArray *blocks = @[ @{@"type" : @"rich_text", @"elements" : @[ @{@"type" : @"rich_text_section", @"elements" : @[ @{@"type" : @"text", @"text" : @"see this"} ]} ]} ];
    SNMessage *pending = [store sendText:@"see this" blocks:blocks uploads:[store uploadsInConversation:@"C01GENERAL" threadTS:@"1795400000.000100"]
                          inConversation:@"C01GENERAL" threadTS:@"1795400000.000100" broadcast:NO];
    SNExpect(pending.sendState == SNMessagePending && pending.files.count == 1 && [pending.files[0].name isEqualToString:@"notes.txt"] && pending.files[0].localURL.isFileURL,
             "the message shows its file from this device at once");
    SNExpect([store uploadsInConversation:@"C01GENERAL" threadTS:@"1795400000.000100"].count == 0, "the files leave the composer with the message");
    SNWaitUntil(2, ^BOOL { return Calls(api, @"files.completeUpload").count == 1; });
    SNSettle(0.05);
    SNExpect(!Calls(api, @"files.share").count, "files.share waits for Slack to make the file");
    [store applyEvent:@{@"type" : @"file_created", @"file_id" : @"F0UPLOAD1"}];
    SNWaitUntil(2, ^BOOL { return Calls(api, @"files.share").count == 1; });
    NSDictionary *shared = Calls(api, @"files.share").firstObject[1];
    SNExpect([shared[@"files"] isEqualToString:@"F0UPLOAD1"] && [shared[@"channel"] isEqualToString:@"C01GENERAL"] &&
                 [shared[@"thread_ts"] isEqualToString:@"1795400000.000100"] && [shared[@"client_msg_id"] isEqualToString:pending.clientMessageID] &&
                 [JSON(shared[@"blocks"]) isEqualToArray:blocks] && [shared[@"broadcast"] isEqualToString:@"false"] &&
                 [shared[@"resharing_aware"] isEqualToString:@"true"] && [shared[@"_x_reason"] isEqualToString:@"send_message_with_files"] && !shared[@"text"],
             "files.share with the file IDs, the thread, the message's blocks and its client_msg_id");
    NSDictionary *file = @{@"id" : @"F0UPLOAD1", @"name" : @"notes.txt", @"title" : @"notes.txt", @"mimetype" : @"text/plain", @"filetype" : @"text",
                           @"pretty_type" : @"Plain Text", @"size" : @12, @"mode" : @"snippet", @"url_private" : @"https://files.slack.com/files-pri/T0NORTHWND-F0UPLOAD1/notes.txt"};
    [store applyEvent:@{@"type" : @"message", @"channel" : @"C01GENERAL", @"user" : @"U01ALEX", @"text" : @"see this", @"blocks" : blocks, @"files" : @[ file ],
                        @"upload" : @YES, @"display_as_bot" : @NO, @"ts" : @"1795400050.000200", @"thread_ts" : @"1795400000.000100",
                        @"client_msg_id" : pending.clientMessageID}];
    NSArray<SNMessage *> *thread = [store threadInConversation:@"C01GENERAL" ts:@"1795400000.000100"];
    SNExpect(thread.count == 2 && thread[1].sendState == SNMessageSent && [thread[1].ts isEqualToString:@"1795400050.000200"] && !thread[1].files[0].localURL &&
                 [thread[1].identifier isEqualToString:pending.identifier],
             "Slack's copy from the websocket replaces it in place");
}

SN_TEST(StoreFailsAFileMessageWhoseUploadFailed) {
    SNTestAPI *api = UploadAPI();
    __block BOOL down = YES;
    api.uploadStatus = ^NSInteger(NSURL *url, NSString *name) { return down ? 0 : 200; };
    SNStore *store = UploadStore(api);
    [store attachFiles:@[ LocalFile(@"notes.txt", @"twelve bytes") ] inConversation:@"C01GENERAL" threadTS:nil];
    SNMessage *pending = [store sendText:@"" blocks:nil uploads:[store uploadsInConversation:@"C01GENERAL" threadTS:nil] inConversation:@"C01GENERAL"
                                threadTS:nil broadcast:NO];
    SNWaitUntil(2, ^BOOL { return [store messagesInConversation:@"C01GENERAL"].lastObject.sendState == SNMessageFailed; });
    SNExpect([store messagesInConversation:@"C01GENERAL"].lastObject.sendState == SNMessageFailed && !Calls(api, @"files.share").count,
             "the message fails with its file");
    down = NO;
    [store retrySendingMessage:[store messagesInConversation:@"C01GENERAL"].lastObject];
    SNWaitUntil(2, ^BOOL { return Calls(api, @"files.completeUpload").count == 1; });
    [store applyEvent:@{@"type" : @"file_created", @"file_id" : @"F0UPLOAD3"}];
    SNWaitUntil(2, ^BOOL { return Calls(api, @"files.share").count == 1; });
    NSDictionary *shared = Calls(api, @"files.share").firstObject[1];
    SNExpect([shared[@"files"] isEqualToString:@"F0UPLOAD3"] && [shared[@"client_msg_id"] isEqualToString:pending.clientMessageID] && !shared[@"blocks"],
             "Retry uploads the file again and shares it; a message of files alone has no blocks");
}

SN_TEST(ClientWritesUploadsAsABrowserForm) {
    NSURL *file = LocalFile(@"say \"hi\".txt", @"twelve bytes");
    NSURL *body = [file URLByAppendingPathExtension:@"body"];
    SNExpect(SNWriteMultipartBody(file, file.lastPathComponent, @"text/plain", @"----WebKitFormBoundaryAbCdEfGh12345678", body), "the body is written");
    NSString *text = [NSString stringWithContentsOfURL:body encoding:NSUTF8StringEncoding error:nil];
    NSString *expected = @"------WebKitFormBoundaryAbCdEfGh12345678\r\nContent-Disposition: form-data; name=\"file\"; filename=\"say %22hi%22.txt\"\r\n"
                         @"Content-Type: text/plain\r\n\r\ntwelve bytes\r\n------WebKitFormBoundaryAbCdEfGh12345678--\r\n";
    SNExpect([text isEqualToString:expected], "one \"file\" part with the file's name (quotes escaped as browsers do) and type");
    SNExpect(!SNWriteMultipartBody([file URLByAppendingPathExtension:@"missing"], @"x", @"text/plain", @"b", body), "a file that cannot be read is refused");
}
