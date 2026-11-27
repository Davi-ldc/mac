// Owns decoding messages, reactions and files, and ordering timestamps.
#import "model/json.h"
#import "model/message.h"

NSComparisonResult SNCompareTS(NSString *a, NSString *b) {
    NSRange dotA = [a rangeOfString:@"."], dotB = [b rangeOfString:@"."];
    NSUInteger secondsA = dotA.location == NSNotFound ? a.length : dotA.location;
    NSUInteger secondsB = dotB.location == NSNotFound ? b.length : dotB.location;
    if (secondsA != secondsB) return secondsA < secondsB ? NSOrderedAscending : NSOrderedDescending;
    return [a compare:b options:NSNumericSearch];
}

@implementation SNReaction

+ (instancetype)reactionWithJSON:(NSDictionary *)json {
    NSString *name = SNJSONString(json, @"name");
    if (!name.length) return nil;
    SNReaction *reaction = [self new];
    reaction->_name = name;
    reaction->_userIDs = SNJSONStrings(json, @"users");
    reaction->_count = MAX(SNJSONInteger(json, @"count"), (NSInteger)reaction->_userIDs.count);
    return reaction;
}

+ (instancetype)reactionWithName:(NSString *)name userIDs:(NSArray<NSString *> *)userIDs count:(NSInteger)count {
    SNReaction *reaction = [self new];
    reaction->_name = name;
    reaction->_userIDs = [userIDs copy];
    reaction->_count = count;
    return reaction;
}

- (NSDictionary *)json { return @{@"name" : self.name, @"users" : self.userIDs, @"count" : @(self.count)}; }
- (id)copyWithZone:(NSZone *)zone { return self; }

@end

@implementation SNFile

+ (instancetype)fileWithJSON:(NSDictionary *)json {
    NSString *fileID = SNJSONString(json, @"id");
    if (!fileID.length) return nil;
    SNFile *file = [self new];
    file->_fileID = fileID;
    file->_name = SNJSONString(json, @"name") ?: @"";
    file->_title = SNJSONString(json, @"title") ?: file->_name;
    file->_mimeType = SNJSONString(json, @"mimetype");
    file->_fileType = SNJSONString(json, @"filetype");
    file->_prettyType = SNJSONString(json, @"pretty_type");
    file->_size = SNJSONInteger(json, @"size");
    file->_userID = SNJSONString(json, @"user");
    file->_privateURL = SNJSONURL(json, @"url_private");
    file->_downloadURL = SNJSONURL(json, @"url_private_download");
    file->_permalink = SNJSONURL(json, @"permalink");
    file->_thumbnailURLs = SNJSONSizedURLs(json, @"thumb_");
    file->_originalSize = CGSizeMake(SNJSONDouble(json, @"original_w"), SNJSONDouble(json, @"original_h"));
    file->_mode = SNJSONString(json, @"mode");
    file->_subtype = SNJSONString(json, @"subtype");
    file->_videoThumbnailURL = SNJSONURL(json, @"thumb_video");
    file->_videoThumbnailSize = CGSizeMake(SNJSONDouble(json, @"thumb_video_w"), SNJSONDouble(json, @"thumb_video_h"));
    file->_mp4URL = SNJSONURL(json, @"mp4");
    file->_aacURL = SNJSONURL(json, @"aac");
    file->_pdfThumbnailURL = SNJSONURL(json, @"thumb_pdf");
    file->_pdfThumbnailSize = CGSizeMake(SNJSONDouble(json, @"thumb_pdf_w"), SNJSONDouble(json, @"thumb_pdf_h"));
    file->_duration = SNJSONDouble(json, @"duration_ms") / 1000;
    NSDictionary *transcription = SNJSONObject(json, @"transcription");
    file->_transcriptionStatus = SNJSONString(transcription, @"status");
    file->_transcriptionPreview = SNJSONString(SNJSONObject(transcription, @"preview"), @"content");
    file->_transcriptionHasMore = SNJSONBool(SNJSONObject(transcription, @"preview"), @"has_more");
    NSDictionary *progress = SNJSONObject(json, @"media_progress");
    file->_playbackOffset = SNJSONBool(progress, @"media_watched") ? 0 : SNJSONDouble(progress, @"offset_ms") / 1000;
    NSMutableArray *samples = [NSMutableArray new];
    for (id sample in SNJSONArray(json, @"audio_wave_samples") ?: @[])
        if ([sample isKindOfClass:NSNumber.class]) [samples addObject:sample];
    file->_waveform = samples;
    file->_preview = SNJSONString(json, @"preview");
    file->_previewHighlight = SNJSONString(json, @"preview_highlight");
    file->_lineCount = SNJSONInteger(json, @"lines");
    file->_moreLineCount = SNJSONInteger(json, @"lines_more");
    file->_previewIsTruncated = SNJSONBool(json, @"preview_is_truncated");
    file->_isExternal = SNJSONBool(json, @"is_external");
    file->_externalType = SNJSONString(json, @"external_type");
    NSURL *local = [NSURL URLWithString:SNJSONString(json, @"sn_local_url") ?: @""];
    file->_localURL = local.isFileURL ? local : nil;
    file->_created = SNJSONDouble(json, @"created");
    file->_timestamp = SNJSONDouble(json, @"timestamp");
    file->_updated = SNJSONDouble(json, @"updated");
    double lastRead = SNJSONDouble(json, @"last_read");
    file->_lastRead = lastRead >= 1e10 ? floor(lastRead / 1000) : lastRead;
    file->_userName = SNJSONString(json, @"username");
    return file;
}

