// Native macOS tabbed Settings window matching Spotifly PreferencesView.swift (General, Playback, Shortcuts)
// while preserving FairPlay/Soloist audio engine selector and conditional Soloist key controls.
#import "ui/prefs/prefs.h"
#import "render/icons.h"
#import "theme/theme.h"
#import "ui/kit/controls.h"

NSString *const kSPAppearanceModeDefaultsKey = @"sp.appearanceMode";

static NSToolbarItemIdentifier const kSPPrefsTabGeneral = @"sp.prefs.general";
static NSToolbarItemIdentifier const kSPPrefsTabPlayback = @"sp.prefs.playback";
static NSToolbarItemIdentifier const kSPPrefsTabShortcuts = @"sp.prefs.shortcuts";

void SPApplySavedAppearancePreference(void) {
    SPAppearanceMode mode = (SPAppearanceMode)[NSUserDefaults.standardUserDefaults integerForKey:kSPAppearanceModeDefaultsKey];
    if (mode == SPAppearanceLight) {
        NSApp.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    } else if (mode == SPAppearanceDark) {
        NSApp.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    } else {
        NSApp.appearance = nil; // Follow macOS System Appearance automatically
    }
}

static void SPDrawPrefsCard(CGContextRef ctx, CGRect rect) {
    CGPathRef p = CGPathCreateWithRoundedRect(rect, 10.0, 10.0, NULL);
    CGContextSetFillColorWithColor(ctx, SPCardSurfaceColor().CGColor);
    CGContextAddPath(ctx, p);
    CGContextFillPath(ctx);
    CGContextSetStrokeColorWithColor(ctx, SPSeparatorColor().CGColor);
    CGContextSetLineWidth(ctx, 1.0);
    CGContextAddPath(ctx, p);
    CGContextStrokePath(ctx);
    CGPathRelease(p);
}

static void SPDrawVersionFooter(CGRect bounds) {
    NSString *ver = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"0.1";
    NSString *bld = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"1";
    NSString *text = [NSString stringWithFormat:@"Spotify Native %@ (%@)", ver, bld];
    [text drawInRect:NSMakeRect(16.0, bounds.size.height - 26.0, bounds.size.width - 32.0, 16.0)
      withAttributes:SPSemanticTextAttributes(SPThemeTypography()->caption, SPSecondaryLabelColor(), NSLineBreakByTruncatingTail, NSTextAlignmentCenter)];
}

#pragma mark - Tab Views

@interface SPPrefsGeneralView : NSView
@property (nonatomic, readonly) NSSegmentedControl *appearanceControl;
@end

@implementation SPPrefsGeneralView

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _appearanceControl = [NSSegmentedControl segmentedControlWithLabels:@[ @"System", @"Light", @"Dark" ]
                                                           trackingMode:NSSegmentSwitchTrackingSelectOne
                                                                 target:self
                                                                 action:@selector(appearanceChanged:)];
    _appearanceControl.selectedSegmentBezelColor = SPAccentColor();
    SPAppearanceMode mode = (SPAppearanceMode)[NSUserDefaults.standardUserDefaults integerForKey:kSPAppearanceModeDefaultsKey];
    _appearanceControl.selectedSegment = MIN(2, MAX(0, (NSInteger)mode));
    [self addSubview:_appearanceControl];
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)appearanceChanged:(NSSegmentedControl *)sender {
    [NSUserDefaults.standardUserDefaults setInteger:sender.selectedSegment forKey:kSPAppearanceModeDefaultsKey];
    SPApplySavedAppearancePreference();
}

- (void)layout {
    [super layout];
    [_appearanceControl sizeToFit];
    CGFloat sw = _appearanceControl.frame.size.width;
    CGFloat sh = _appearanceControl.frame.size.height;
    _appearanceControl.frame = NSMakeRect(self.bounds.size.width - 36.0 - sw, 26.0 + floor((44.0 - sh) * 0.5), sw, sh);
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    if (!ctx) return;
    CGContextSetFillColorWithColor(ctx, SPWindowBackgroundColor().CGColor);
    CGContextFillRect(ctx, self.bounds);

    SPDrawPrefsCard(ctx, CGRectMake(20.0, 26.0, self.bounds.size.width - 40.0, 44.0));
    [@"Appearance" drawInRect:NSMakeRect(34.0, 39.0, 160.0, 18.0)
               withAttributes:SPSemanticTextAttributes(SPThemeTypography()->body, SPLabelColor(), NSLineBreakByClipping, NSTextAlignmentLeft)];
    SPDrawVersionFooter(self.bounds);
}

