// Slack Native: a native Slack client. Without arguments it opens the session stored in the
// Keychain, or shows the sign-in window when there is none; nothing reaches Slack before the
// user signs in. `--fixture <folder>` runs the UI on saved responses; `--selftest <repo>`,
// `--snapshot <repo> <output>`, `--bench <fixture>` and `--memory <fixture>` run headless (see
// the Makefile).
#import <AppKit/AppKit.h>

#import "app/account.h"
#import "app/instance.h"
#import "app/launch.h"
#import "auth/signin.h"
#import "net/switches.h"
#import "render/icon.h"
#import "render/images.h"
#import "render/strings.h"
#import "theme/theme.h"
#import "ui/files/filenet.h"
#import "ui/files/fileview.h"
#import "ui/kit/popover.h"
#import "ui/prefs/prefs.h"
#import "ui/shell/actions.h"
#import "ui/shell/shell.h"

#ifndef SN_RELEASE
int SNRunSelfTest(NSString *repository, NSArray<NSString *> *arguments);
int SNRunSnapshots(NSString *repository, NSString *output, NSArray<NSString *> *arguments);
int SNRunBench(NSURL *fixture);

/// argv from `first` on.
static NSArray<NSString *> *Arguments(int argc, const char *argv[], int first) {
    NSMutableArray *arguments = [NSMutableArray new];
    for (int i = first; i < argc; i++) [arguments addObject:@(argv[i])];
    return arguments;
}
#endif

/// How long the last calls get to reach Slack: read marks still waiting and a huddle's leaves at
/// quit, auth.signout.
static const NSTimeInterval SNLastCallsWait = 2;

@interface SNLaunchPreload : NSObject
@property (nonatomic) BOOL locked;
@property (nonatomic) dispatch_group_t group;
@property (nonatomic) id<SNSecretStore> secrets;
@property (nonatomic) SNSession *session;
@property (nonatomic) SNStore *store;
@end

@implementation SNLaunchPreload
@end

@interface SNAppDelegate : NSObject <NSApplicationDelegate, SNAppActions>
/// Set before launch for fixture runs; a signed-in launch sets it to the account's store.
@property (nonatomic) id<SNSource> source;
/// Where the shell keeps its state (SNAppDefaults); set with `source`.
@property (nonatomic) NSUserDefaults *defaults;
@property (nonatomic) SNShell *shell;
@property (nonatomic) SNAccount *account;
/// Accounts still finishing rooms.leave + auth.signout after the user signed out.
@property (nonatomic) NSMutableArray<SNAccount *> *signingOut;
@property (nonatomic) NSMutableArray<dispatch_block_t> *signOutWaiters;
@property (nonatomic) SNSignInWindowController *signIn;
@property (nonatomic) id<SNSecretStore> secrets;
/// Started in main() before AppKit initializes so Keychain XPC and SQLite overlap with AppKit.
@property (nonatomic) SNLaunchPreload *preload;
@property (nonatomic) BOOL postFrameDone;
/// Cold-launch notification click received before the shell was built.
@property (nonatomic, copy) NSString *pendingOpenConversation;
@property (nonatomic, copy) NSString *pendingOpenThreadTS;
/// SIGTERM (kill, launchctl) quits as Quit does, so a call is left and read marks are sent.
@property (nonatomic) dispatch_source_t terminationSignal;
@end

@implementation SNAppDelegate

- (void)applicationWillFinishLaunching:(NSNotification *)notification {
    SNTraceLaunch(@"willLaunch");
    self.signingOut = [NSMutableArray new];
    self.signOutWaiters = [NSMutableArray new];
    signal(SIGTERM, SIG_IGN);
    self.terminationSignal = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(self.terminationSignal, ^{ [NSApp terminate:nil]; });
    dispatch_resume(self.terminationSignal);
    if (self.source) {
        [self showShell];
        return;
    }
    SNLaunchPreload *preload = self.preload;
    if (preload && !preload.locked) return;
    if (preload) {
        // Bounded wait so a Keychain prompt or slow XPC service never deadlocks app launch; in the
        // normal case preload already finished while AppKit initialized.
        if (dispatch_group_wait(preload.group, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC))) == 0) {
            [self finishPreload:preload];
        } else {
            [self setMenuWithShell:NO];
            __weak SNAppDelegate *weakSelf = self;
            dispatch_group_notify(preload.group, dispatch_get_main_queue(), ^{ [weakSelf finishPreload:preload]; });
        }
    }
}