- (NSDictionary *)json {
    NSMutableDictionary *dict = [NSMutableDictionary new];
    dict[@"id"] = _fileID;
    if (_name.length) dict[@"name"] = _name;
    if (_title.length) dict[@"title"] = _title;
    if (_mimeType) dict[@"mimetype"] = _mimeType;
    if (_fileType) dict[@"filetype"] = _fileType;
    if (_prettyType) dict[@"pretty_type"] = _prettyType;
    if (_size) dict[@"size"] = @(_size);
    if (_userID) dict[@"user"] = _userID;
    if (_privateURL) dict[@"url_private"] = _privateURL.absoluteString;
    if (_downloadURL) dict[@"url_private_download"] = _downloadURL.absoluteString;
    if (_permalink) dict[@"permalink"] = _permalink.absoluteString;
    [_thumbnailURLs enumerateKeysAndObjectsUsingBlock:^(NSNumber *size, NSURL *url, BOOL *stop) {
        dict[[NSString stringWithFormat:@"thumb_%@", size]] = url.absoluteString;
    }];
    if (_originalSize.width > 0) dict[@"original_w"] = @(_originalSize.width);
    if (_originalSize.height > 0) dict[@"original_h"] = @(_originalSize.height);
    if (_mode) dict[@"mode"] = _mode;
    if (_subtype) dict[@"subtype"] = _subtype;
    if (_videoThumbnailURL) dict[@"thumb_video"] = _videoThumbnailURL.absoluteString;
    if (_videoThumbnailSize.width > 0) dict[@"thumb_video_w"] = @(_videoThumbnailSize.width);
    if (_videoThumbnailSize.height > 0) dict[@"thumb_video_h"] = @(_videoThumbnailSize.height);
    if (_mp4URL) dict[@"mp4"] = _mp4URL.absoluteString;
    if (_aacURL) dict[@"aac"] = _aacURL.absoluteString;
    if (_pdfThumbnailURL) dict[@"thumb_pdf"] = _pdfThumbnailURL.absoluteString;
    if (_pdfThumbnailSize.width > 0) dict[@"thumb_pdf_w"] = @(_pdfThumbnailSize.width);
    if (_pdfThumbnailSize.height > 0) dict[@"thumb_pdf_h"] = @(_pdfThumbnailSize.height);
    if (_duration > 0) dict[@"duration_ms"] = @(_duration * 1000);
    if (_transcriptionStatus || _transcriptionPreview) {
        NSMutableDictionary *tr = [NSMutableDictionary new];
        if (_transcriptionStatus) tr[@"status"] = _transcriptionStatus;
        if (_transcriptionPreview) tr[@"preview"] = @{@"content" : _transcriptionPreview, @"has_more" : @(_transcriptionHasMore)};
        dict[@"transcription"] = tr;
    }
    if (_playbackOffset > 0) dict[@"media_progress"] = @{@"offset_ms" : @(_playbackOffset * 1000)};
    if (_waveform.count) dict[@"audio_wave_samples"] = _waveform;
    if (_preview) dict[@"preview"] = _preview;
    if (_previewHighlight) dict[@"preview_highlight"] = _previewHighlight;
    if (_lineCount) dict[@"lines"] = @(_lineCount);
    if (_moreLineCount) dict[@"lines_more"] = @(_moreLineCount);
    if (_previewIsTruncated) dict[@"preview_is_truncated"] = @YES;
    if (_isExternal) dict[@"is_external"] = @YES;
    if (_externalType) dict[@"external_type"] = _externalType;
    if (_localURL) dict[@"sn_local_url"] = _localURL.absoluteString;
    if (_created) dict[@"created"] = @(_created);
    if (_timestamp) dict[@"timestamp"] = @(_timestamp);
    if (_updated) dict[@"updated"] = @(_updated);
    if (_lastRead) dict[@"last_read"] = @(_lastRead);
    if (_userName) dict[@"username"] = _userName;
    return dict;
}