@end

@interface SPPrefsPlaybackView : NSView
@property (nonatomic, copy) NSString *accountSummary;
@property (nonatomic, copy) NSString *engineStatusText;
@property (nonatomic) BOOL showSoloistKeyLabel;
@end

@implementation SPPrefsPlaybackView

- (BOOL)isFlipped { return YES; }

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    if (!ctx) return;
    const SPTypographyScale *typo = SPThemeTypography();
    CGFloat w = self.bounds.size.width;
    SPTextStyle secStyle = {12.0, NSFontWeightSemibold, 16.0, 0.0, NO};

    CGContextSetFillColorWithColor(ctx, SPWindowBackgroundColor().CGColor);
    CGContextFillRect(ctx, self.bounds);

    // Card 1: Audio Engine
    [@"Audio Engine" drawInRect:NSMakeRect(32.0, 16.0, 200.0, 16.0)
                 withAttributes:SPSemanticTextAttributes(secStyle, SPSecondaryLabelColor(), NSLineBreakByClipping, NSTextAlignmentLeft)];
    CGFloat card1H = _showSoloistKeyLabel ? 148.0 : 94.0;
    SPDrawPrefsCard(ctx, CGRectMake(20.0, 36.0, w - 40.0, card1H));

    [_engineStatusText drawInRect:NSMakeRect(34.0, 88.0, w - 180.0, 16.0)
                   withAttributes:SPSemanticTextAttributes(typo->caption, SPSecondaryLabelColor(), NSLineBreakByTruncatingTail, NSTextAlignmentLeft)];

    if (_showSoloistKeyLabel) {
        CGContextSetFillColorWithColor(ctx, SPSeparatorColor().CGColor);
        CGContextFillRect(ctx, CGRectMake(34.0, 114.0, w - 68.0, 1.0));
        [@"Soloist Key (required for Soloist fallback)"
            drawInRect:NSMakeRect(34.0, 122.0, w - 68.0, 16.0)
        withAttributes:SPSemanticTextAttributes(typo->caption, NSColor.systemOrangeColor, NSLineBreakByTruncatingTail, NSTextAlignmentLeft)];
    }

    // Card 2: Playback & Account
    CGFloat card2Y = 36.0 + card1H + 34.0;
    [@"Playback & Account" drawInRect:NSMakeRect(32.0, card2Y - 20.0, 200.0, 16.0)
                       withAttributes:SPSemanticTextAttributes(secStyle, SPSecondaryLabelColor(), NSLineBreakByClipping, NSTextAlignmentLeft)];
    SPDrawPrefsCard(ctx, CGRectMake(20.0, card2Y, w - 40.0, 90.0));

    CGContextSetFillColorWithColor(ctx, SPSeparatorColor().CGColor);
    CGContextFillRect(ctx, CGRectMake(34.0, card2Y + 44.0, w - 68.0, 1.0));

    [_accountSummary drawInRect:NSMakeRect(34.0, card2Y + 58.0, w - 160.0, 18.0)
                 withAttributes:SPSemanticTextAttributes(typo->body, SPSecondaryLabelColor(), NSLineBreakByTruncatingTail, NSTextAlignmentLeft)];

    SPDrawVersionFooter(self.bounds);
}

@end

@interface SPPrefsShortcutsView : NSView
@end

@implementation SPPrefsShortcutsView