- (void)finishPreload:(SNLaunchPreload *)preload {
    if (self.preload != preload) return;
    self.secrets = preload.secrets;
    SNSession *session = preload.session;
    SNStore *store = preload.store;
    self.preload = nil;
    if (!session) {
        NSError *keychainError = [self.secrets isKindOfClass:SNKeychain.class] ? ((SNKeychain *)self.secrets).lastError : nil;
        if (keychainError) {
            NSLog(@"slack-native: aborting launch on keychain error (not treating as signed out): %@", keychainError);
            [NSApp terminate:nil];
            return;
        }
        [self setMenuWithShell:NO];
        [self showSignInAfter:nil];
        return;
    }
    [self open:session preloadedStore:store];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    SNTraceLaunch(@"appkit");
    if (self.preload && !self.preload.locked) {
        self.preload = nil;
        [self setMenuWithShell:NO];
        [self explainAnotherCopy];
        [NSApp terminate:nil];
    }
}

/// Before anything reads the session: this copy leaves it to the one already running.
- (void)explainAnotherCopy {
    SNSetLanguage(NSLocale.preferredLanguages.firstObject ?: @"en");
    NSAlert *alert = [NSAlert new];
    alert.messageText = SNLocalized(@"app.instance.title");
    alert.informativeText = SNLocalized(@"app.instance.message");
    [NSApp activate];
    [alert runModal];
}

- (void)showShell {
    self.shell = [[SNShell alloc] initWithSource:self.source defaults:self.defaults];
    if (self.pendingOpenConversation) {
        NSString *conversationID = self.pendingOpenConversation;
        NSString *threadTS = self.pendingOpenThreadTS;
        self.pendingOpenConversation = nil;
        self.pendingOpenThreadTS = nil;
        if (threadTS) [self.shell openThread:threadTS inConversation:conversationID];
        else [self.shell openConversation:conversationID];
    }
    [self setMenuWithShell:YES];
    [self.shell.window center];
    [self.shell.window makeKeyAndOrderFront:nil];
    SNTraceLaunch(@"window");
    __weak SNAppDelegate *weakSelf = self;
    // After Core Animation's commit (order 2000000) of the turn that showed the window: start
    // notifications and clean sign-in stores off the critical path to the first frame.
    CFRunLoopObserverRef frame = CFRunLoopObserverCreateWithHandler(NULL, kCFRunLoopBeforeWaiting, false, 3000000,
                                                                    ^(CFRunLoopObserverRef observer, CFRunLoopActivity activity) {
        SNTraceLaunch(@"frame");
        CFRunLoopObserverInvalidate(observer);
        SNAppDelegate *delegate = weakSelf;
        if (!delegate) return;
        if (!delegate.postFrameDone && delegate.account) {
            delegate.postFrameDone = YES;
            // Users, bots, usergroups, activity and commands load on demand from SQLite without
            // decoding the entire users table on the main thread after launch.
            [delegate.account.notifier start];
            SNRemoveSignInDataStores(nil);
        }
    });
    CFRunLoopAddObserver(CFRunLoopGetMain(), frame, kCFRunLoopCommonModes);
    CFRelease(frame);
}

