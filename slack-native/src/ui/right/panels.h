// Slack's flexpanes that open in the right column instead of a thread (SNLocation.panel), under
// a header like the thread's (the title, the close X):
// - "Keyboard Shortcuts" (/shortcuts, ⌘/, toggled): Slack's sections and rows, those of the
//   shortcuts this app answers to, each title with its keys;
// - "Feedback" (/feedback, Slack's default when slash_feedback_in_modal is off): "How can we
//   help?" with a text box (Return sends, Shift+Return starts a line) that sends
//   feedback.submitFeedback, then Slack's "Thank you". Attaching files is not offered here;
// - "Profile": someone's full profile (ui/right/profile.h).
#import <AppKit/AppKit.h>

#import "source/source.h"

NS_ASSUME_NONNULL_BEGIN

@protocol SNPanelView <NSObject>
/// Where typing goes when the panel opens (the feedback box), if anywhere.
- (void)focusForTyping;
@end

/// The view for `panel` (SNPanelShortcuts, SNPanelFeedback, SNPanelProfile()); `close` is its
/// header's X.
NSView<SNPanelView> *_Nullable SNMakePanel(NSString *panel, id<SNSource> source, void (^close)(void));
/// The header every panel has: `title` in black at `titleSize` and the close X, SNThreadHeaderHeight
/// tall.
NSView *SNMakePanelHeader(NSString *title, CGFloat titleSize, void (^close)(void));

@interface SNShortcutsPanel : NSView <SNPanelView>
/// The sections' titles and every row as "title: keys" (tests).
@property (nonatomic, readonly) NSArray<NSString *> *sectionTitles, *rowTexts;
@end

@interface SNFeedbackPanel : NSView <SNPanelView>
@property (nonatomic, copy) NSString *text;
/// Send (Return); whether the thanks show.
- (void)send;
@property (nonatomic, readonly) BOOL sent;
@end

NS_ASSUME_NONNULL_END