- (BOOL)isFlipped { return YES; }

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    if (!ctx) return;
    CGContextSetFillColorWithColor(ctx, SPWindowBackgroundColor().CGColor);
    CGContextFillRect(ctx, self.bounds);

    NSArray<NSArray<NSString *> *> *rows = @[
        @[ @"Play / Pause", @"Space" ],
        @[ @"Next Track", @"⌘→" ],
        @[ @"Previous Track", @"⌘←" ],
        @[ @"Volume Up", @"⌘↑" ],
        @[ @"Volume Down", @"⌘↓" ],
        @[ @"Search", @"⌘K / ⌘L" ],
        @[ @"Back / Forward", @"⌘[ / ⌘]" ],
        @[ @"Settings", @"⌘," ],
    ];
    CGFloat w = self.bounds.size.width;
    CGFloat rowH = 34.0;
    CGRect card = CGRectMake(20.0, 20.0, w - 40.0, (CGFloat)rows.count * rowH);
    SPDrawPrefsCard(ctx, card);

    const SPTypographyScale *typo = SPThemeTypography();
    NSDictionary *leftAttrs = SPSemanticTextAttributes(typo->body, SPLabelColor(), NSLineBreakByClipping, NSTextAlignmentLeft);
    NSDictionary *rightAttrs = SPSemanticTextAttributes(typo->body, SPSecondaryLabelColor(), NSLineBreakByClipping, NSTextAlignmentRight);

    for (NSUInteger i = 0; i < rows.count; i++) {
        CGFloat y = card.origin.y + (CGFloat)i * rowH;
        [rows[i][0] drawInRect:NSMakeRect(card.origin.x + 14.0, y + 8.0, 220.0, 18.0) withAttributes:leftAttrs];
        [rows[i][1] drawInRect:NSMakeRect(NSMaxX(card) - 134.0, y + 8.0, 120.0, 18.0) withAttributes:rightAttrs];
        if (i + 1 < rows.count) {
            CGContextSetFillColorWithColor(ctx, SPSeparatorColor().CGColor);
            CGContextFillRect(ctx, CGRectMake(card.origin.x + 14.0, y + rowH - 1.0, card.size.width - 28.0, 1.0));
        }
    }
    SPDrawVersionFooter(self.bounds);
}

@end

#pragma mark - SPPreferencesWindowController

@implementation SPPreferencesWindowController {
    SPStore *_store;
    NSToolbar *_toolbar;
    SPPrefsGeneralView *_generalView;
    SPPrefsPlaybackView *_playbackView;
    SPPrefsShortcutsView *_shortcutsView;

    NSPopUpButton *_enginePopup;
    SPButton *_changeKeyBtn;
    NSSecureTextField *_soloistKeyField;
    SPButton *_saveKeyBtn;
    NSButton *_songRadioCheck;
    SPButton *_signOutBtn;
    BOOL _editingSoloistKey;
    NSToolbarItemIdentifier _selectedTab;
}