/// The menu bar; the Go menu only while a workspace shows, built once its language is set.
- (void)setMenuWithShell:(BOOL)shell {
    NSMenu *menu = [NSMenu new];
    NSMenuItem *appItem = [menu addItemWithTitle:@"" action:nil keyEquivalent:@""];
    appItem.submenu = [NSMenu new];
    if (shell) {
        [appItem.submenu addItemWithTitle:SNLocalized(@"app.menu.preferences") action:@selector(showPreferences:) keyEquivalent:@","];
        [appItem.submenu addItem:NSMenuItem.separatorItem];
    }
    [appItem.submenu addItemWithTitle:SNLocalized(@"app.menu.hide") action:@selector(hide:) keyEquivalent:@"h"];
    NSMenuItem *others = [appItem.submenu addItemWithTitle:SNLocalized(@"app.menu.hideOthers") action:@selector(hideOtherApplications:) keyEquivalent:@"h"];
    others.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
    [appItem.submenu addItemWithTitle:SNLocalized(@"app.menu.showAll") action:@selector(unhideAllApplications:) keyEquivalent:@""];
    [appItem.submenu addItem:NSMenuItem.separatorItem];
    [appItem.submenu addItemWithTitle:SNLocalized(@"app.menu.quit") action:@selector(terminate:) keyEquivalent:@"q"];
    // Text views get cut, copy, paste, undo and select all only through these items' key equivalents.
    NSMenuItem *editItem = [menu addItemWithTitle:SNLocalized(@"app.menu.edit") action:nil keyEquivalent:@""];
    editItem.submenu = [[NSMenu alloc] initWithTitle:SNLocalized(@"app.menu.edit")];
    [editItem.submenu addItemWithTitle:SNLocalized(@"app.menu.undo") action:@selector(undo:) keyEquivalent:@"z"];
    [editItem.submenu addItemWithTitle:SNLocalized(@"app.menu.redo") action:@selector(redo:) keyEquivalent:@"Z"];
    [editItem.submenu addItem:NSMenuItem.separatorItem];
    [editItem.submenu addItemWithTitle:SNLocalized(@"app.menu.cut") action:@selector(cut:) keyEquivalent:@"x"];
    [editItem.submenu addItemWithTitle:SNLocalized(@"app.menu.copy") action:@selector(copy:) keyEquivalent:@"c"];
    [editItem.submenu addItemWithTitle:SNLocalized(@"app.menu.paste") action:@selector(paste:) keyEquivalent:@"v"];
    NSMenuItem *plain = [editItem.submenu addItemWithTitle:SNLocalized(@"app.menu.pastePlain") action:@selector(pasteAsPlainText:) keyEquivalent:@"V"];
    plain.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption | NSEventModifierFlagShift;
    [editItem.submenu addItemWithTitle:SNLocalized(@"app.menu.selectAll") action:@selector(selectAll:) keyEquivalent:@"a"];
    NSMenuItem *windowItem = [menu addItemWithTitle:SNLocalized(@"app.menu.window") action:nil keyEquivalent:@""];
    windowItem.submenu = [[NSMenu alloc] initWithTitle:SNLocalized(@"app.menu.window")];
    [windowItem.submenu addItemWithTitle:SNLocalized(@"app.menu.minimize") action:@selector(performMiniaturize:) keyEquivalent:@"m"];
    [windowItem.submenu addItemWithTitle:SNLocalized(@"app.menu.zoom") action:@selector(performZoom:) keyEquivalent:@""];
    NSApp.windowsMenu = windowItem.submenu;
    if (shell) {
        NSMenuItem *goItem = [menu addItemWithTitle:SNLocalized(@"app.menu.go") action:nil keyEquivalent:@""];
        goItem.submenu = [[NSMenu alloc] initWithTitle:SNLocalized(@"app.menu.go")];
        // Slack opens its search from both.
        [goItem.submenu addItemWithTitle:SNLocalized(@"app.menu.jump") action:@selector(openSearch:) keyEquivalent:@"k"];
        [goItem.submenu addItemWithTitle:SNLocalized(@"app.menu.search") action:@selector(openSearch:) keyEquivalent:@"g"];
        // The top bar's tooltips name these shortcuts, as Slack's do.
        [goItem.submenu addItemWithTitle:SNLocalized(@"app.menu.back") action:@selector(goBack:) keyEquivalent:@"["];
        [goItem.submenu addItemWithTitle:SNLocalized(@"app.menu.forward") action:@selector(goForward:) keyEquivalent:@"]"];
        // Slack's ⌘/ toggles its Keyboard Shortcuts panel.
        [goItem.submenu addItemWithTitle:SNLocalized(@"app.menu.shortcuts") action:@selector(toggleShortcuts:) keyEquivalent:@"/"];
        NSMenuItem *help = [goItem.submenu addItemWithTitle:SNLocalized(@"app.menu.help") action:@selector(openHelp:)
                                              keyEquivalent:[NSString stringWithFormat:@"%C", (unichar)NSF1FunctionKey]];
        help.keyEquivalentModifierMask = 0;
    }
    NSApp.mainMenu = menu;
}

- (void)openSearch:(id)sender { [self.shell openSearch]; }

- (void)toggleShortcuts:(id)sender {
    SNLocation *here = self.shell.location;
    if (here) [self.shell go:[here locationWithPanel:[here.panel isEqualToString:SNPanelShortcuts] ? nil : SNPanelShortcuts]];
}

- (void)showPreferences:(id)sender {
    if (self.shell) [SNPreferencesDialog showInWindow:self.shell.window source:self.source section:SNPrefsNotifications];
}

- (void)reloadLanguage:(id)sender {
    id locale = self.source.preferences[@"locale"];
    if (![locale isKindOfClass:NSString.class] || !self.shell) return;
    NSString *previous = SNLanguage();
    SNSetLanguage(locale);
    // Unbundled locales resolve back to English; avoid rebuilding in a loop.
    if ([SNLanguage() isEqualToString:previous]) return;
    [SNPreferencesDialog.current close];
    [SNPopover.current close];
    SNShell *oldShell = self.shell;
    NSRect frame = oldShell.window.frame;
    [self showShell];
    [self.shell.window setFrame:frame display:YES];
    [oldShell.window close];
}
- (void)goBack:(id)sender { [self.shell goBack]; }
- (void)goForward:(id)sender { [self.shell goForward]; }
- (void)openHelp:(id)sender { [self.shell openHelp]; }

