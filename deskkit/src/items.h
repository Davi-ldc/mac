// What the picker shows: screens (a list or a form), their rows, and the actions on a row.
// Plain data; the views and the controller only read it.
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@class DKCalculation;

/// A key combination written as "cmd+shift+c", "ctrl+x" or "cmd+return".
@interface DKShortcut : NSObject
+ (nullable instancetype)shortcutWithString:(NSString *)spec;
- (BOOL)matchesEvent:(NSEvent *)event;
/// One string per keycap, in display order: modifiers (⌃ ⌥ ⇧ ⌘) and then the key.
@property(readonly) NSArray<NSString *> *keycaps;
@end

@interface DKAction : NSObject
+ (instancetype)actionWithTitle:(NSString *)title
                         symbol:(nullable NSString *)symbol
                       shortcut:(nullable NSString *)shortcut
                        handler:(void (^)(void))handler;
@property(copy, readonly) NSString *title;
/// SF Symbol shown next to the title in the Actions menu.
@property(copy, readonly, nullable) NSString *symbol;
@property(strong, readonly, nullable) DKShortcut *shortcut;
/// More keys that run it without being shown: Copy Answer's ⌘C beside its ⏎.
@property(copy, nullable) NSArray<DKShortcut *> *otherShortcuts;
/// Starts a new group in the Actions menu, below a separator.
@property BOOL startsSection;
/// The shortcut or one of the other shortcuts.
- (BOOL)matchesEvent:(NSEvent *)event;
@property(copy) void (^handler)(void);
/// Drawn in red in the Actions menu.
@property BOOL destructive;
@end

/// The right-hand pane of a list-and-detail screen, for one row.
@interface DKDetail : NSObject
@property(copy, nullable) NSString *text;
/// A picture in place of the text. The pane calls this with the room it has for one, in
/// points, and its screen's pixels per point; `show` takes the picture scaled down to fit
/// (never up), on the main thread, during the call or later.
@property(copy, nullable) void (^imageLoader)(NSSize room, CGFloat scale, void (^show)(NSImage *_Nullable image));
/// Label and value pairs listed under "Information".
@property(copy, nullable) NSArray<NSArray<NSString *> *> *metadata;
@end

@interface DKItem : NSObject
@property(copy) NSString *title;
@property(copy, nullable) NSString *subtitle;
/// Other names the item is found by, not shown: System Preferences for System Settings.
@property(copy, nullable) NSArray<NSString *> *alternateTitles;
/// Words that also find the item, without ranking it higher: an app's bundle identifier.
@property(copy, nullable) NSArray<NSString *> *keywords;
/// Right-aligned grey label: "Application", "Quicklink", "Command".
@property(copy, nullable) NSString *accessory;
@property(strong, nullable) NSImage *icon;
/// Makes the icon when the row first appears, for icons that are expensive to make.
@property(copy, nullable) NSImage *_Nullable (^iconLoader)(void);
/// Raycast's dot under the icon, which marks an application that is running.
@property BOOL running;
/// Grey header shown above the first item of each run of equal sections.
@property(copy, nullable) NSString *section;
/// Stable identity, used for usage ranking and to keep the selection across reloads.
@property(copy) NSString *key;
/// The first action runs on ⏎ and is named in the bottom bar; the rest live in ⌘K.
@property(copy, nonatomic) NSArray<DKAction *> *actions;
/// Runs in place of the first action when ⏎ or the mouse button stays down on the row for
/// DKHoldSeconds. ⏎ let go sooner runs the first action, on its release.
@property(strong, nullable) DKAction *heldAction;
/// Makes the actions when they are first asked for, which for most rows of a long list is
/// never.
@property(copy, nullable) NSArray<DKAction *> * (^actionsLoader)(void);
/// Makes the detail pane when the row is selected, so previews, images and formatted dates
/// are made only for the row on screen.
@property(copy, nullable) DKDetail * (^detail)(void);
/// Shown as Raycast's calculator card rather than a row; the subtitle goes under its arrow.
@property(strong, nullable) DKCalculation *calculation;
/// Heads the Actions menu.
@property(copy, nullable) NSString *actionsTitle;
@end

/// What a screen shows in the bottom-left pill.
@interface DKScreen : NSObject
@property(copy) NSString *title;
@property(strong, nullable) NSImage *icon;
@end

typedef NSArray<DKItem *> *_Nonnull (^DKItemsForQuery)(NSString *query);

/// A searchable list.
@interface DKPage : DKScreen
@property(copy) NSString *placeholder;
@property(copy) DKItemsForQuery items;
/// List on the left, the selected row's detail on the right.
@property BOOL showsDetail;
@end

@interface DKFormField : NSObject
+ (instancetype)fieldWithLabel:(NSString *)label placeholder:(NSString *)placeholder value:(nullable NSString *)value;
@property(copy, readonly) NSString *label, *placeholder;
@property(copy, readonly, nullable) NSString *value;
/// A tall box whose text wraps, like Raycast's link field.
@property BOOL multiline;
/// A list, one entry per line: Return starts a new line rather than moving to the next
/// field, and lines do not wrap, so that each entry keeps a row of its own.
@property BOOL oneEntryPerLine;
/// A file dropped on a line of a one-entry-per-line field: returns the line to put in its
/// place, or nil to refuse the file. Only image files are offered.
@property(copy, nullable) NSString *_Nullable (^lineForDroppedFile)(NSString *line, NSURL *file);
/// Grey help text under the field.
@property(copy, nullable) NSString *info;
@end

@interface DKForm : DKScreen
@property(copy) NSArray<DKFormField *> *fields;
/// Named in the bottom bar with ⌘⏎.
@property(copy) NSString *submitTitle;
/// Returns nil when the values were accepted, or what is wrong with them, which the form
/// shows while it stays open.
@property(copy) NSString *_Nullable (^submit)(NSArray<NSString *> *values);
@end

NS_ASSUME_NONNULL_END