- (instancetype)initWithStore:(SPStore *)store {
    NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 560.0, 340.0)
                                                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                  backing:NSBackingStoreBuffered
                                                    defer:YES];
    win.title = @"Settings";
    win.toolbarStyle = NSWindowToolbarStylePreference;
    win.releasedWhenClosed = NO;

    if (!(self = [super initWithWindow:win])) return nil;
    _store = store;
    _songRadioEnabled = YES;
    _selectedTab = kSPPrefsTabPlayback;

    _toolbar = [[NSToolbar alloc] initWithIdentifier:@"sp.prefs.toolbar"];
    _toolbar.delegate = self;
    _toolbar.displayMode = NSToolbarDisplayModeIconAndLabel;
    _toolbar.allowsUserCustomization = NO;
    _toolbar.selectedItemIdentifier = _selectedTab;
    win.toolbar = _toolbar;

    _generalView = [[SPPrefsGeneralView alloc] initWithFrame:NSMakeRect(0, 0, 560.0, 130.0)];
    _playbackView = [[SPPrefsPlaybackView alloc] initWithFrame:NSMakeRect(0, 0, 560.0, 340.0)];
    _shortcutsView = [[SPPrefsShortcutsView alloc] initWithFrame:NSMakeRect(0, 0, 560.0, 336.0)];

    __weak typeof(self) weakSelf = self;

    _enginePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(34.0, 48.0, 492.0, 28.0) pullsDown:NO];
    [_enginePopup addItemsWithTitles:@[
        @"Auto (FairPlay native primary, Soloist fallback)",
        @"FairPlay Native (256 kbps AAC, zero daemon)",
        @"Soloist Fallback",
    ]];
    _enginePopup.target = self;
    _enginePopup.action = @selector(enginePopupChanged:);
    [_playbackView addSubview:_enginePopup];

    _changeKeyBtn = [SPButton pillButtonWithTitle:@"Change Key..." style:SPButtonStyleSecondary frame:NSMakeRect(416.0, 82.0, 110.0, 26.0)];
    _changeKeyBtn.onClick = ^{ [weakSelf beginEditingSoloistKey]; };
    [_playbackView addSubview:_changeKeyBtn];

    _soloistKeyField = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(34.0, 144.0, 400.0, 24.0)];
    _soloistKeyField.placeholderString = @"Enter Soloist key";
    [_playbackView addSubview:_soloistKeyField];

    _saveKeyBtn = [SPButton pillButtonWithTitle:@"Save Key" style:SPButtonStylePrimary frame:NSMakeRect(442.0, 142.0, 84.0, 28.0)];
    _saveKeyBtn.onClick = ^{
        SPPreferencesWindowController *s = weakSelf;
        if (!s) return;
        NSString *val = [s->_soloistKeyField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (val.length) {
            s->_soloistKeyValue = val;
            s->_soloistKeyMissingOrFailed = NO;
            s->_editingSoloistKey = NO;
            if (s.onSaveSoloistKey) s.onSaveSoloistKey(val);
            [s refreshState];
        }
    };
    [_playbackView addSubview:_saveKeyBtn];

    _songRadioCheck = [NSButton checkboxWithTitle:@"Continue playback with Song Radio after standalone tracks"
                                           target:self
                                           action:@selector(songRadioToggled:)];
    _songRadioCheck.state = NSControlStateValueOn;
    [_playbackView addSubview:_songRadioCheck];

    _signOutBtn = [SPButton pillButtonWithTitle:@"Log Out" style:SPButtonStyleDestructive frame:NSZeroRect];
    _signOutBtn.onClick = ^{
        if (weakSelf.onSignOut) weakSelf.onSignOut();
    };
    [_playbackView addSubview:_signOutBtn];

    [_store addObserver:self];
    [self selectTab:_selectedTab animate:NO];
    [self refreshState];
    return self;
}

- (void)dealloc {
    [_store removeObserver:self];
}

#pragma mark - NSToolbarDelegate

