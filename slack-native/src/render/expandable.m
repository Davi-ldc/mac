// Owns the expandable keys, character for character as the client's icC3 module builds them.
#import "model/json.h"
#import "render/expandable.h"
#import "render/file.h"

NSString *const SNViewContextChannel = @"Channel", *const SNViewContextThread = @"Thread";
/// isImageTooLarge: 0x1400000 bytes.
static const long long kInlineLimit = 20 * 1024 * 1024;

/// JavaScript's ts.replace(".", "_"): the first dot only.
static NSString *Underscored(NSString *ts) {
    NSRange dot = [ts rangeOfString:@"."];
    return dot.location == NSNotFound ? ts : [ts stringByReplacingCharactersInRange:dot withString:@"_"];
}

NSString *SNExpandableFilesKey(SNMessage *message, NSString *viewContext) {
    NSMutableArray<NSString *> *ids = [NSMutableArray new];
    for (SNFile *file in message.files) [ids addObject:file.fileID];
    return [NSString stringWithFormat:@"inline_files_msg_%@%@%@", Underscored(message.ts), [ids componentsJoinedByString:@"_"], viewContext];
}

NSString *SNExpandableAttachmentKey(NSDictionary *attachment, NSString *ts, NSString *viewContext) {
    id identifier = attachment[@"id"];
    // `id || image_url`: an id of 0 counts as none.
    NSString *ID = [identifier isKindOfClass:NSNumber.class] && [identifier doubleValue] ? [identifier stringValue]
                   : [identifier isKindOfClass:NSString.class] && [identifier length] ? identifier
                                                                                     : nil;
    NSString *image = SNJSONString(attachment, @"image_url"), *audio = SNJSONString(attachment, @"audio_html"), *video = SNJSONString(attachment, @"video_html");
    if (image.length) return [NSString stringWithFormat:@"img_msg_%@%@%@", ts, ID ?: image, viewContext];
    if (audio.length) return [NSString stringWithFormat:@"aud_msg_%@%@%@", ts, ID ?: audio, viewContext];
    if (video.length) return [NSString stringWithFormat:@"vid_msg_%@%@%@", ts, ID ?: SNJSONString(attachment, @"thumb_url") ?: @"undefined", viewContext];
    return nil;
}

NSString *SNExpandableBlockImageKey(NSString *ts, NSString *blockID) { return [NSString stringWithFormat:@"block_image_%@_%@", ts, blockID]; }

/// image blocks and sections with a picture as their accessory.
static NSArray<NSString *> *BlockImageKeys(NSArray *blocks, NSString *ts) {
    NSMutableArray<NSString *> *keys = [NSMutableArray new];
    for (NSDictionary *block in blocks) {
        if (![block isKindOfClass:NSDictionary.class]) continue;
        NSString *type = SNJSONString(block, @"type");
        BOOL picture = [type isEqualToString:@"image"] || ([type isEqualToString:@"section"] && [SNJSONString(SNJSONObject(block, @"accessory"), @"type") isEqualToString:@"image"]);
        if (picture) [keys addObject:SNExpandableBlockImageKey(ts, SNJSONString(block, @"block_id") ?: @"undefined")];
    }
    return keys;
}

NSArray<NSString *> *SNExpandableKeysOfMessage(SNMessage *message, NSString *viewContext) {
    if (message.files.count) return @[ SNExpandableFilesKey(message, viewContext) ];
    if (message.attachments.count) {
        NSMutableArray<NSString *> *keys = [NSMutableArray new];
        for (NSDictionary *attachment in message.attachments) {
            if (![attachment isKindOfClass:NSDictionary.class]) continue;
            NSString *key = SNExpandableAttachmentKey(attachment, message.ts, viewContext);
            if (key) [keys addObject:key];
            [keys addObjectsFromArray:BlockImageKeys(SNJSONArray(attachment, @"blocks") ?: @[], message.ts)];
        }
        return keys;
    }
    return BlockImageKeys(message.blocks, message.ts);
}

BOOL SNFilesAreExpanded(SNMessage *message, NSString *viewContext, id<SNSource> source) {
    NSNumber *chosen = [source expandedStateOfItem:SNExpandableFilesKey(message, viewContext)];
    if (chosen) return chosen.boolValue;
    for (SNFile *file in message.files)
        if (![file.mode isEqualToString:@"tombstone"] && SNFileStyleOf(file) == SNFileStyleImage)
            return SNPreferenceBool(source.preferences, @"expand_internal_inline_imgs", YES);
    return YES;
}

BOOL SNMediaIsExpanded(NSString *key, long long bytes, id<SNSource> source) {
    NSNumber *chosen = [source expandedStateOfItem:key];
    if (chosen) return chosen.boolValue;
    NSDictionary *preferences = source.preferences;
    if (!SNPreferenceBool(preferences, @"expand_inline_imgs", YES)) return NO;
    return !(bytes > kInlineLimit && SNPreferenceBool(preferences, @"obey_inline_img_limit", NO));
}
