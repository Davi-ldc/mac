// A message reduced to the one paragraph list rows show under a name (the DMs list, Activity):
// the renderer's preview (render/message.h), after "Você: " when the user sent it.
#import <Foundation/Foundation.h>

#import "source/source.h"
#import "render/document.h"

NS_ASSUME_NONNULL_BEGIN

SNRenderDocument *SNPreviewDocument(SNMessage *message, id<SNSource> source);
/// The preview in `style`; `yours` puts "Você: " in front whoever sent it (a reaction to the
/// user's message).
SNRenderDocument *SNPreviewDocumentWithStyle(SNMessage *message, id<SNSource> source, SNTextStyle style, BOOL yours);
/// The users a preview names (its mentions), so it can be made again when one of them changes.
NSSet<NSString *> *SNPreviewUserIDs(SNMessage *message);

NS_ASSUME_NONNULL_END
