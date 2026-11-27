// The slash commands Slack's client runs itself (its getCommands registry and the
// slash-commands-local handlers), with their requests, confirmations and answers: /leave (/close,
// /part), /msg (/dm), /open (/join), /topic, /invite, /remove (/kick), /rename, /archive, /search
// (/s) and "s/old/new". Every other command goes to the source's chat.command;
// the client's own commands this app lacks the views for (/shortcuts, /gif...) say so.
#import <AppKit/AppKit.h>

#import "source/source.h"
#import "ui/shell/pane.h"

NS_ASSUME_NONNULL_BEGIN

@interface SNSlashCommands : NSObject
- (instancetype)initWithSource:(id<SNSource>)source;
/// Where /msg, /open and /search go.
@property (nonatomic, weak, nullable) id<SNNavigator> navigator;
/// The time /remind starts from; nil: now (tests set a time of day).
@property (nonatomic, copy, nullable) NSDate * (^clock)(void);
/// /gif: the composer's GIF picker, searching what followed the command.
@property (nonatomic, copy, nullable) void (^openGifPicker)(NSString *query);
/// Runs what the composer sent: `typed` is the command word as typed ("/Leave"), `rest` the
/// composer's text after it and its space. Dialogs open in `window`; `restore` puts the composer's
/// text back (Slack's keep_input).
- (void)run:(NSString *)typed
            rest:(NSAttributedString *)rest
  inConversation:(NSString *)conversationID
        threadTS:(nullable NSString *)threadTS
          window:(nullable NSWindow *)window
         restore:(void (^)(void))restore;
@end

/// The rest of a command as Slack's client parses it (parseSlashCmdArgsFromDelta): each mention
/// (picked from the list, so an entity) is @{type: "mention", value: <ID>, range}, and the plain
/// text between them splits on white space into @{type: "string", value, range}.
NSArray<NSDictionary *> *SNSlashCommandParams(NSAttributedString *rest);

NS_ASSUME_NONNULL_END