- (NSURL *)thumbnailURLForPixels:(CGFloat)pixels {
    if (self.localURL) return self.localURL;
    // Slack makes no thumbnail bigger than the picture, so one shown at its own size on a 2x
    // screen is sharpest from the original.
    CGFloat original = MAX(self.originalSize.width, self.originalSize.height);
    if (original <= 0 || !self.privateURL || ![self.mimeType hasPrefix:@"image/"]) return SNBestURL(self.thumbnailURLs, pixels);
    NSMutableDictionary *urls = [self.thumbnailURLs mutableCopy];
    urls[@(original)] = self.privateURL;
    return SNBestURL(urls, pixels);
}
- (id)copyWithZone:(NSZone *)zone { return self; }

@end

/// The local send state rides in the JSON so it is persisted and patched like the rest.
static NSString *const SendStateKey = @"sn_send_state";

@implementation SNMessage {
    BOOL _isEphemeral;
    NSString *_ephemeralType;
    NSString *_editedUser;
    NSString *_lastRead;
    NSString *_botUserID;
    NSDictionary *_saved;
    NSDictionary *_room;
    NSDictionary *_root;
    NSArray<NSString *> *_uploadIDs;
    NSDictionary *_systemFields;
}

+ (instancetype)messageWithJSON:(NSDictionary *)json conversationID:(NSString *)conversationID {
    NSString *ts = SNJSONString(json, @"ts");
    if (!ts.length) return nil;
    SNMessage *message = [self new];
    message->_ts = ts;
    message->_conversationID = conversationID ?: SNJSONString(json, @"channel");
    message->_userID = SNJSONString(json, @"user");
    message->_botID = SNJSONString(json, @"bot_id");
    NSDictionary *bot = SNJSONObject(json, @"bot_profile");
    message->_username = SNJSONString(json, @"username") ?: SNJSONString(bot, @"name");
    message->_botUserID = SNJSONString(bot, @"user_id");
    NSDictionary *icons = SNJSONObject(bot, @"icons") ?: SNJSONObject(json, @"icons");
    message->_botIconURLs = SNJSONSizedURLs(icons, @"image_");
    message->_subtype = SNJSONString(json, @"subtype");
    message->_text = SNJSONString(json, @"text") ?: @"";
    message->_blocks = SNJSONMap(json, @"blocks", ^id(NSDictionary *item) { return item; });
    message->_attachments = SNJSONMap(json, @"attachments", ^id(NSDictionary *item) { return item; });
    message->_files = SNJSONMap(json, @"files", ^id(NSDictionary *item) { return [SNFile fileWithJSON:item]; });
    message->_reactions = SNJSONMap(json, @"reactions", ^id(NSDictionary *item) { return [SNReaction reactionWithJSON:item]; });
    message->_threadTS = SNJSONString(json, @"thread_ts");
    message->_replyCount = SNJSONInteger(json, @"reply_count");
    message->_replyUsersCount = SNJSONInteger(json, @"reply_users_count");
    message->_replyUserIDs = SNJSONStrings(json, @"reply_users");
    message->_latestReply = SNJSONString(json, @"latest_reply");
    NSDictionary *edited = SNJSONObject(json, @"edited");
    message->_editedTS = SNJSONString(edited, @"ts");
    message->_editedUser = SNJSONString(edited, @"user");
    message->_clientMessageID = SNJSONString(json, @"client_msg_id");
    message->_isPinned = SNJSONArray(json, @"pinned_to").count > 0;
    message->_isStarred = SNJSONBool(json, @"is_starred");
    message->_isEphemeral = SNJSONBool(json, @"is_ephemeral");
    message->_ephemeralType = SNJSONString(json, @"_ephemeral_type");
    message->_lastRead = SNJSONString(json, @"last_read");
    message->_saved = SNJSONObject(json, @"saved");
    message->_room = SNJSONObject(json, @"room");
    message->_root = SNJSONObject(json, @"root");
    NSArray<NSString *> *uploads = SNJSONStrings(json, @"sn_uploads");
    if (uploads.count) message->_uploadIDs = uploads;
    if (message->_subtype) {
        NSMutableDictionary *sys = nil;
        for (NSString *key in @[ @"old_name", @"name", @"purpose", @"topic", @"bot_link" ]) {
            NSString *val = SNJSONString(json, key);
            if (val) {
                if (!sys) sys = [NSMutableDictionary new];
                sys[key] = val;
            }
        }
        message->_systemFields = sys;
    }
    NSString *state = SNJSONString(json, SendStateKey);
    message->_sendState = [state isEqualToString:@"pending"] ? SNMessagePending : [state isEqualToString:@"failed"] ? SNMessageFailed : SNMessageSent;
    return message;
}