- (void)signOut:(id)sender {
    SNAccount *account = self.account;
    if (!account) return;
    [self.signingOut addObject:account];
    __weak SNAppDelegate *weakSelf = self;
    [account signOutWithin:SNLastCallsWait completion:^{
        SNAppDelegate *delegate = weakSelf;
        if (!delegate) return;
        [delegate.signingOut removeObject:account];
        if (!delegate.signingOut.count && delegate.signOutWaiters.count) {
            NSArray<dispatch_block_t> *waiters = [delegate.signOutWaiters copy];
            [delegate.signOutWaiters removeAllObjects];
            for (dispatch_block_t waiter in waiters) waiter();
        }
    }];
    [self signedOut:nil];
}

/// `previous`: the session that ended, whose cookies Slack's pages get back.
- (void)showSignInAfter:(SNSession *)previous {
    __weak SNAppDelegate *weakSelf = self;
    self.signIn = [[SNSignInWindowController alloc] initWithSession:previous completion:^(SNSession *session) {
        SNAppDelegate *delegate = weakSelf;
        delegate.signIn = nil;
        if (!session) {
            [NSApp terminate:nil];
            return;
        }
        SNSaveSession(session, delegate.secrets);
        [delegate open:session preloadedStore:nil];
    }];
}

- (void)open:(SNSession *)session preloadedStore:(SNStore *)preloaded {
    SNAccount *account = [[SNAccount alloc] initWithSession:session secrets:self.secrets urlSession:SNMakeURLSession(session) database:nil store:preloaded];
    self.account = account;
    self.postFrameDone = NO;
    __weak SNAppDelegate *weakSelf = self;
    __weak SNAccount *weakAccount = account;
    SNSetImageFetcher(^(NSURL *url, void (^completion)(NSData *)) {
        // Files being sent show from this device until Slack's copy comes.
        if (url.isFileURL) {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                completion([NSData dataWithContentsOfURL:url]);
            });
            return;
        }
        SNClient *client = weakAccount.client;
        if (client) [client fetchData:url completion:completion];
        else completion(nil);
    });
    SNSetFileCredentials(^NSArray<NSHTTPCookie *> * {
        SNClient *client = weakAccount.client;
        return client.isSignedOut ? nil : client.session.cookies;
    }, session.userAgent);
    // Assign the UNUserNotificationCenter delegate synchronously before applicationDidFinishLaunching:
    // returns so cold-launch notification clicks are never dropped.
    account.notifier.focusedConversation = ^NSString * { return weakSelf.shell.location.conversationID; };
    account.notifier.onOpen = ^(NSString *conversationID, NSString *threadTS) {
        SNAppDelegate *delegate = weakSelf;
        if (!delegate) return;
        SNShell *shell = delegate.shell;
        if (!shell) {
            delegate.pendingOpenConversation = conversationID;
            delegate.pendingOpenThreadTS = threadTS;
            return;
        }
        if (threadTS) [shell openThread:threadTS inConversation:conversationID];
        else [shell openConversation:conversationID];
        [shell.window makeKeyAndOrderFront:nil];
    };
    [account.notifier installDelegate];
    account.onSignedOut = ^{ [weakSelf signedOut:session]; };
    [account startWithReady:^{
        SNAppDelegate *delegate = weakSelf;
        SNAccount *ready = weakAccount;
        // The Preferences set the locale preference; the profile's follows it later.
        id locale = ready.store.preferences[@"locale"] ?: ready.store.me.locale;
        SNSetLanguage([locale isKindOfClass:NSString.class] ? locale : @"en");
        delegate.source = ready.store;
        delegate.defaults = SNAppDefaults(ready.client.teamID);
        [delegate showShell];
    }];
}

