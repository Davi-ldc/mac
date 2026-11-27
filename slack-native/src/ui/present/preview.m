// Owns the list preview's prefix and the users it names.
#import "render/message.h"
#import "render/strings.h"
#import "ui/present/preview.h"

/// List previews: 15 pt on 22 pt lines in #f8f8f8 (components.json dm_list_row).
static const SNTextStyle kPreviewStyle = {SNFontSizeBase, SNFontWeightRegular, 22, SNColorContentPry};

SNRenderDocument *SNPreviewDocument(SNMessage *message, id<SNSource> source) { return SNPreviewDocumentWithStyle(message, source, kPreviewStyle, NO); }

SNRenderDocument *SNPreviewDocumentWithStyle(SNMessage *message, id<SNSource> source, SNTextStyle style, BOOL yours) {
    BOOL mine = yours || [message.userID isEqualToString:source.me.userID];
    return [SNRenderer previewOfMessage:message source:source style:style prefix:mine ? SNLocalized(@"dms.preview.you") : nil];
}

@interface SNMentionedUsers : SNTextSink
@property (nonatomic, readonly) NSMutableSet<NSString *> *userIDs;
@end

@implementation SNMentionedUsers

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _userIDs = [NSMutableSet new];
    return self;
}

- (void)appendUser:(NSString *)userID label:(NSString *)label { [_userIDs addObject:userID]; }

@end

NSSet<NSString *> *SNPreviewUserIDs(SNMessage *message) {
    SNMentionedUsers *users = [SNMentionedUsers new];
    SNWalkRichTextBlocks(message.blocks, users);
    SNWalkMrkdwn(message.text ?: @"", 0, users);
    return users.userIDs;
}