- (NSDictionary *)json {
    NSMutableDictionary *dict = [NSMutableDictionary new];
    dict[@"type"] = @"message";
    dict[@"ts"] = _ts;
    if (_userID) dict[@"user"] = _userID;
    if (_botID) dict[@"bot_id"] = _botID;
    if (_username) dict[@"username"] = _username;
    if (_botUserID || _botIconURLs.count) {
        NSMutableDictionary *bp = [NSMutableDictionary new];
        if (_botUserID) bp[@"user_id"] = _botUserID;
        if (_username) bp[@"name"] = _username;
        if (_botIconURLs.count) {
            NSMutableDictionary *icons = [NSMutableDictionary new];
            [_botIconURLs enumerateKeysAndObjectsUsingBlock:^(NSNumber *size, NSURL *url, BOOL *stop) {
                icons[[NSString stringWithFormat:@"image_%@", size]] = url.absoluteString;
            }];
            bp[@"icons"] = icons;
        }
        dict[@"bot_profile"] = bp;
    }
    if (_subtype) dict[@"subtype"] = _subtype;
    dict[@"text"] = _text;
    if (_blocks.count) dict[@"blocks"] = _blocks;
    if (_attachments.count) dict[@"attachments"] = _attachments;
    if (_files.count) dict[@"files"] = [_files valueForKey:@"json"];
    if (_reactions.count) dict[@"reactions"] = [_reactions valueForKey:@"json"];
    if (_threadTS) dict[@"thread_ts"] = _threadTS;
    if (_replyCount) dict[@"reply_count"] = @(_replyCount);
    if (_replyUsersCount) dict[@"reply_users_count"] = @(_replyUsersCount);
    if (_replyUserIDs.count) dict[@"reply_users"] = _replyUserIDs;
    if (_latestReply) dict[@"latest_reply"] = _latestReply;
    if (_editedTS) {
        NSMutableDictionary *ed = [@{@"ts" : _editedTS} mutableCopy];
        if (_editedUser) ed[@"user"] = _editedUser;
        dict[@"edited"] = ed;
    }
    if (_clientMessageID) dict[@"client_msg_id"] = _clientMessageID;
    if (_isPinned) dict[@"pinned_to"] = @[ _conversationID ?: @"" ];
    if (_isStarred) dict[@"is_starred"] = @YES;
    if (_isEphemeral) dict[@"is_ephemeral"] = @YES;
    if (_ephemeralType) dict[@"_ephemeral_type"] = _ephemeralType;
    if (_lastRead) dict[@"last_read"] = _lastRead;
    if (_saved) dict[@"saved"] = _saved;
    if (_room) dict[@"room"] = _room;
    if (_root) dict[@"root"] = _root;
    if (_uploadIDs.count) dict[@"sn_uploads"] = _uploadIDs;
    if (_systemFields) [dict addEntriesFromDictionary:_systemFields];
    if (_sendState == SNMessagePending) dict[SendStateKey] = @"pending";
    else if (_sendState == SNMessageFailed) dict[SendStateKey] = @"failed";
    return dict;
}

