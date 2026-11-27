// Where every part of a message row goes at a width (components.json message_row, measured on
// the reference crops): the avatar 16 pt in and 8 pt down, the text column at 60 pt and 4 pt
// down, 22 pt lines, the 4 pt spacer after the text, files, reactions and the reply bar. It is
// computed once per message, grouping and width and then only read, by drawing, hit testing and
// the list's height cache. It keeps no reference to the message: cached layouts outlive the
// decoded messages they were made from.
#import <AppKit/AppKit.h>

#import "model/message.h"
#import "render/file.h"
#import "render/message.h"

NS_ASSUME_NONNULL_BEGIN

static const CGFloat SNMessageGutter = 16, SNMessageAvatarSize = 36, SNMessageAvatarTop = 8;
static const CGFloat SNMessageTextLeft = 60, SNMessageTextRight = 16, SNMessageTextTop = 4, SNMessageLineHeight = 22;
static const CGFloat SNReactionHeight = 24, SNReplyBarHeight = 34;
/// A failed send's warning glyph and the space after it.
static const CGFloat SNFailedIconWidth = 18;

/// A file of the message, drawn by the component Slack draws it with (render/file.h).
@interface SNFileLayout : NSObject
@property (nonatomic, readonly) SNFile *file;
@property (nonatomic, readonly) SNFileStyle style;
@property (nonatomic, readonly) NSRect frame;
/// The message and column, which keep a snippet's expansion.
@property (nonatomic, readonly) NSString *context;
/// The key the message's files collapse and expand by (render/expandable.h), and whether its
/// meta line has the caret that does it (pictures, snippets, the collapsed line).
@property (nonatomic, readonly) NSString *expandableKey;
@property (nonatomic, readonly) BOOL togglesFiles;
/// The collapsed line's words: the file's name, or how many files.
@property (nonatomic, readonly, nullable) NSString *metaTitle;
@end

typedef NS_ENUM(NSInteger, SNMessageRowStyle) {
    /// In a conversation, with the reply bar of a thread's parent.
    SNMessageRowInConversation,
    /// A thread's parent atop the thread: the day beside the time ("Sexta-feira à(s) 11h44").
    SNMessageRowThreadParent,
    SNMessageRowThreadReply,
};

@interface SNMessageLayout : NSObject
+ (instancetype)layoutForMessage:(SNMessage *)message
                    continuation:(BOOL)continuation
                           style:(SNMessageRowStyle)style
                           width:(CGFloat)width
                        renderer:(SNRenderer *)renderer;
/// Grouped under the previous message of the same sender: no avatar and no header.
@property (nonatomic, readonly) BOOL continuation;
@property (nonatomic, readonly) SNMessageRowStyle style;
@property (nonatomic, readonly) CGFloat width, height;
/// The sender as Slack shows them, and the header pieces (zero rects on continuations).
@property (nonatomic, readonly) NSString *senderName, *time;
@property (nonatomic, readonly) NSRect avatarRect, nameRect, timeRect;
/// The bot or app badge after the name ("APP"), or zero.
@property (nonatomic, readonly) NSRect badgeRect;
/// PriorityVipBadge: the 18 pt vip-filled 4 pt after a VIP's name (not in a DM, where Slack leaves
/// it out), or zero.
@property (nonatomic, readonly) NSRect vipBadgeRect;
/// A huddle_thread message: the huddle's headphones square in the avatar's place and its status
/// in the name's; while the huddle is live, the jade-0 background, the LIVE badge after the
/// status and, for a huddle the user is not in, "Join Huddle" under the text (faces of
/// `huddleFaces`).
@property (nonatomic, readonly) BOOL isHuddle, huddleLive;
@property (nonatomic, readonly) NSRect liveBadgeRect, joinRect;
@property (nonatomic, readonly, nullable) NSArray<NSString *> *huddleFaces;
/// A continuation's time in the left gutter, shown while the row is hovered, and the part of
/// it the text covers (right-aligned), which the pointer hovers.
@property (nonatomic, readonly) NSRect compactTimeRect, compactTimeBox;
@property (nonatomic, readonly) SNRenderLayout *body;
@property (nonatomic, readonly) NSPoint bodyOrigin;
@property (nonatomic, readonly) NSArray<SNFileLayout *> *files;
/// A failed send's line under the message: its warning (`failedRect`), then the Retry and
/// Delete links. Zero rects otherwise.
@property (nonatomic, readonly) NSRect failedRect, retryRect, discardRect;
/// "Only visible to you" over a message only the user sees (the eye right-aligned to the avatar's
/// column, the words at the text's), or zero.
@property (nonatomic, readonly) NSRect ephemeralRect;
/// One frame per reaction, then the add-reaction pill's.
@property (nonatomic, readonly) NSArray<NSValue *> *reactionFrames;
@property (nonatomic, readonly) NSRect replyBarRect;
@end

/// Whether `message` groups under `previous` (same sender, within 5 minutes, same day, neither a
/// system message).
BOOL SNMessageGroupsWith(SNMessage *message, SNMessage *_Nullable previous);
/// A reaction pill's width: 8 pt padding, a 16 pt emoji, 4 pt and the count.
CGFloat SNReactionWidth(SNReaction *reaction, BOOL mine);

NS_ASSUME_NONNULL_END