/// The token could not be refreshed (`session`, whose cookies the sign-in pages get), or the user
/// signed out (nil). For the first the account has stopped (nothing more reaches Slack) and the
/// Keychain keeps the session: only an explicit sign-out deletes it, and the next sign-in
/// replaces it.
- (void)signedOut:(SNSession *)session {
    // The sign-in window opens first, so the shell's is never the last window to close.
    [SNPreferencesDialog.current close];
    [SNPopover.current close];
    SNResetExpandedSnippets();
    [self showSignInAfter:session];
    [self.shell.window close];
    self.shell = nil;
    self.source = nil;
    self.account = nil;
    [self setMenuWithShell:NO];
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    if (!self.account && !self.signingOut.count) return NSTerminateNow;
    __block NSInteger waiting = (self.account ? 1 : 0) + (self.signingOut.count ? 1 : 0);
    __block BOOL replied = NO;
    __block BOOL returning = NO;
    void (^done)(void) = ^{
        if (replied || --waiting > 0) return;
        replied = YES;
        if (returning) dispatch_async(dispatch_get_main_queue(), ^{ [NSApp replyToApplicationShouldTerminate:YES]; });
    };
    if (self.account) [self.account finishWithin:SNLastCallsWait completion:done];
    if (self.signingOut.count) {
        [self.signOutWaiters addObject:done];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SNLastCallsWait * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (replied) return;
            replied = YES;
            [NSApp replyToApplicationShouldTerminate:YES];
        });
    }
    if (replied) return NSTerminateNow;
    returning = YES;
    return NSTerminateLater;
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [self.account stop];
    for (SNAccount *account in [self.signingOut copy]) [account stop];
}
// Only the shell's window ends the app: between sign-in and the first boot there is no window at
// all, and a sign-in window closed without a session quits from its completion.
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return self.shell != nil; }

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        SNTraceLaunch(@"main");
#ifndef SN_RELEASE
        if (argc > 2 && !strcmp(argv[1], "--selftest")) return SNRunSelfTest(@(argv[2]), Arguments(argc, argv, 3));
        if (argc > 3 && !strcmp(argv[1], "--snapshot")) return SNRunSnapshots(@(argv[2]), @(argv[3]), Arguments(argc, argv, 4));
        if (argc > 2 && !strcmp(argv[1], "--bench")) return SNRunBench([NSURL fileURLWithPath:@(argv[2])]);
#endif
        if (argc > 2 && !strcmp(argv[1], "--memory")) return SNMeasureMemory([NSURL fileURLWithPath:@(argv[2])]);
        __attribute__((objc_precise_lifetime)) SNAppDelegate *delegate = [SNAppDelegate new];
        if (argc > 2 && !strcmp(argv[1], "--fixture")) {
            delegate.source = SNOpenFixture([NSURL fileURLWithPath:@(argv[2])]);
            delegate.defaults = SNAppDefaults(nil);
            if (!delegate.source) {
                fprintf(stderr, "slack-native: no fixture at %s\n", argv[2]);
                return 1;
            }
        } else if (argc > 1 && !strncmp(argv[1], "--", 2)) {
            fprintf(stderr, "usage: slack-native [--fixture <folder> | --selftest <repo> [--slow] [--jobs N] [name...] | --snapshot <repo> <output> [--jobs N] [name...] | "
                            "--bench <fixture> | --memory <fixture>]\n");
            return 2;
        } else {
            // Overlap Keychain XPC, SQLite open, first-frame cache decode, and font/icon warm-up
            // with AppKit's startup (~100 ms) so they add 0 ms to the critical path.
            SNLaunchPreload *preload = [SNLaunchPreload new];
            preload.locked = SNHoldInstanceLock(SNInstanceLockFile());
            if (preload.locked) {
                preload.group = dispatch_group_create();
                dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
                dispatch_group_async(preload.group, queue, ^{
                    preload.secrets = [SNKeychain sessionKeychain];
                    preload.session = SNLoadSession(preload.secrets);
                    SNTraceLaunch(@"keychain");
                    NSString *teamID = preload.session.teams.firstObject.teamID;
                    if (!teamID.length) return;
                    SNDatabase *database = [SNDatabase databaseAtURL:[SNDatabase URLForWorkspace:teamID]];
                    SNTraceLaunch(@"database");
                    preload.store = [[SNStore alloc] initWithDatabase:database api:nil deferred:YES];
                    SNTraceLaunch(@"cache");
                });
                dispatch_async(queue, ^{
                    (void)SNFont(SNFontSizeBase, SNFontWeightRegular);
                    (void)SNFont(SNFontSizeBase, SNFontWeightBold);
                    (void)SNFont(SNFontSizeBase, SNFontWeightBlack);
                    (void)SNFont(SNFontSizeCaption, SNFontWeightRegular);
                    (void)SNFont(SNFontSizeCaption, SNFontWeightBold);
                    (void)SNFont(SNFontSizeSubtitle, SNFontWeightBlack);
                    (void)SNHasSlackIcons();
                });
            }
            delegate.preload = preload;
        }
        NSApplication *app = NSApplication.sharedApplication;
        app.activationPolicy = NSApplicationActivationPolicyRegular;
        app.delegate = delegate;
        [app run];
        return 0;
    }
}
