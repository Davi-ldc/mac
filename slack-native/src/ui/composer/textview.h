// The composer's editable text: the rich document (richtext.h) laid out in CSS line boxes (15 pt
// Lato on 22.5 pt lines), drawn the way the web client's editor draws it (list markers, quote
// bars, code boxes, mention chips), with Slack's keys: Return sends, Shift+Return starts a new
// line (a new list item; an empty item or quote line ends the block), Tab and Shift+Tab indent
// list items, Backspace removes a mention whole and turns a block's first character back into
// plain text, Up in an empty composer edits the last message.
#import <AppKit/AppKit.h>

#import "ui/composer/richtext.h"

NS_ASSUME_NONNULL_BEGIN

@class SNComposerTextView;

@protocol SNComposerTextViewDelegate <NSObject>
/// The user changed the text (typing, pasting, formatting, undo); setting `document` is not a
/// change.
- (void)composerTextViewDidChange:(SNComposerTextView *)textView;
- (void)composerTextViewFocusDidChange:(SNComposerTextView *)textView;
/// Return without Shift.
- (void)composerTextViewSend:(SNComposerTextView *)textView;
/// Up in an empty composer.
- (void)composerTextViewEditLastMessage:(SNComposerTextView *)textView;
/// Keys the autocomplete list takes while it is open (Up, Down, Return, Tab, Escape); YES when
/// it used the key.
- (BOOL)composerTextView:(SNComposerTextView *)textView autocompleteCommand:(SEL)command;
@optional
/// The caret or selection moved without an edit (arrows, clicks).
- (void)composerTextViewSelectionDidChange:(SNComposerTextView *)textView;
/// A paste of files or of a picture alone: YES when the delegate attached them (nothing is
/// pasted as text then).
- (BOOL)composerTextView:(SNComposerTextView *)textView pasteFilesFrom:(NSPasteboard *)pasteboard;
@end

/// Text sizes from components.json composer and mrkdwn.
static const CGFloat SNComposerFontSize = 15, SNComposerLineHeight = 22.5;

@interface SNComposerTextView : NSTextView
- (instancetype)initWithFrame:(NSRect)frame;
@property (nonatomic, weak, nullable) id<SNComposerTextViewDelegate> composerDelegate;
@property (nonatomic, copy) NSString *placeholder;
/// Slack's msg_input_send_btn: Return starts a new line and ⌘Return sends (else Return sends and
/// Shift+Return starts a line).
@property (nonatomic) BOOL returnStartsLine;
/// Slack's enter_is_special_in_tbt: inside a code block Return starts a line and Shift+Return sends.
@property (nonatomic) BOOL returnStartsLineInCode;
/// Draws a lock before the placeholder's last word (a private channel's name).
@property (nonatomic) BOOL placeholderLock;
/// The document; setting it replaces the text, puts the caret at its end and clears the text
/// view's own undo history.
@property (nonatomic, copy) NSAttributedString *document;
@property (nonatomic, readonly) BOOL isEmpty;
@property (nonatomic, readonly) BOOL isFocused;
/// The height of the laid-out text.
@property (nonatomic, readonly) CGFloat contentHeight;

/// Inline styles: on the selection, or for what is typed next.
- (void)toggleStyle:(SNInlineStyle)style;
/// Whether the selection (or the typing attributes) has `style` everywhere.
- (BOOL)hasStyle:(SNInlineStyle)style;
/// Blocks on the selected paragraphs: set, or removed when they all have it already.
- (void)toggleBlock:(SNRichBlockKind)kind;
/// Starts a [text](url) link around the selection; the URL is typed next.
- (void)beginLink;
/// Inserts a mention or emoji at the caret, replacing `range` (the typed "@na" of an
/// autocomplete) and adding the space after it.
- (void)insertEntity:(SNRichEntity *)entity text:(NSString *)text replacingRange:(NSRange)range;
/// Shift+Return: a new line, list item or quote line, or the end of the block on an empty one.
- (void)insertLineBreak;
/// The word being typed right before the caret when it starts with `@`, `#` or `:` (the
/// autocomplete's query), and its range; nil otherwise.
- (nullable NSString *)autocompleteQueryRange:(nullable NSRangePointer)range;
@end

NS_ASSUME_NONNULL_END