- (NSArray<NSToolbarItemIdentifier> *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar {
    (void)toolbar;
    return @[ kSPPrefsTabGeneral, kSPPrefsTabPlayback, kSPPrefsTabShortcuts ];
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar {
    return [self toolbarAllowedItemIdentifiers:toolbar];
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarSelectableItemIdentifiers:(NSToolbar *)toolbar {
    return [self toolbarAllowedItemIdentifiers:toolbar];
}

- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar itemForItemIdentifier:(NSToolbarItemIdentifier)itemIdentifier willBeInsertedIntoToolbar:(BOOL)flag {
    (void)toolbar; (void)flag;
    NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:itemIdentifier];
    item.target = self;
    item.action = @selector(toolbarTabClicked:);
    if ([itemIdentifier isEqualToString:kSPPrefsTabGeneral]) {
        item.label = @"General";
        item.image = SPSFSymbolImage(@"gearshape", 16.0, NSFontWeightRegular, nil);
    } else if ([itemIdentifier isEqualToString:kSPPrefsTabPlayback]) {
        item.label = @"Playback";
        item.image = SPSFSymbolImage(@"speaker.wave.3", 16.0, NSFontWeightRegular, nil);
    } else {
        item.label = @"Shortcuts";
        item.image = SPSFSymbolImage(@"command", 16.0, NSFontWeightRegular, nil);
    }
    return item;
}

- (void)toolbarTabClicked:(NSToolbarItem *)sender {
    [self selectTab:sender.itemIdentifier animate:YES];
}

- (void)selectTab:(NSToolbarItemIdentifier)tab animate:(BOOL)animate {
    _selectedTab = tab;
    _toolbar.selectedItemIdentifier = tab;
    NSView *target = _playbackView;
    CGFloat height = self.soloistKeySectionVisible ? 350.0 : 298.0;
    NSString *title = @"Playback";
    if ([tab isEqualToString:kSPPrefsTabGeneral]) {
        target = _generalView;
        height = 126.0;
        title = @"General";
    } else if ([tab isEqualToString:kSPPrefsTabShortcuts]) {
        target = _shortcutsView;
        height = 334.0;
        title = @"Shortcuts";
    }
    self.window.title = title;
    target.frame = NSMakeRect(0.0, 0.0, 560.0, height);
    self.window.contentView = target;

    NSRect cur = self.window.frame;
    NSRect newFrame = [self.window frameRectForContentRect:NSMakeRect(0.0, 0.0, 560.0, height)];
    newFrame.origin.x = cur.origin.x;
    newFrame.origin.y = NSMaxY(cur) - newFrame.size.height;
    [self.window setFrame:newFrame display:YES animate:animate];
}

#pragma mark - State & Actions

- (BOOL)isSoloistRelevant {
    return (_enginePreference == SPAudioEnginePrefSoloist) || (_activeEngineKind == SPAudioEngineKindSoloist);
}

- (BOOL)soloistKeySectionVisible {
    return [self isSoloistRelevant] && (_soloistKeyMissingOrFailed || _editingSoloistKey);
}

- (BOOL)soloistChangeKeyButtonVisible {
    return [self isSoloistRelevant] && !self.soloistKeySectionVisible;
}

- (void)beginEditingSoloistKey {
    _editingSoloistKey = YES;
    [self refreshState];
    if (_soloistKeyField && !_soloistKeyField.hidden) {
        [self.window makeFirstResponder:_soloistKeyField];
    }
}

- (void)enginePopupChanged:(NSPopUpButton *)sender {
    _enginePreference = (SPAudioEnginePreference)sender.indexOfSelectedItem;
    if (![self isSoloistRelevant]) _editingSoloistKey = NO;
    if (self.onEnginePreferenceChange) self.onEnginePreferenceChange(_enginePreference);
    [self refreshState];
}

- (void)songRadioToggled:(NSButton *)sender {
    _songRadioEnabled = (sender.state == NSControlStateValueOn);
    if (self.onSongRadioToggle) self.onSongRadioToggle(_songRadioEnabled);
}

- (void)storeChanged:(SPChange *)change {
    if (change.profile || change.connection || change.devices) {
        [self refreshState];
    }
}

- (void)refreshState {
    SPUserProfile *prof = _store.userProfile;
    _playbackView.accountSummary = prof.displayName.length
        ? [NSString stringWithFormat:@"Signed in as %@ (%@)", prof.displayName, prof.username]
        : @"Signed in";
    _playbackView.engineStatusText = (_activeEngineKind == SPAudioEngineKindFairPlay)
        ? @"Active engine: Apple FairPlay Native (256 kbps AAC)"
        : @"Active engine: Soloist Fallback";

    [_enginePopup selectItemAtIndex:(NSInteger)_enginePreference];
    _songRadioCheck.state = _songRadioEnabled ? NSControlStateValueOn : NSControlStateValueOff;

    BOOL showKey = self.soloistKeySectionVisible;
    _playbackView.showSoloistKeyLabel = showKey;
    _changeKeyBtn.hidden = !self.soloistChangeKeyButtonVisible;
    _soloistKeyField.hidden = !showKey;
    _saveKeyBtn.hidden = !showKey;
    if (_soloistKeyValue.length && _soloistKeyField.stringValue.length == 0) {
        _soloistKeyField.stringValue = _soloistKeyValue;
    }

    CGFloat card1H = showKey ? 148.0 : 94.0;
    CGFloat card2Y = 36.0 + card1H + 34.0;
    _songRadioCheck.frame = NSMakeRect(34.0, card2Y + 11.0, 492.0, 22.0);
    _signOutBtn.frame = NSMakeRect(436.0, card2Y + 53.0, 90.0, 28.0);

    if ([_selectedTab isEqualToString:kSPPrefsTabPlayback]) {
        [self selectTab:kSPPrefsTabPlayback animate:NO];
    }
    _playbackView.needsDisplay = YES;
}

@end
