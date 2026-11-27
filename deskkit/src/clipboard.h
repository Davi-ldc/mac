// Clipboard history: what was copied in the last 90 days, kept encrypted on disk within a
// size limit.
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// True when the pasteboard content asks not to be recorded: password managers mark
/// secrets with these types (nspasteboard.org).
BOOL DKPasteboardIsPrivate(NSPasteboard *pasteboard);

typedef NS_ENUM(NSInteger, DKClipKind) { DKClipText, DKClipFiles, DKClipImage };

/// One entry of the history.
@interface DKClip : NSObject
@property(readonly) DKClipKind kind;
/// The text's first 2000 characters, or the file paths one per line; empty for images.
@property(readonly) NSString *text;
@property(readonly) NSDate *date;
/// The app in front when it was copied.
@property(readonly, nullable) NSString *application;
/// Images only, in pixels.
@property(readonly) NSSize imageSize;
/// Images only: PNG data of a copy at most 64 pixels on a side.
@property(readonly, nullable) NSData *thumbnail;
@end

/// Posted on the main thread when a history's entries are in (see -load).
extern NSNotificationName const DKClipboardHistoryDidLoadNotification;

@interface DKClipboardHistory : NSObject
/// The history in deskkit's folder, keyed in the login Keychain under "local.deskkit" (or
/// DESKKIT_KEYCHAIN_SERVICE).
@property(class, readonly) DKClipboardHistory *shared;
/// `readKey` gives the key the entries are sealed with, or nil while it cannot be had. It
/// is called off the main thread, one call at a time, and may take as long as it needs:
/// the Keychain can wait on a prompt.
- (instancetype)initWithFolder:(NSURL *)folder key:(NSData *_Nullable (^)(void))readKey NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
/// Most the history keeps on disk, in bytes; past it the oldest entries go.
@property unsigned long long byteLimit;
/// Most one entry's content may take, in bytes; larger copies are not recorded.
@property NSUInteger entryByteLimit;
/// What the history's entries take on disk, in bytes.
@property(readonly) unsigned long long byteCount;
/// Reads the key and then the history without holding up the main thread, and posts
/// DKClipboardHistoryDidLoadNotification once the entries are in. While the key cannot be
/// read it tries again later; files it cannot open are kept until they would have expired
/// anyway.
- (void)load;
/// NO until the entries are in. Nothing is recorded before, as sealing takes the key.
@property(readonly, getter=isLoaded) BOOL loaded;
/// Loads, then records each change of the general pasteboard. The last copy made while the
/// key was awaited is recorded once the key is there.
- (void)start;
/// Records what the pasteboard holds, unless it is private or came from the history. The
/// entry appears once it has been sealed and written, which happens off the main thread.
- (void)recordPasteboard:(NSPasteboard *)pasteboard;
/// Newest first, at most `limit`.
- (NSArray<DKClip *> *)clipsMatching:(NSString *)query limit:(NSUInteger)limit;
/// UTF-8 text, paths one per line, or PNG data. Reads the entry's file on the calling
/// thread, which need not be the main one.
- (nullable NSData *)contentOf:(DKClip *)clip;
/// Puts the clip back on the general pasteboard, where it is not recorded again, and moves
/// it to the top. Returns NO when its content cannot be read.
- (BOOL)copyToPasteboard:(DKClip *)clip;
- (void)remove:(DKClip *)clip;
- (void)removeAll;
@end

NS_ASSUME_NONNULL_END
