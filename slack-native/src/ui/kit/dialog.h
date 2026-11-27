// Slack's confirmation modal for something that cannot be undone (components.json modal; the
// open effect is the CSS one, effects.txt [modal-open], never captured live): a 520 pt dialog over
// a rgba(16,18,20,.6) backdrop, the 22 pt title with the close button, the question and an
// optional view under it (the message being deleted, a field), then Cancelar and the red or green
// confirm button; a dialog that asks Slack waits for its answer and shows a refusal in a red note.
// It opens over 80 ms (backdrop and dialog fade, the dialog scales from .95). Escape, the close
// button and a click on the backdrop cancel; a Return pressed after it opened confirms (key
// repeats and a Return held from before are ignored).
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface SNConfirmDialog : NSObject
+ (instancetype)showInWindow:(NSWindow *)window
                       title:(NSString *)title
                        text:(NSString *)text
                   accessory:(nullable NSView *)accessory
                confirmTitle:(NSString *)confirmTitle
                  completion:(void (^)(BOOL confirmed))completion;
/// Slack's alert ("File too large"): the title, the text and one green button that closes it, as
/// do Escape, the close button and the backdrop.
+ (instancetype)showAlertInWindow:(NSWindow *)window title:(NSString *)title text:(NSString *)text buttonTitle:(NSString *)buttonTitle;
/// A dialog whose confirm button asks Slack something (Slack's dialogs with shouldCloseOnGo off):
/// the button waits while `perform` runs, the dialog closes once `finish` gets nil, and an error's
/// text shows in a red note over the buttons, the dialog staying open. `danger` makes the button
/// red, else it is the green primary one.
+ (instancetype)showInWindow:(NSWindow *)window
                       title:(NSString *)title
                        text:(nullable NSString *)text
                   accessory:(nullable NSView *)accessory
                confirmTitle:(NSString *)confirmTitle
                      danger:(BOOL)danger
                     perform:(void (^)(void (^finish)(NSString *_Nullable error)))perform;
/// A form (Slack's Later "Reminder" dialog): `accessory` under the title, `width` wide, then
/// Cancel and the green `confirmTitle`, which closes it at once and calls `confirmed` (Slack does
/// not wait for its request). The accessory may change height: -accessoryHeightChanged.
+ (instancetype)showFormInWindow:(NSWindow *)window
                           title:(NSString *)title
                       accessory:(NSView *)accessory
                           width:(CGFloat)width
                    confirmTitle:(NSString *)confirmTitle
                       confirmed:(void (^)(void))confirmed;
/// The dialog open now, if any.
+ (nullable SNConfirmDialog *)current;
/// Whether the confirm button (and Return) can confirm; the rename dialog's waits for a change.
@property (nonatomic) BOOL confirmEnabled;
/// Keys the dialog leaves to what has the keyboard (a text view that sends on Return, a list open
/// over it): YES passes the event on. Escape and Return are the dialog's otherwise.
@property (nonatomic, copy, nullable) BOOL (^passesKey)(NSEvent *event);
/// Lays the dialog out again around its accessory's new height.
- (void)accessoryHeightChanged;
/// Dialogs of several steps (add people: who, then history): what confirm (the button, Return) and
/// Cancel do instead of closing, the step shown and closing when done.
@property (nonatomic, copy, nullable) void (^confirmAction)(void);
@property (nonatomic, copy, nullable) void (^cancelAction)(void);
- (void)showStepTitled:(NSString *)title
                  text:(nullable NSString *)text
             accessory:(nullable NSView *)accessory
          confirmTitle:(NSString *)confirmTitle
           cancelTitle:(nullable NSString *)cancelTitle;
/// While a request is out the confirm button waits.
@property (nonatomic) BOOL waiting;
/// The red note over the buttons; nil takes it away.
- (void)showError:(nullable NSString *)error;
- (void)close;
/// The red note's text while one shows (tests).
@property (nonatomic, readonly, nullable) NSString *errorText;
/// The dialog's surface, for tests and snapshots.
@property (nonatomic, readonly) NSView *panel;
- (void)confirm;
- (void)cancel;
/// The dialog's keys, as its event monitor hands them over; YES when the event was consumed.
- (BOOL)handleKeyEvent:(NSEvent *)event;
@end

NS_ASSUME_NONNULL_END
