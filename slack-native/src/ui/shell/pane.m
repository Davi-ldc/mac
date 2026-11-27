// Owns the pane registry and locations.
#import "ui/shell/pane.h"

static Class registered[3];

void SNRegisterPane(SNPaneSlot slot, Class<SNPane> _Nullable paneClass) { registered[slot] = paneClass; }
Class<SNPane> SNRegisteredPane(SNPaneSlot slot) { return registered[slot]; }

NSString *const SNPageChannels = @"channels", *const SNPageFiles = @"files", *const SNPageFilesCanvases = @"files/canvases",
                *const SNPageFilesLists = @"files/lists", *const SNPageConversationFiles = @"conversation/files";
NSString *const SNPanelShortcuts = @"shortcuts", *const SNPanelFeedback = @"feedback";

static NSString *feedbackStartText;
void SNSetFeedbackStartText(NSString *text) { feedbackStartText = [text copy]; }

NSString *SNTakeFeedbackStartText(void) {
    NSString *text = feedbackStartText;
    feedbackStartText = nil;
    return text;
}
static NSString *const kProfilePrefix = @"profile:";

NSString *SNPanelProfile(NSString *userID) { return [kProfilePrefix stringByAppendingString:userID]; }

NSString *SNPanelProfileUserID(NSString *panel) {
    return [panel hasPrefix:kProfilePrefix] && panel.length > kProfilePrefix.length ? [panel substringFromIndex:kProfilePrefix.length] : nil;
}

static BOOL Same(NSString *a, NSString *b) { return a == b || [a isEqualToString:b]; }

@implementation SNLocation

+ (instancetype)locationWithTab:(SNTab)tab conversation:(NSString *)conversationID thread:(NSString *)threadTS {
    return [self locationWithTab:tab conversation:conversationID thread:threadTS page:nil panel:nil];
}

+ (instancetype)locationWithTab:(SNTab)tab conversation:(NSString *)conversationID thread:(NSString *)threadTS page:(NSString *)page panel:(NSString *)panel {
    SNLocation *location = [self new];
    location->_tab = tab;
    location->_conversationID = [conversationID copy];
    location->_threadTS = conversationID ? [threadTS copy] : nil;
    location->_page = conversationID && ![page isEqualToString:SNPageConversationFiles] ? nil : [page copy];
    location->_panel = location->_threadTS ? nil : [panel copy];
    return location;
}

- (SNLocation *)locationWithPanel:(NSString *)panel {
    return [SNLocation locationWithTab:_tab conversation:_conversationID thread:nil page:_page panel:panel];
}

- (SNLocation *)locationWithMessage:(NSString *)messageTS {
    SNLocation *location = [SNLocation locationWithTab:_tab conversation:_conversationID thread:_threadTS page:_page panel:_panel];
    location->_messageTS = _conversationID ? [messageTS copy] : nil;
    return location;
}

- (BOOL)isEqual:(SNLocation *)other {
    return [other isKindOfClass:SNLocation.class] && other.tab == self.tab && Same(other.conversationID, self.conversationID) && Same(other.threadTS, self.threadTS) &&
           Same(other.page, self.page) && Same(other.panel, self.panel) && Same(other.messageTS, self.messageTS);
}

- (NSUInteger)hash { return self.conversationID.hash ^ self.threadTS.hash ^ self.page.hash ^ self.panel.hash ^ self.messageTS.hash ^ (NSUInteger)self.tab; }
- (id)copyWithZone:(NSZone *)zone { return self; }

@end