- (NSDate *)date { return [NSDate dateWithTimeIntervalSince1970:self.ts.doubleValue]; }
- (NSString *)identifier { return self.clientMessageID.length ? self.clientMessageID : self.ts; }

- (BOOL)isReply {
    return self.threadTS && ![self.threadTS isEqualToString:self.ts] && ![self.subtype isEqualToString:@"thread_broadcast"];
}

- (BOOL)isThreadParent { return [self.threadTS isEqualToString:self.ts]; }

- (instancetype)messageByMergingJSON:(NSDictionary *)changes {
    return [SNMessage messageWithJSON:SNJSONMerge(self.json, changes) conversationID:self.conversationID] ?: self;
}

- (instancetype)messageWithReactions:(NSArray<SNReaction *> *)reactions {
    return [self messageByMergingJSON:@{@"reactions" : reactions.count ? [reactions valueForKey:@"json"] : NSNull.null}];
}

- (BOOL)isEphemeral { return _isEphemeral; }

- (instancetype)messageWithSendState:(SNMessageSendState)sendState {
    id state = sendState == SNMessagePending ? @"pending" : sendState == SNMessageFailed ? @"failed" : NSNull.null;
    return [self messageByMergingJSON:@{SendStateKey : state}];
}

/// Calls `visit` with every rich_text element of the blocks, however deeply nested.
static void VisitElements(NSArray *elements, void (^visit)(NSDictionary *element)) {
    for (NSDictionary *element in elements) {
        if (![element isKindOfClass:NSDictionary.class]) continue;
        visit(element);
        VisitElements(SNJSONArray(element, @"elements"), visit);
    }
}

- (BOOL)mentionsUser:(NSString *)userID {
    if ([self.text containsString:[NSString stringWithFormat:@"<@%@>", userID]] ||
        [self.text containsString:[NSString stringWithFormat:@"<@%@|", userID]])
        return YES;
    __block BOOL found = NO;
    VisitElements(self.blocks, ^(NSDictionary *element) {
        found = found || ([SNJSONString(element, @"type") isEqualToString:@"user"] && [SNJSONString(element, @"user_id") isEqualToString:userID]);
    });
    return found;
}

- (BOOL)mentionsEveryone {
    for (NSString *mention in @[ @"<!here", @"<!channel", @"<!everyone" ])
        if ([self.text containsString:mention]) return YES;
    __block BOOL found = NO;
    VisitElements(self.blocks, ^(NSDictionary *element) {
        found = found || [SNJSONString(element, @"type") isEqualToString:@"broadcast"];
    });
    return found;
}

- (BOOL)mentionsAnyone {
    for (NSString *mention in @[ @"<@", @"<!subteam^", @"<#" ])
        if ([self.text containsString:mention]) return YES;
    __block BOOL found = NO;
    VisitElements(self.blocks, ^(NSDictionary *element) {
        found = found || [@[ @"user", @"usergroup", @"channel" ] containsObject:SNJSONString(element, @"type") ?: @""];
    });
    return found;
}

- (NSURL *)permalinkInWorkspace:(SNWorkspace *)workspace {
    if (!workspace.url || !self.conversationID) return nil;
    NSString *digits = [self.ts stringByReplacingOccurrencesOfString:@"." withString:@""];
    NSString *path = [NSString stringWithFormat:@"archives/%@/p%@", self.conversationID, digits];
    if (self.isReply) path = [path stringByAppendingFormat:@"?thread_ts=%@&cid=%@", self.threadTS, self.conversationID];
    return [NSURL URLWithString:path relativeToURL:workspace.url].absoluteURL;
}

- (id)copyWithZone:(NSZone *)zone { return self; }

@end
