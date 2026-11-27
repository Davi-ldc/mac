// Spotifly 1:1 Floating Liquid Glass Now Playing capsule, Now Playing Inspector,
// Queue Page, and Playing On (Speakers) Page.
#import "ui/player/player.h"
#import "render/icons.h"
#import "render/images.h"
#import "theme/theme.h"
#import "ui/kit/controls.h"
#import "ui/kit/list.h"

static NSString *SPDeviceSymbolForType(SPDeviceType t) {
    switch (t) {
        case SPDeviceTypeComputer:
        case SPDeviceTypeChromebook: return @"laptopcomputer";
        case SPDeviceTypeSmartphone: return @"iphone";
        case SPDeviceTypeTablet: return @"ipad";
        case SPDeviceTypeTV:
        case SPDeviceTypeSTB:
        case SPDeviceTypeCastVideo: return @"tv";
        case SPDeviceTypeSpeaker:
        case SPDeviceTypeAVR:
        case SPDeviceTypeAudioDongle:
        case SPDeviceTypeCastAudio: return @"hifispeaker.fill";
        case SPDeviceTypeGameConsole: return @"gamecontroller.fill";
        case SPDeviceTypeAutomobile: return @"car.fill";
        case SPDeviceTypeSmartwatch: return @"applewatch";
        default: return @"hifispeaker.2";
    }
}

static NSString *SPDeviceLabelForType(SPDeviceType t) {
    switch (t) {
        case SPDeviceTypeComputer: return @"Computer";
        case SPDeviceTypeTablet: return @"Tablet";
        case SPDeviceTypeSmartphone: return @"Smartphone";
        case SPDeviceTypeSpeaker: return @"Speaker";
        case SPDeviceTypeTV: return @"TV";
        case SPDeviceTypeAVR: return @"AVR";
        case SPDeviceTypeSTB: return @"Set-Top Box";
        case SPDeviceTypeAudioDongle: return @"Audio Dongle";
        case SPDeviceTypeGameConsole: return @"Game Console";
        case SPDeviceTypeCastVideo: return @"Cast Video";
        case SPDeviceTypeCastAudio: return @"Cast Audio";
        case SPDeviceTypeAutomobile: return @"Car";
        case SPDeviceTypeSmartwatch: return @"Watch";
        case SPDeviceTypeChromebook: return @"Chromebook";
        default: return @"Device";
    }
}

#pragma mark - SPPlayerBarContentView (hosted inside NSGlassEffectView capsule)

@interface SPPlayerBarContentView : NSView
@property (nonatomic, weak) SPPlayerBarView *owner;
@property (nonatomic, strong, nullable) SPTrack *track;
@property (nonatomic) int64_t displayedPositionMs;
@property (nonatomic) int64_t displayedDurationMs;
@property (nonatomic) BOOL showTime;
@property (nonatomic) BOOL showRemaining;
@property (nonatomic) NSRect artRect;
@property (nonatomic) NSRect titleRect;
@property (nonatomic) NSRect artistRect;
@property (nonatomic) NSRect timeRect;
@property (nonatomic, copy, nullable) void (^onClickTitle)(void);
@property (nonatomic, copy, nullable) void (^onClickArtist)(void);
@property (nonatomic, copy, nullable) void (^onClickTime)(void);
@end

@implementation SPPlayerBarContentView {
    NSString *_lastArtURL;
}

- (BOOL)isFlipped { return YES; }

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (!self.window) SPReleaseViewImages(self);
}

- (void)setTrack:(SPTrack *)track {
    NSString *url = track.artworkSmallURL.length ? track.artworkSmallURL : track.artworkURL;
    if (![_lastArtURL isEqualToString:url ?: @""]) {
        [self.imageHolder removeAllImages];
        _lastArtURL = [url copy];
    }
    _track = track;
    self.needsDisplay = YES;
}

- (void)mouseDown:(NSEvent *)event {
    if ([self.window.firstResponder isKindOfClass:NSText.class]) {
        [self.window makeFirstResponder:nil];
    }
    NSPoint pt = [self convertPoint:event.locationInWindow fromView:nil];
    if (!NSIsEmptyRect(_timeRect) && NSPointInRect(pt, _timeRect) && _onClickTime) {
        _onClickTime();
        return;
    }
    if (!NSIsEmptyRect(_titleRect) && NSPointInRect(pt, _titleRect) && _onClickTitle) {
        _onClickTitle();
        return;
    }
    if (!NSIsEmptyRect(_artistRect) && NSPointInRect(pt, _artistRect) && _onClickArtist) {
        _onClickArtist();
        return;
    }
    [super mouseDown:event];
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    if (!ctx) return;

    const SPTypographyScale *typo = SPThemeTypography();

    // 40x40pt rounded (6pt) album artwork (Spotifly NowPlayingBarView.artworkSize = 40)
    CGImageRef img = NULL;
    if (_lastArtURL.length) {
        NSURL *u = [NSURL URLWithString:_lastArtURL];
        if (u) {
            CGFloat scale = self.window.backingScaleFactor ?: 2.0;
            img = [self.imageHolder imageWithURL:u pixels:ceil(40.0 * scale)];
        }
    }
    SPDrawArtworkSemantic(ctx, img, _artRect, 6.0, NO, @"music.note", 18.0, 0.0);

    // Track title, artist, and "0:05 / 2:10" tabular time beside title
    if (_track) {
        [_track.name drawInRect:_titleRect
                 withAttributes:SPSemanticTextAttributes(typo->headline, SPLabelColor(), NSLineBreakByTruncatingTail, NSTextAlignmentLeft)];
        [_track.artistName drawInRect:_artistRect
                       withAttributes:SPSemanticTextAttributes(typo->callout, SPSecondaryLabelColor(), NSLineBreakByTruncatingTail, NSTextAlignmentLeft)];
    } else {
        [@"Nothing Playing" drawInRect:_titleRect
                        withAttributes:SPSemanticTextAttributes(typo->callout, SPSecondaryLabelColor(), NSLineBreakByTruncatingTail, NSTextAlignmentLeft)];
    }

    if (_showTime && !NSIsEmptyRect(_timeRect)) {
        NSString *pos = SPFormatDurationMs(_displayedPositionMs);
        NSString *dur = _showRemaining
            ? [NSString stringWithFormat:@"-%@", SPFormatDurationMs(MAX(0, _displayedDurationMs - _displayedPositionMs))]
            : SPFormatDurationMs(_displayedDurationMs);
        NSString *timeStr = [NSString stringWithFormat:@"%@ / %@", pos, dur];
        [timeStr drawInRect:_timeRect
             withAttributes:SPSemanticTextAttributes(typo->monoTime, SPSecondaryLabelColor(), NSLineBreakByClipping, NSTextAlignmentRight)];
    }
}

@end

#pragma mark - SPPlayerBarView (Floating Liquid Glass Capsule matching Spotifly 1:1)

@implementation SPPlayerBarView {
    SPStore *_store;
    NSView *_glassContainer;
    SPPlayerBarContentView *_content;

    SPButton *_shuffleBtn;
    SPButton *_prevBtn;
    SPButton *_playPauseBtn;
    SPButton *_nextBtn;
    SPButton *_repeatBtn;
    SPSlider *_scrubSlider;
    SPHeartButton *_heartBtn;
    SPButton *_moreBtn;
    SPButton *_speakersBtn;
    SPButton *_muteBtn;
    SPSlider *_volumeSlider;
    SPButton *_inspectorBtn;

    NSTimer *_progressTimer;
    BOOL _showRemaining;
    int64_t _displayedPositionMs;
    int64_t _displayedDurationMs;
}

- (instancetype)initWithFrame:(NSRect)frame store:(SPStore *)store navigator:(id<SPNavigator>)navigator {
    if (!(self = [super initWithFrame:frame])) return nil;
    _store = store;
    _navigator = navigator;
    _volumePercent = 80;

    _content = [[SPPlayerBarContentView alloc] initWithFrame:self.bounds];
    _content.owner = self;

    __weak typeof(self) weakSelf = self;
    _content.onClickTitle = ^{
        SPPlayerBarView *s = weakSelf;
        if (!s) return;
        SPTrack *t = s->_content.track;
        if (t.albumID.length) [s.navigator openAlbumWithID:t.albumID];
    };
    _content.onClickArtist = ^{
        SPPlayerBarView *s = weakSelf;
        if (!s) return;
        SPTrack *t = s->_content.track;
        if (t.artistID.length) [s.navigator openArtistWithID:t.artistID];
    };
    _content.onClickTime = ^{
        SPPlayerBarView *s = weakSelf;
        if (!s) return;
        s->_showRemaining = !s->_showRemaining;
        s->_content.showRemaining = s->_showRemaining;
        s->_content.needsDisplay = YES;
    };

    // Left transport cluster (exact Spotifly order: Shuffle, Prev, Play/Pause, Next, Repeat)
    _shuffleBtn = [SPButton iconButton:SPIconShuffle size:13.0 frame:NSZeroRect];
    _shuffleBtn.toolTip = @"Shuffle";
    _shuffleBtn.onClick = ^{ [weakSelf.navigator toggleShuffle]; };
    [_content addSubview:_shuffleBtn];

    _prevBtn = [SPButton iconButton:SPIconPrevious size:14.0 frame:NSZeroRect];
    _prevBtn.primaryWhenIdle = YES;
    _prevBtn.toolTip = @"Previous Track";
    _prevBtn.onClick = ^{ [weakSelf.navigator skipPrevious]; };
    [_content addSubview:_prevBtn];

    _playPauseBtn = [SPButton iconButton:SPIconPlay size:22.0 frame:NSZeroRect];
    _playPauseBtn.primaryWhenIdle = YES;
    _playPauseBtn.iconWeight = NSFontWeightRegular;
    _playPauseBtn.toolTip = @"Play / Pause";
    _playPauseBtn.onClick = ^{ [weakSelf.navigator togglePlayPause]; };
    [_content addSubview:_playPauseBtn];

    _nextBtn = [SPButton iconButton:SPIconNext size:14.0 frame:NSZeroRect];
    _nextBtn.primaryWhenIdle = YES;
    _nextBtn.toolTip = @"Next Track";
    _nextBtn.onClick = ^{ [weakSelf.navigator skipNext]; };
    [_content addSubview:_nextBtn];

    _repeatBtn = [SPButton iconButton:SPIconRepeat size:13.0 frame:NSZeroRect];
    _repeatBtn.toolTip = @"Repeat";
    _repeatBtn.onClick = ^{ [weakSelf.navigator cycleRepeatMode]; };
    [_content addSubview:_repeatBtn];

    // Center scrubber (white/primary track + white circular thumb)
    _scrubSlider = [[SPSlider alloc] initWithFrame:NSZeroRect];
    _scrubSlider.accentFill = NO;
    _scrubSlider.alwaysShowKnob = YES;
    _scrubSlider.onChange = ^(double val) {
        SPPlayerBarView *s = weakSelf;
        if (!s) return;
        s->_displayedPositionMs = (int64_t)val;
        s->_content.displayedPositionMs = s->_displayedPositionMs;
        s->_content.needsDisplay = YES;
    };
    _scrubSlider.onCommit = ^(double val) {
        [weakSelf.navigator seekToMs:(int64_t)val];
    };
    [_content addSubview:_scrubSlider];

    // Right actions cluster (exact Spotifly order: Heart, More, Playing On, Volume icon + green slider, Inspector)
    _heartBtn = [[SPHeartButton alloc] initWithFrame:NSZeroRect];
    _heartBtn.primaryWhenUnfavorited = YES;
    _heartBtn.iconPointSize = 13.5;
    _heartBtn.toolTip = @"Favorite";
    _heartBtn.onToggle = ^{
        SPPlayerBarView *s = weakSelf;
        if (!s) return;
        NSString *tid = s->_store.playbackState.currentTrackID;
        if (tid.length) [s.navigator toggleFavoriteTrackID:tid];
    };
    [_content addSubview:_heartBtn];

    _moreBtn = [SPButton iconButton:SPIconMore size:14.0 frame:NSZeroRect];
    _moreBtn.primaryWhenIdle = YES;
    _moreBtn.toolTip = @"More Options";
    _moreBtn.onClick = ^{ [weakSelf showCurrentTrackMenu]; };
    [_content addSubview:_moreBtn];

    _speakersBtn = [SPButton iconButton:SPIconDevicesOutline size:14.0 frame:NSZeroRect];
    _speakersBtn.primaryWhenIdle = YES;
    _speakersBtn.toolTip = @"Playing On…";
    _speakersBtn.onClick = ^{ [weakSelf.navigator openSpeakers]; };
    [_content addSubview:_speakersBtn];

    _muteBtn = [SPButton iconButton:SPIconSpeakerMed size:12.5 frame:NSZeroRect];
    _muteBtn.toolTip = @"Volume";
    _muteBtn.onClick = ^{ [weakSelf.navigator toggleMute]; };
    [_content addSubview:_muteBtn];

    // GREEN #1DB954 volume slider matching Spotifly screenshot 38.png 1:1
    _volumeSlider = [[SPSlider alloc] initWithFrame:NSZeroRect];
    _volumeSlider.minValue = 0.0;
    _volumeSlider.maxValue = 100.0;
    _volumeSlider.doubleValue = (double)_volumePercent;
    _volumeSlider.accentFill = YES;
    _volumeSlider.alwaysShowKnob = YES;
    _volumeSlider.onChange = ^(double val) {
        SPPlayerBarView *s = weakSelf;
        if (!s) return;
        s->_volumePercent = (NSInteger)llround(val);
        [s syncVolumeIcon];
        [s.navigator previewVolumePercent:s->_volumePercent];
    };
    _volumeSlider.onCommit = ^(double val) {
        SPPlayerBarView *s = weakSelf;
        if (!s) return;
        s->_volumePercent = (NSInteger)llround(val);
        [s syncVolumeIcon];
        [s.navigator setVolumePercent:s->_volumePercent];
    };
    [_content addSubview:_volumeSlider];

    _inspectorBtn = [SPButton iconButton:SPIconInspector size:14.5 frame:NSZeroRect];
    _inspectorBtn.primaryWhenIdle = YES;
    _inspectorBtn.toolTip = @"Now Playing";
    _inspectorBtn.onClick = ^{ [weakSelf.navigator toggleInspector]; };
    [_content addSubview:_inspectorBtn];

    _glassContainer = SPCreateGlassContainerView(self.bounds, 32.0, _content);
    [self addSubview:_glassContainer];

    [_store addObserver:self];
    [self syncFromStore];
    return self;
}

- (void)dealloc {
    [self stopProgressTimer];
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [_store removeObserver:self];
}

- (BOOL)isFlipped { return YES; }
- (BOOL)progressTimerRunning { return _progressTimer != nil; }

- (void)viewWillMoveToWindow:(NSWindow *)newWindow {
    if (self.window) {
        [NSNotificationCenter.defaultCenter removeObserver:self
                                                      name:NSWindowDidChangeOcclusionStateNotification
                                                    object:self.window];
    }
    if (!newWindow) {
        [self stopProgressTimer];
        SPReleaseViewImages(_content);
    }
    [super viewWillMoveToWindow:newWindow];
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (self.window) {
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(windowOcclusionChanged:)
                                                   name:NSWindowDidChangeOcclusionStateNotification
                                                 object:self.window];
    }
    [self updateProgressTimerState];
}

- (void)windowOcclusionChanged:(NSNotification *)note {
    (void)note;
    [self updateProgressTimerState];
}

- (void)setVolumePercent:(NSInteger)volumePercent {
    _volumePercent = MIN(100, MAX(0, volumePercent));
    if (!_volumeSlider.isDragging) {
        _volumeSlider.doubleValue = (double)_volumePercent;
    }
    [self syncVolumeIcon];
}

- (void)setMuted:(BOOL)muted {
    _muted = muted;
    [self syncVolumeIcon];
}

- (void)setQueueOpen:(BOOL)queueOpen {
    _queueOpen = queueOpen;
}

- (void)setInspectorOpen:(BOOL)inspectorOpen {
    _inspectorOpen = inspectorOpen;
    _inspectorBtn.active = inspectorOpen;
}

- (void)syncVolumeIcon {
    if (_muted || _volumePercent == 0) _muteBtn.icon = SPIconSpeakerMute;
    else if (_volumePercent < 45) _muteBtn.icon = SPIconSpeakerLow;
    else if (_volumePercent < 80) _muteBtn.icon = SPIconSpeakerMed;
    else _muteBtn.icon = SPIconSpeaker;
}

- (void)showCurrentTrackMenu {
    SPTrack *track = _content.track;
    if (!track) return;
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];

    NSMenuItem *q = [[NSMenuItem alloc] initWithTitle:@"Play Next" action:@selector(menuAddToQueue:) keyEquivalent:@""];
    q.target = self;
    q.representedObject = track;
    q.image = SPSFSymbolImage(@"text.line.first.and.arrowtriangle.forward", 12.0, NSFontWeightRegular, nil);
    [menu addItem:q];

    NSMenuItem *radio = [[NSMenuItem alloc] initWithTitle:@"Start Song Radio" action:@selector(menuStartRadio:) keyEquivalent:@""];
    radio.target = self;
    radio.representedObject = track;
    radio.image = SPSFSymbolImage(@"dot.radiowaves.left.and.right", 12.0, NSFontWeightRegular, nil);
    [menu addItem:radio];

    [menu addItem:[NSMenuItem separatorItem]];

    BOOL fav = [_store isFavoriteTrackID:track.trackID];
    NSMenuItem *like = [[NSMenuItem alloc] initWithTitle:fav ? @"Remove from Favorites" : @"Add to Favorites"
                                                  action:@selector(menuToggleFav:)
                                           keyEquivalent:@""];
    like.target = self;
    like.representedObject = track;
    [menu addItem:like];

    if (track.artistID.length || track.albumID.length) [menu addItem:[NSMenuItem separatorItem]];
    if (track.artistID.length) {
        NSMenuItem *ar = [[NSMenuItem alloc] initWithTitle:@"Go to Artist" action:@selector(menuGoArtist:) keyEquivalent:@""];
        ar.target = self;
        ar.representedObject = track;
        [menu addItem:ar];
    }
    if (track.albumID.length) {
        NSMenuItem *al = [[NSMenuItem alloc] initWithTitle:@"Go to Album" action:@selector(menuGoAlbum:) keyEquivalent:@""];
        al.target = self;
        al.representedObject = track;
        [menu addItem:al];
    }

    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *copy = [[NSMenuItem alloc] initWithTitle:@"Copy Link" action:@selector(menuCopyLink:) keyEquivalent:@""];
    copy.target = self;
    copy.representedObject = track;
    copy.image = SPSFSymbolImage(@"link", 12.0, NSFontWeightRegular, nil);
    [menu addItem:copy];

    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0.0, _moreBtn.bounds.size.height + 4.0) inView:_moreBtn];
}

- (void)menuAddToQueue:(NSMenuItem *)sender { [_navigator addTrackToQueue:(SPTrack *)sender.representedObject]; }
- (void)menuStartRadio:(NSMenuItem *)sender { [_navigator playTrackWithRadio:(SPTrack *)sender.representedObject fallbackURIs:nil]; }
- (void)menuToggleFav:(NSMenuItem *)sender { [_navigator toggleFavoriteTrackID:((SPTrack *)sender.representedObject).trackID]; }
- (void)menuGoArtist:(NSMenuItem *)sender { SPTrack *t = sender.representedObject; if (t.artistID.length) [_navigator openArtistWithID:t.artistID]; }
- (void)menuGoAlbum:(NSMenuItem *)sender { SPTrack *t = sender.representedObject; if (t.albumID.length) [_navigator openAlbumWithID:t.albumID]; }
- (void)menuCopyLink:(NSMenuItem *)sender {
    SPTrack *t = sender.representedObject;
    if (!t.trackID.length) return;
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:[NSString stringWithFormat:@"https://open.spotify.com/track/%@", t.trackID]
                                      forType:NSPasteboardTypeString];
}

- (void)stopProgressTimer {
    [_progressTimer invalidate];
    _progressTimer = nil;
}

- (void)updateProgressTimerState {
    SPPlaybackState *pb = _store.playbackState;
    BOOL visible = (self.window != nil) && ((self.window.occlusionState & NSWindowOcclusionStateVisible) != 0);
    BOOL shouldRun = pb.isPlaying && visible;
    if (shouldRun && !_progressTimer) {
        __weak typeof(self) weakSelf = self;
        _progressTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
            (void)timer;
            [weakSelf tickProgress];
        }];
        _progressTimer.tolerance = 0.15;
    } else if (!shouldRun && _progressTimer) {
        [self stopProgressTimer];
    }
}

- (void)tickProgress {
    SPPlaybackState *pb = _store.playbackState;
    if (!pb || !pb.isPlaying || _scrubSlider.isDragging) return;
    int64_t nowMs = (int64_t)llround(NSDate.date.timeIntervalSince1970 * 1000.0);
    _displayedPositionMs = [pb interpolatedPositionMsAt:nowMs];
    _scrubSlider.doubleValue = (double)_displayedPositionMs;
    _content.displayedPositionMs = _displayedPositionMs;
    _content.needsDisplay = YES;
}

- (void)syncFromStore {
    SPPlaybackState *pb = _store.playbackState;
    SPTrack *track = pb.currentTrackID.length ? [_store trackWithID:pb.currentTrackID] : nil;
    BOOL hasPlayback = (pb.currentTrackURI.length > 0 || track != nil);

    _content.track = track;
    _playPauseBtn.icon = pb.isPlaying ? SPIconPause : SPIconPlay;
    _prevBtn.enabled = hasPlayback;
    _nextBtn.enabled = hasPlayback && (pb.canSkipNext || pb.nextTracks.count > 0);
    _shuffleBtn.active = pb.shuffling;
    _shuffleBtn.enabled = hasPlayback && pb.canShuffle;
    _repeatBtn.active = (pb.repeatMode != SPRepeatOff);
    _repeatBtn.icon = (pb.repeatMode == SPRepeatTrack) ? SPIconRepeatOne : SPIconRepeat;
    _repeatBtn.enabled = hasPlayback && (pb.repeatMode != SPRepeatOff || pb.canRepeatContext || pb.canRepeatTrack);

    _heartBtn.favorited = track ? [_store isFavoriteTrackID:track.trackID] : NO;
    _heartBtn.hidden = !hasPlayback;
    _moreBtn.hidden = (track == nil);

    BOOL remoteActive = NO;
    for (SPDevice *d in _store.devices) {
        if (d.isActive && d.deviceType != SPDeviceTypeComputer) { remoteActive = YES; break; }
    }
    _speakersBtn.active = remoteActive;

    int64_t durMs = pb.durationMs > 0 ? pb.durationMs : track.durationMs;
    _displayedDurationMs = MAX(0, durMs);
    if (!_scrubSlider.isDragging) {
        int64_t nowMs = (int64_t)llround(NSDate.date.timeIntervalSince1970 * 1000.0);
        _displayedPositionMs = pb ? [pb interpolatedPositionMsAt:nowMs] : 0;
        _scrubSlider.maxValue = (double)MAX(1, _displayedDurationMs);
        _scrubSlider.doubleValue = (double)_displayedPositionMs;
    }
    _content.displayedPositionMs = _displayedPositionMs;
    _content.displayedDurationMs = _displayedDurationMs;

    [self updateProgressTimerState];
    _content.needsDisplay = YES;
}

- (void)layout {
    [super layout];
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    _glassContainer.frame = self.bounds;
    SPUpdateGlassContainerCornerRadius(_glassContainer, h * 0.5);
    _content.frame = _glassContainer.bounds;

    // Spotifly Fit tiers: >= 680pt everything, 640..679pt hide volume, < 640pt hide time too.
    BOOL showVolume = (w >= 680.0);
    BOOL showTime = (w >= 640.0);
    _muteBtn.hidden = !showVolume;
    _volumeSlider.hidden = !showVolume;
    _content.showTime = showTime;

    // 1. Left transport cluster (paddingLeft 14pt)
    CGFloat lx = 14.0;
    CGFloat cy = floor(h * 0.5);
    _shuffleBtn.frame = NSMakeRect(lx, cy - 13.0, 24.0, 26.0); lx += 25.0;
    _prevBtn.frame = NSMakeRect(lx, cy - 13.0, 24.0, 26.0); lx += 25.0;
    _playPauseBtn.frame = NSMakeRect(lx, cy - 18.0, 34.0, 36.0); lx += 35.0;
    _nextBtn.frame = NSMakeRect(lx, cy - 13.0, 24.0, 26.0); lx += 25.0;
    _repeatBtn.frame = NSMakeRect(lx, cy - 13.0, 24.0, 26.0); lx += 26.0;

    // 2. Right actions cluster (paddingRight 16pt)
    CGFloat rx = w - 16.0;
    _inspectorBtn.frame = NSMakeRect(rx - 26.0, cy - 13.0, 26.0, 26.0); rx -= 28.0;
    if (showVolume) {
        _volumeSlider.frame = NSMakeRect(rx - 72.0, cy - 8.0, 72.0, 16.0); rx -= 74.0;
        _muteBtn.frame = NSMakeRect(rx - 20.0, cy - 11.0, 20.0, 22.0); rx -= 24.0;
    }
    _speakersBtn.frame = NSMakeRect(rx - 24.0, cy - 13.0, 24.0, 26.0); rx -= 26.0;
    _moreBtn.frame = NSMakeRect(rx - 24.0, cy - 13.0, 24.0, 26.0); rx -= 25.0;
    _heartBtn.frame = NSMakeRect(rx - 24.0, cy - 12.0, 24.0, 24.0); rx -= 28.0;

    // 3. Center track + scrubber block
    CGFloat midLeft = lx + 8.0;
    CGFloat midRight = MAX(midLeft + 100.0, rx - 6.0);
    _content.artRect = NSMakeRect(midLeft, floor((h - 40.0) * 0.5), 40.0, 40.0);

    CGFloat infoX = NSMaxX(_content.artRect) + 10.0;
    CGFloat infoW = MAX(60.0, midRight - infoX);
    CGFloat timeW = showTime ? 76.0 : 0.0;

    _content.titleRect = NSMakeRect(infoX, 9.0, MAX(30.0, infoW - timeW - (showTime ? 6.0 : 0.0)), 17.0);
    _content.timeRect = showTime ? NSMakeRect(infoX + infoW - timeW, 11.0, timeW, 14.0) : NSZeroRect;
    _content.artistRect = NSMakeRect(infoX, 26.0, infoW, 15.0);
    _scrubSlider.frame = NSMakeRect(infoX - 6.0, 42.0, infoW + 12.0, 14.0);
    _content.needsDisplay = YES;
}

- (void)storeChanged:(SPChange *)change {
    if (change.playback || change.devices || change.favorites.count > 0 || change.tracks.count > 0) {
        [self syncFromStore];
    }
}

@end

#pragma mark - SPNowPlayingInspectorView (320pt Right Column matching Spotifly NowPlayingInspector.swift)

@interface SPUpNextRowView : SPListRowView
@property (nonatomic, strong, nullable) SPTrack *track;
@property (nonatomic, copy, nullable) NSString *fallbackTitle;
@end

@implementation SPUpNextRowView {
    NSString *_lastArtURL;
}

- (void)setTrack:(SPTrack *)track {
    NSString *url = track.artworkSmallURL.length ? track.artworkSmallURL : track.artworkURL;
    if (![_lastArtURL isEqualToString:url ?: @""]) {
        [self.imageHolder removeAllImages];
        _lastArtURL = [url copy];
    }
    _track = track;
    self.needsDisplay = YES;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    _track = nil;
    _fallbackTitle = nil;
    _lastArtURL = nil;
    [self.imageHolder removeAllImages];
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    if (!ctx) return;

    const SPTypographyScale *typo = SPThemeTypography();
    NSRect b = self.bounds;
    if (self.isHovered) {
        CGContextSetFillColorWithColor(ctx, SPHoverFillColor().CGColor);
        CGPathRef p = CGPathCreateWithRoundedRect(NSInsetRect(b, 8.0, 1.0), 6.0, 6.0, NULL);
        CGContextAddPath(ctx, p);
        CGContextFillPath(ctx);
        CGPathRelease(p);
    }

    CGRect artRect = CGRectMake(16.0, floor((b.size.height - 32.0) * 0.5), 32.0, 32.0);
    CGImageRef img = NULL;
    if (_lastArtURL.length) {
        NSURL *u = [NSURL URLWithString:_lastArtURL];
        if (u) img = [self.imageHolder imageWithURL:u pixels:ceil(32.0 * (self.window.backingScaleFactor ?: 2.0))];
    }
    SPDrawArtworkSemantic(ctx, img, artRect, 4.0, NO, @"music.note", 13.0, 0.0);

    NSString *title = _track.name.length ? _track.name : (_fallbackTitle ?: @"Loading...");
    NSString *artist = _track.artistName ?: @"";
    NSString *dur = _track ? SPFormatDurationMs(_track.durationMs) : @"";

    CGFloat tx = 58.0;
    CGFloat durW = 42.0;
    CGFloat tw = MAX(30.0, b.size.width - tx - durW - 22.0);
    CGFloat ty = floor((b.size.height - 32.0) * 0.5);
    [title drawInRect:NSMakeRect(tx, ty, tw, 16.0)
       withAttributes:SPSemanticTextAttributes(typo->body, SPLabelColor(), NSLineBreakByTruncatingTail, NSTextAlignmentLeft)];
    if (artist.length) {
        [artist drawInRect:NSMakeRect(tx, ty + 17.0, tw, 15.0)
            withAttributes:SPSemanticTextAttributes(typo->callout, SPSecondaryLabelColor(), NSLineBreakByTruncatingTail, NSTextAlignmentLeft)];
    }
    if (dur.length) {
        [dur drawInRect:NSMakeRect(b.size.width - durW - 16.0, floor((b.size.height - 14.0) * 0.5), durW, 15.0)
         withAttributes:SPSemanticTextAttributes(typo->monoTime, SPSecondaryLabelColor(), NSLineBreakByClipping, NSTextAlignmentRight)];
    }
}

@end

@interface SPUpNextListView : SPListView
@property (nonatomic, weak) SPStore *store;
@property (nonatomic, weak, nullable) id<SPNavigator> navigator;
@property (nonatomic, copy) NSArray<SPQueueTrack *> *items;
@end

@implementation SPUpNextListView
- (void)setItems:(NSArray<SPQueueTrack *> *)items {
    _items = [items copy] ?: @[];
    NSMutableArray<NSString *> *keys = [NSMutableArray arrayWithCapacity:_items.count];
    for (NSUInteger i = 0; i < _items.count; i++) {
        [keys addObject:[NSString stringWithFormat:@"%lu:%@", (unsigned long)i, _items[i].uid.length ? _items[i].uid : _items[i].uri]];
    }
    [self showKeys:keys];
}
- (SPListRowView *)makeRow { return [[SPUpNextRowView alloc] initWithFrame:NSZeroRect]; }
- (CGFloat)heightOfIndex:(NSUInteger)index width:(CGFloat)width { (void)index; (void)width; return 44.0; }
- (void)showIndex:(NSUInteger)index inRow:(SPUpNextRowView *)row {
    if (index >= _items.count) return;
    SPQueueTrack *qt = _items[index];
    row.track = qt.trackID.length ? [_store trackWithID:qt.trackID] : nil;
    row.fallbackTitle = row.track ? nil : @"Loading track...";
}
- (void)didSelectIndex:(NSUInteger)index {
    if (index < _items.count) [_navigator skipToQueueIndex:(NSInteger)index];
}
- (void)didActivateIndex:(NSUInteger)index {
    if (index < _items.count) [_navigator skipToQueueIndex:(NSInteger)index];
}
@end

@implementation SPNowPlayingInspectorView {
    SPStore *_store;
    SPUpNextListView *_upNextList;
    NSString *_lastCoverURL;
    NSUInteger _totalNextCount;
}

- (instancetype)initWithFrame:(NSRect)frame store:(SPStore *)store navigator:(id<SPNavigator>)navigator {
    if (!(self = [super initWithFrame:frame])) return nil;
    _store = store;
    _navigator = navigator;

    _upNextList = [[SPUpNextListView alloc] initWithFrame:NSZeroRect];
    _upNextList.store = store;
    _upNextList.navigator = navigator;
    _upNextList.topInset = 4.0;
    _upNextList.bottomInset = 16.0;
    [self addSubview:_upNextList];

    [_store addObserver:self];
    [self reloadInspector];
    return self;
}

- (void)dealloc { [_store removeObserver:self]; }
- (BOOL)isFlipped { return YES; }

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (!self.window) SPReleaseViewImages(self);
}

- (void)reloadInspector {
    SPPlaybackState *pb = _store.playbackState;
    SPTrack *cur = pb.currentTrackID.length ? [_store trackWithID:pb.currentTrackID] : nil;
    NSString *url = cur.artworkURL.length ? cur.artworkURL : cur.artworkSmallURL;
    if (![_lastCoverURL isEqualToString:url ?: @""]) {
        [self.imageHolder removeAllImages];
        _lastCoverURL = [url copy];
    }

    NSMutableArray<SPQueueTrack *> *next = [NSMutableArray new];
    NSUInteger totalNext = 0;
    for (SPQueueTrack *qt in pb.nextTracks) {
        if (qt.isHidden || qt.isDelimiter) continue;
        totalNext++;
        if (next.count < 8) [next addObject:qt];
    }
    _totalNextCount = totalNext;
    _upNextList.items = next;
    _upNextList.hidden = (cur == nil);
    self.needsDisplay = YES;
}

- (void)layout {
    [super layout];
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    CGFloat listY = 448.0;
    _upNextList.frame = NSMakeRect(1.0, listY, MAX(0.0, w - 1.0), MAX(0.0, h - listY));
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    if (!ctx) return;

    const SPTypographyScale *typo = SPThemeTypography();
    CGFloat w = self.bounds.size.width;

    // Opaque native window background + 1pt left divider (matching Spotifly NowPlayingInspector)
    CGContextSetFillColorWithColor(ctx, SPWindowBackgroundColor().CGColor);
    CGContextFillRect(ctx, self.bounds);
    CGContextSetFillColorWithColor(ctx, SPSeparatorColor().CGColor);
    CGContextFillRect(ctx, CGRectMake(0.0, 0.0, 1.0, self.bounds.size.height));

    [@"Now Playing" drawInRect:NSMakeRect(16.0, 16.0, w - 32.0, 20.0)
                withAttributes:SPSemanticTextAttributes(typo->headline, SPLabelColor(), NSLineBreakByClipping, NSTextAlignmentLeft)];

    SPPlaybackState *pb = _store.playbackState;
    SPTrack *cur = pb.currentTrackID.length ? [_store trackWithID:pb.currentTrackID] : nil;
    if (!cur) {
        CGFloat cy = floor(self.bounds.size.height * 0.45);
        SPDrawIconSemantic(SPIconMusicNote, CGRectMake(floor(w * 0.5) - 20.0, cy - 44.0, 40.0, 40.0),
                           34.0, NSFontWeightRegular, SPTertiaryLabelColor());
        [@"Nothing Playing" drawInRect:NSMakeRect(20.0, cy, w - 40.0, 20.0)
                        withAttributes:SPSemanticTextAttributes(typo->headline, SPSecondaryLabelColor(), NSLineBreakByTruncatingTail, NSTextAlignmentCenter)];
        return;
    }

    // 280x280pt rounded (10pt) cover art
    CGFloat artDim = MIN(280.0, MAX(120.0, w - 40.0));
    CGRect artRect = CGRectMake(20.0, 52.0, artDim, artDim);
    CGImageRef img = NULL;
    if (_lastCoverURL.length) {
        NSURL *u = [NSURL URLWithString:_lastCoverURL];
        if (u) img = [self.imageHolder imageWithURL:u pixels:ceil(artDim * (self.window.backingScaleFactor ?: 2.0))];
    }
    SPDrawArtworkSemantic(ctx, img, artRect, 10.0, NO, @"music.note", 52.0, 2.0);

    CGFloat y = CGRectGetMaxY(artRect) + 14.0;
    [cur.name drawInRect:NSMakeRect(20.0, y, w - 40.0, 22.0)
          withAttributes:SPSemanticTextAttributes(typo->title2, SPLabelColor(), NSLineBreakByTruncatingTail, NSTextAlignmentLeft)];
    y += 23.0;
    [cur.artistName drawInRect:NSMakeRect(20.0, y, w - 40.0, 18.0)
                withAttributes:SPSemanticTextAttributes(typo->body, SPSecondaryLabelColor(), NSLineBreakByTruncatingTail, NSTextAlignmentLeft)];
    y += 18.0;
    if (cur.albumName.length) {
        [cur.albumName drawInRect:NSMakeRect(20.0, y, w - 40.0, 16.0)
                   withAttributes:SPSemanticTextAttributes(typo->callout, SPTertiaryLabelColor(), NSLineBreakByTruncatingTail, NSTextAlignmentLeft)];
    }

    // Divider + "Up Next" header
    CGContextSetFillColorWithColor(ctx, SPSeparatorColor().CGColor);
    CGContextFillRect(ctx, CGRectMake(1.0, 412.0, w - 1.0, 1.0));

    [@"Up Next" drawInRect:NSMakeRect(16.0, 424.0, 120.0, 18.0)
            withAttributes:SPSemanticTextAttributes(typo->headline, SPLabelColor(), NSLineBreakByClipping, NSTextAlignmentLeft)];
    NSString *cntStr = (_totalNextCount == 1) ? @"1 song" : [NSString stringWithFormat:@"%lu songs", (unsigned long)_totalNextCount];
    [cntStr drawInRect:NSMakeRect(w - 116.0, 424.0, 100.0, 18.0)
        withAttributes:SPSemanticTextAttributes(typo->callout, SPSecondaryLabelColor(), NSLineBreakByClipping, NSTextAlignmentRight)];
}

- (void)storeChanged:(SPChange *)change {
    if (change.playback || change.tracks.count > 0) [self reloadInspector];
}

@end

#pragma mark - SPQueuePageView (Full Queue Page matching Spotifly QueueListView.swift)

@interface SPQueuePageEntry : NSObject
@property (nonatomic, copy) NSString *key;
@property (nonatomic, strong) SPQueueTrack *queueTrack;
@property (nonatomic, strong, nullable) SPTrack *track;
@property (nonatomic) BOOL isPast;
@property (nonatomic) BOOL isCurrent;
@property (nonatomic) NSInteger nextQueueIndex; // >= 0 for upcoming tracks
@end

@implementation SPQueuePageEntry
@end

@interface SPQueuePageListView : SPListView
@property (nonatomic, weak) SPStore *store;
@property (nonatomic, weak, nullable) id<SPNavigator> navigator;
@property (nonatomic, copy) NSArray<SPQueuePageEntry *> *entries;
@end

@implementation SPQueuePageListView

- (void)setEntries:(NSArray<SPQueuePageEntry *> *)entries {
    _entries = [entries copy] ?: @[];
    NSMutableArray<NSString *> *keys = [NSMutableArray arrayWithCapacity:_entries.count];
    for (SPQueuePageEntry *e in _entries) [keys addObject:e.key];
    [self showKeys:keys];
}

- (SPListRowView *)makeRow {
    SPTrackRowView *row = [[SPTrackRowView alloc] initWithFrame:NSZeroRect];
    __weak typeof(self) weakSelf = self;
    row.onToggleFavorite = ^(SPTrack *track) {
        [weakSelf.navigator toggleFavoriteTrackID:track.trackID];
    };
    return row;
}

- (CGFloat)heightOfIndex:(NSUInteger)index width:(CGFloat)width {
    (void)index; (void)width;
    return SPThemeMetrics()->trackRowHeight;
}

- (void)showIndex:(NSUInteger)index inRow:(SPTrackRowView *)row {
    if (index >= _entries.count) return;
    SPQueuePageEntry *e = _entries[index];
    SPPlaybackState *pb = _store.playbackState;
    row.track = e.track;
    row.displayNumber = index + 1;
    row.showArtwork = YES;
    row.showAlbumColumn = NO;
    row.isFavorited = e.track ? [_store isFavoriteTrackID:e.track.trackID] : NO;
    row.isPlayingTrack = e.isCurrent;
    row.isAudioPlaying = pb.isPlaying;
    row.isDimmed = e.isPast;

    NSString *prov = e.queueTrack.provider.lowercaseString ?: @"";
    if ([prov isEqualToString:@"queue"]) row.badgeTag = @"Q";
    else if ([prov isEqualToString:@"context"]) row.badgeTag = @"C";
    else if ([prov containsString:@"autoplay"]) row.badgeTag = @"A";
    else row.badgeTag = nil;
}

- (void)didActivateIndex:(NSUInteger)index {
    if (index >= _entries.count) return;
    SPQueuePageEntry *e = _entries[index];
    if (e.nextQueueIndex >= 0) {
        [_navigator skipToQueueIndex:e.nextQueueIndex];
    } else if (e.track && !e.isCurrent) {
        [_navigator playTrackWithRadio:e.track fallbackURIs:nil];
    }
}

@end

@implementation SPQueuePageView {
    SPStore *_store;
    SPQueuePageListView *_list;
    NSUInteger _currentRowIndex;
    NSUInteger _totalCount;
    NSUInteger _upcomingCount;
}

- (instancetype)initWithFrame:(NSRect)frame store:(SPStore *)store navigator:(id<SPNavigator>)navigator {
    if (!(self = [super initWithFrame:frame])) return nil;
    _store = store;
    _navigator = navigator;
    _currentRowIndex = NSNotFound;

    _list = [[SPQueuePageListView alloc] initWithFrame:NSZeroRect];
    _list.store = store;
    _list.navigator = navigator;
    _list.topInset = 2.0;
    _list.bottomInset = SPThemeMetrics()->nowPlayingContentClearance;
    [self addSubview:_list];

    [_store addObserver:self];
    [self reloadQueue];
    return self;
}

- (void)dealloc { [_store removeObserver:self]; }
- (BOOL)isFlipped { return YES; }

- (void)scrollToCurrentTrack {
    if (_currentRowIndex != NSNotFound) {
        [_list revealIndex:_currentRowIndex];
    }
}

- (void)reloadQueue {
    SPPlaybackState *pb = _store.playbackState;
    NSMutableArray<SPQueuePageEntry *> *rows = [NSMutableArray new];
    _currentRowIndex = NSNotFound;
    _upcomingCount = 0;

    for (NSUInteger i = 0; i < pb.prevTracks.count; i++) {
        SPQueueTrack *qt = pb.prevTracks[i];
        if (qt.isHidden || qt.isDelimiter) continue;
        SPTrack *t = qt.trackID.length ? [_store trackWithID:qt.trackID] : nil;
        if (!t) continue;
        SPQueuePageEntry *e = [SPQueuePageEntry new];
        e.key = [NSString stringWithFormat:@"p:%lu:%@", (unsigned long)i, qt.uid ?: qt.uri];
        e.queueTrack = qt;
        e.track = t;
        e.isPast = YES;
        e.nextQueueIndex = -1;
        [rows addObject:e];
    }

    if (pb.currentTrackID.length) {
        SPTrack *cur = [_store trackWithID:pb.currentTrackID];
        if (cur) {
            SPQueuePageEntry *e = [SPQueuePageEntry new];
            e.key = [NSString stringWithFormat:@"cur:%@", pb.currentTrackURI ?: cur.trackID];
            e.queueTrack = [[SPQueueTrack alloc] initWithURI:pb.currentTrackURI ?: cur.uri uid:@"current" provider:@"context" isHidden:NO];
            e.track = cur;
            e.isCurrent = YES;
            e.nextQueueIndex = -1;
            _currentRowIndex = rows.count;
            [rows addObject:e];
        }
    }

    NSInteger nextIdx = 0;
    for (NSUInteger i = 0; i < pb.nextTracks.count; i++) {
        SPQueueTrack *qt = pb.nextTracks[i];
        if (qt.isHidden || qt.isDelimiter) continue;
        _upcomingCount++;
        SPTrack *t = qt.trackID.length ? [_store trackWithID:qt.trackID] : nil;
        if (t) {
            SPQueuePageEntry *e = [SPQueuePageEntry new];
            e.key = [NSString stringWithFormat:@"n:%lu:%@", (unsigned long)i, qt.uid ?: qt.uri];
            e.queueTrack = qt;
            e.track = t;
            e.nextQueueIndex = nextIdx;
            [rows addObject:e];
        }
        nextIdx++;
    }

    _totalCount = rows.count;
    _list.entries = rows;
    _list.hidden = (rows.count == 0);
    self.needsDisplay = YES;
}

- (void)layout {
    [super layout];
    CGFloat headerH = 96.0;
    _list.frame = NSMakeRect(0.0, headerH, self.bounds.size.width, MAX(0.0, self.bounds.size.height - headerH));
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    if (!ctx) return;

    const SPTypographyScale *typo = SPThemeTypography();
    CGFloat padX = SPThemeMetrics()->pageInset;
    CGFloat w = self.bounds.size.width;

    [@"Queue" drawInRect:NSMakeRect(padX, 10.0, w - padX * 2.0, 36.0)
          withAttributes:SPSemanticTextAttributes(typo->display, SPLabelColor(), NSLineBreakByTruncatingTail, NSTextAlignmentLeft)];

    if (_totalCount > 0) {
        NSString *meta = [NSString stringWithFormat:@"%lu songs · %lu up next",
                          (unsigned long)_totalCount, (unsigned long)_upcomingCount];
        [meta drawInRect:NSMakeRect(padX, 48.0, w - padX * 2.0, 18.0)
          withAttributes:SPSemanticTextAttributes(typo->body, SPSecondaryLabelColor(), NSLineBreakByTruncatingTail, NSTextAlignmentLeft)];
    }

    SPDevice *active = nil;
    for (SPDevice *d in _store.devices) { if (d.isActive) { active = d; break; } }
    if (active) {
        NSString *ctxName = _store.playbackState.contextName;
        NSString *line = ctxName.length
            ? [NSString stringWithFormat:@"Playing from %@ on %@", ctxName, active.name]
            : [NSString stringWithFormat:@"Playing on %@", active.name];
        SPDrawSFSymbol(SPDeviceSymbolForType(active.deviceType), CGRectMake(padX, 68.0, 15.0, 15.0),
                       12.5, NSFontWeightRegular, SPSecondaryLabelColor());
        [line drawInRect:NSMakeRect(padX + 20.0, 68.0, w - padX * 2.0 - 20.0, 18.0)
          withAttributes:SPSemanticTextAttributes(typo->callout, SPSecondaryLabelColor(), NSLineBreakByTruncatingTail, NSTextAlignmentLeft)];
    }

    CGContextSetFillColorWithColor(ctx, SPSeparatorColor().CGColor);
    CGContextFillRect(ctx, CGRectMake(0.0, 95.0, w, 1.0));

    if (_totalCount == 0) {
        CGFloat cy = MAX(180.0, floor(self.bounds.size.height * 0.45));
        SPDrawSFSymbol(@"list.bullet", CGRectMake(floor(w * 0.5) - 22.0, cy - 50.0, 44.0, 44.0),
                       34.0, NSFontWeightRegular, SPSecondaryLabelColor());
        [@"Queue is Empty" drawInRect:NSMakeRect(24.0, cy, w - 48.0, 22.0)
                       withAttributes:SPSemanticTextAttributes(typo->title2, SPLabelColor(), NSLineBreakByTruncatingTail, NSTextAlignmentCenter)];
        [@"Play a song, album, or playlist to fill your queue."
            drawInRect:NSMakeRect(24.0, cy + 26.0, w - 48.0, 20.0)
        withAttributes:SPSemanticTextAttributes(typo->body, SPSecondaryLabelColor(), NSLineBreakByWordWrapping, NSTextAlignmentCenter)];
    }
}

- (void)storeChanged:(SPChange *)change {
    if (change.playback || change.tracks.count > 0 || change.devices || change.favorites.count > 0) {
        [self reloadQueue];
    }
}

@end

#pragma mark - SPSpeakersPageView (Full Playing On Page matching Spotifly SpeakersView.swift)

@interface SPSpeakerRowItemView : NSView
@property (nonatomic, strong) SPDevice *device;
@property (nonatomic) NSInteger volumePercent;
@property (nonatomic) BOOL showBottomDivider;
@property (nonatomic, copy, nullable) void (^onSelect)(SPDevice *d);
@property (nonatomic, copy, nullable) void (^onPreviewVolume)(NSInteger pct);
@property (nonatomic, copy, nullable) void (^onCommitVolume)(NSInteger pct);
@end

@implementation SPSpeakerRowItemView {
    SPSlider *_volSlider;
    NSTrackingArea *_tracking;
    BOOL _hovered;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _volSlider = [[SPSlider alloc] initWithFrame:NSZeroRect];
    _volSlider.minValue = 0.0;
    _volSlider.maxValue = 100.0;
    _volSlider.accentFill = YES;
    _volSlider.alwaysShowKnob = YES;
    __weak typeof(self) weakSelf = self;
    _volSlider.onChange = ^(double v) {
        SPSpeakerRowItemView *s = weakSelf;
        if (!s) return;
        s->_volumePercent = (NSInteger)llround(v);
        s.needsDisplay = YES;
        if (s.onPreviewVolume) s.onPreviewVolume(s->_volumePercent);
    };
    _volSlider.onCommit = ^(double v) {
        SPSpeakerRowItemView *s = weakSelf;
        if (!s) return;
        s->_volumePercent = (NSInteger)llround(v);
        s.needsDisplay = YES;
        if (s.onCommitVolume) s.onCommitVolume(s->_volumePercent);
    };
    [self addSubview:_volSlider];
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)setDevice:(SPDevice *)device {
    _device = device;
    _volSlider.hidden = !device.isActive;
    _volSlider.enabled = !device.disableVolume;
    self.needsLayout = YES;
    self.needsDisplay = YES;
}

- (void)setVolumePercent:(NSInteger)volumePercent {
    _volumePercent = MIN(100, MAX(0, volumePercent));
    if (!_volSlider.isDragging) _volSlider.doubleValue = (double)_volumePercent;
    self.needsDisplay = YES;
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_tracking) [self removeTrackingArea:_tracking];
    _tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect
                                             options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
                                               owner:self
                                            userInfo:nil];
    [self addTrackingArea:_tracking];
}

- (void)mouseEntered:(NSEvent *)event { (void)event; _hovered = YES; self.needsDisplay = YES; }
- (void)mouseExited:(NSEvent *)event { (void)event; _hovered = NO; self.needsDisplay = YES; }

- (void)mouseDown:(NSEvent *)event {
    NSPoint pt = [self convertPoint:event.locationInWindow fromView:nil];
    if (pt.y <= 48.0 && _device && _onSelect) {
        _onSelect(_device);
        return;
    }
    [super mouseDown:event];
}

- (void)layout {
    [super layout];
    if (!_volSlider.hidden) {
        _volSlider.frame = NSMakeRect(76.0, 50.0, MAX(80.0, self.bounds.size.width - 132.0), 18.0);
    }
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    if (!_device) return;
    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    if (!ctx) return;

    const SPTypographyScale *typo = SPThemeTypography();
    CGFloat w = self.bounds.size.width;

    if (_hovered) {
        CGContextSetFillColorWithColor(ctx, SPHoverFillColor().CGColor);
        CGContextFillRect(ctx, NSMakeRect(0.0, 0.0, w, 48.0));
    }

    // 28x28pt rounded (7pt) icon tile: green accent when active, quaternary fill when inactive (Spotifly SpeakerRow)
    CGRect tile = CGRectMake(14.0, 10.0, 28.0, 28.0);
    CGPathRef tp = CGPathCreateWithRoundedRect(tile, 7.0, 7.0, NULL);
    CGContextSetFillColorWithColor(ctx, (_device.isActive ? SPAccentColor() : SPQuaternaryFillColor()).CGColor);
    CGContextAddPath(ctx, tp);
    CGContextFillPath(ctx);
    CGPathRelease(tp);

    SPDrawSFSymbol(SPDeviceSymbolForType(_device.deviceType), tile, 14.0, NSFontWeightRegular,
                   _device.isActive ? NSColor.whiteColor : SPLabelColor());

    [_device.name drawInRect:NSMakeRect(54.0, 8.0, MAX(40.0, w - 92.0), 18.0)
              withAttributes:SPSemanticTextAttributes(typo->body, SPLabelColor(), NSLineBreakByTruncatingTail, NSTextAlignmentLeft)];

    NSString *typeStr = SPDeviceLabelForType(_device.deviceType);
    NSString *sub = _device.isActive ? [NSString stringWithFormat:@"%@ · Active", typeStr] : typeStr;
    [sub drawInRect:NSMakeRect(54.0, 26.0, MAX(40.0, w - 92.0), 15.0)
     withAttributes:SPSemanticTextAttributes(typo->caption, SPSecondaryLabelColor(), NSLineBreakByTruncatingTail, NSTextAlignmentLeft)];

    if (_device.isActive) {
        SPDrawIconSemantic(SPIconCheck, CGRectMake(w - 30.0, 16.0, 16.0, 16.0), 13.0, NSFontWeightSemibold, SPAccentColor());
        // Volume icon + percent around green slider
        SPDrawIconSemantic(SPIconSpeakerMed, CGRectMake(54.0, 52.0, 16.0, 14.0), 11.5, NSFontWeightRegular, SPSecondaryLabelColor());
        NSString *pct = [NSString stringWithFormat:@"%ld%%", (long)_volumePercent];
        [pct drawInRect:NSMakeRect(w - 50.0, 52.0, 36.0, 14.0)
         withAttributes:SPSemanticTextAttributes(typo->monoTime, SPSecondaryLabelColor(), NSLineBreakByClipping, NSTextAlignmentRight)];
    }

    if (_showBottomDivider) {
        CGContextSetFillColorWithColor(ctx, SPSeparatorColor().CGColor);
        CGContextFillRect(ctx, CGRectMake(14.0, self.bounds.size.height - 1.0, MAX(0.0, w - 28.0), 1.0));
    }
}

@end

@interface SPSpeakersDocView : NSView
@property (nonatomic) NSRect devicesCardRect;
@property (nonatomic) NSRect connectionCardRect;
@property (nonatomic) BOOL isEmpty;
@property (nonatomic) BOOL isConnected;
@property (nonatomic, copy, nullable) NSString *activeDeviceID;
@end

@implementation SPSpeakersDocView

- (BOOL)isFlipped { return YES; }

- (void)drawCard:(CGContextRef)ctx rect:(CGRect)r {
    CGPathRef p = CGPathCreateWithRoundedRect(r, 10.0, 10.0, NULL);
    CGContextSetFillColorWithColor(ctx, SPCardSurfaceColor().CGColor);
    CGContextAddPath(ctx, p);
    CGContextFillPath(ctx);
    CGContextSetStrokeColorWithColor(ctx, SPSeparatorColor().CGColor);
    CGContextSetLineWidth(ctx, 1.0);
    CGContextAddPath(ctx, p);
    CGContextStrokePath(ctx);
    CGPathRelease(p);
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    if (!ctx) return;

    const SPTypographyScale *typo = SPThemeTypography();
    SPTextStyle secStyle = {12.0, NSFontWeightSemibold, 16.0, 0.0, NO};

    [@"Spotify Connect" drawInRect:NSMakeRect(_devicesCardRect.origin.x + 12.0, _devicesCardRect.origin.y - 22.0, 220.0, 16.0)
                    withAttributes:SPSemanticTextAttributes(secStyle, SPSecondaryLabelColor(), NSLineBreakByClipping, NSTextAlignmentLeft)];
    [self drawCard:ctx rect:_devicesCardRect];

    if (_isEmpty) {
        CGFloat cx = CGRectGetMidX(_devicesCardRect);
        CGFloat cy = CGRectGetMidY(_devicesCardRect);
        SPDrawSFSymbol(@"hifispeaker.slash", CGRectMake(cx - 18.0, cy - 32.0, 36.0, 36.0), 26.0, NSFontWeightRegular, SPSecondaryLabelColor());
        [@"No Devices Available" drawInRect:NSMakeRect(_devicesCardRect.origin.x + 16.0, cy + 8.0, _devicesCardRect.size.width - 32.0, 18.0)
                             withAttributes:SPSemanticTextAttributes(typo->headline, SPLabelColor(), NSLineBreakByTruncatingTail, NSTextAlignmentCenter)];
    }

    [@"Select a device to transfer playback. Playback continues seamlessly across Spotify Connect devices."
        drawInRect:NSMakeRect(_devicesCardRect.origin.x + 12.0, NSMaxY(_devicesCardRect) + 8.0, _devicesCardRect.size.width - 24.0, 28.0)
    withAttributes:SPSemanticTextAttributes(typo->caption, SPSecondaryLabelColor(), NSLineBreakByWordWrapping, NSTextAlignmentLeft)];

    [@"Spotify Connection" drawInRect:NSMakeRect(_connectionCardRect.origin.x + 12.0, _connectionCardRect.origin.y - 22.0, 220.0, 16.0)
                       withAttributes:SPSemanticTextAttributes(secStyle, SPSecondaryLabelColor(), NSLineBreakByClipping, NSTextAlignmentLeft)];
    [self drawCard:ctx rect:_connectionCardRect];

    NSDictionary *lbl = SPSemanticTextAttributes(typo->body, SPLabelColor(), NSLineBreakByClipping, NSTextAlignmentLeft);
    NSDictionary *val = SPSemanticTextAttributes(typo->body, _isConnected ? SPAccentColor() : SPSecondaryLabelColor(), NSLineBreakByTruncatingTail, NSTextAlignmentRight);
    [@"Status" drawInRect:NSMakeRect(_connectionCardRect.origin.x + 14.0, _connectionCardRect.origin.y + 12.0, 140.0, 18.0) withAttributes:lbl];
    [(_isConnected ? @"Connected" : @"Standby") drawInRect:NSMakeRect(_connectionCardRect.origin.x + 160.0, _connectionCardRect.origin.y + 12.0, _connectionCardRect.size.width - 174.0, 18.0)
                                            withAttributes:val];

    CGContextSetFillColorWithColor(ctx, SPSeparatorColor().CGColor);
    CGContextFillRect(ctx, CGRectMake(_connectionCardRect.origin.x + 14.0, _connectionCardRect.origin.y + 42.0, _connectionCardRect.size.width - 28.0, 1.0));
    [@"Connection" drawInRect:NSMakeRect(_connectionCardRect.origin.x + 14.0, _connectionCardRect.origin.y + 54.0, 160.0, 18.0) withAttributes:lbl];
}

@end

@implementation SPSpeakersPageView {
    SPStore *_store;
    NSScrollView *_scroll;
    SPSpeakersDocView *_doc;
    NSMutableArray<SPSpeakerRowItemView *> *_deviceRows;
    SPButton *_reconnectBtn;
}

- (instancetype)initWithFrame:(NSRect)frame store:(SPStore *)store navigator:(id<SPNavigator>)navigator {
    if (!(self = [super initWithFrame:frame])) return nil;
    _store = store;
    _navigator = navigator;
    _volumePercent = 80;
    _deviceRows = [NSMutableArray new];

    _scroll = [[NSScrollView alloc] initWithFrame:self.bounds];
    _scroll.drawsBackground = NO;
    _scroll.hasVerticalScroller = YES;
    _scroll.scrollerStyle = NSScrollerStyleOverlay;
    _scroll.autohidesScrollers = YES;

    _doc = [[SPSpeakersDocView alloc] initWithFrame:self.bounds];
    _scroll.documentView = _doc;
    [self addSubview:_scroll];

    _reconnectBtn = [SPButton pillButtonWithTitle:@"Reconnect" style:SPButtonStyleSecondary frame:NSZeroRect];
    __weak typeof(self) weakSelf = self;
    _reconnectBtn.onClick = ^{ [weakSelf.navigator reconnectSpotify]; };
    [_doc addSubview:_reconnectBtn];

    [_store addObserver:self];
    [self reloadDevices];
    return self;
}

- (void)dealloc { [_store removeObserver:self]; }
- (BOOL)isFlipped { return YES; }

- (void)setVolumePercent:(NSInteger)volumePercent {
    _volumePercent = MIN(100, MAX(0, volumePercent));
    for (SPSpeakerRowItemView *row in _deviceRows) {
        if (row.device.isActive) row.volumePercent = _volumePercent;
    }
}

- (void)reloadDevices {
    for (SPSpeakerRowItemView *r in _deviceRows) [r removeFromSuperview];
    [_deviceRows removeAllObjects];

    NSArray<SPDevice *> *devices = _store.devices;
    _doc.isEmpty = (devices.count == 0);
    _doc.isConnected = _store.isConnected;
    _doc.activeDeviceID = _store.activeDeviceID;

    __weak typeof(self) weakSelf = self;
    for (NSUInteger i = 0; i < devices.count; i++) {
        SPDevice *d = devices[i];
        SPSpeakerRowItemView *row = [[SPSpeakerRowItemView alloc] initWithFrame:NSZeroRect];
        row.device = d;
        row.volumePercent = d.isActive ? _volumePercent : d.volumePercent;
        row.showBottomDivider = (i + 1 < devices.count);
        row.onSelect = ^(SPDevice *dev) {
            [weakSelf.navigator transferPlaybackToDeviceID:dev.deviceID];
        };
        row.onPreviewVolume = ^(NSInteger pct) {
            [weakSelf.navigator previewVolumePercent:pct];
        };
        row.onCommitVolume = ^(NSInteger pct) {
            [weakSelf.navigator setVolumePercent:pct];
        };
        [_doc addSubview:row];
        [_deviceRows addObject:row];
    }
    [self layoutDocument];
    _doc.needsDisplay = YES;
}

- (void)layoutDocument {
    CGFloat w = MAX(320.0, self.bounds.size.width);
    CGFloat cw = MIN(600.0, MAX(280.0, w - 56.0));
    CGFloat cx = floor((w - cw) * 0.5);

    CGFloat devY = 44.0;
    CGFloat devH = 0.0;
    if (_deviceRows.count == 0) {
        devH = 110.0;
    } else {
        CGFloat ry = devY;
        for (SPSpeakerRowItemView *row in _deviceRows) {
            CGFloat rh = row.device.isActive ? 78.0 : 48.0;
            row.frame = NSMakeRect(cx, ry, cw, rh);
            ry += rh;
        }
        devH = ry - devY;
    }
    _doc.devicesCardRect = NSMakeRect(cx, devY, cw, devH);

    CGFloat connY = devY + devH + 64.0;
    _doc.connectionCardRect = NSMakeRect(cx, connY, cw, 84.0);
    _reconnectBtn.frame = NSMakeRect(cx + cw - 108.0, connY + 49.0, 94.0, 28.0);

    CGFloat totalH = MAX(self.bounds.size.height, connY + 110.0 + SPThemeMetrics()->nowPlayingContentClearance);
    _doc.frame = NSMakeRect(0.0, 0.0, w, totalH);
}

- (void)layout {
    [super layout];
    _scroll.frame = self.bounds;
    [self layoutDocument];
}

- (void)storeChanged:(SPChange *)change {
    if (change.devices || change.connection) [self reloadDevices];
}

@end

#pragma mark - Legacy SPQueueDrawerView & SPSpeakersPopover (compatibility)

@implementation SPQueueDrawerView {
    SPNowPlayingInspectorView *_inspector;
}
- (instancetype)initWithFrame:(NSRect)frame store:(SPStore *)store navigator:(id<SPNavigator>)navigator {
    if (!(self = [super initWithFrame:frame])) return nil;
    _navigator = navigator;
    _inspector = [[SPNowPlayingInspectorView alloc] initWithFrame:self.bounds store:store navigator:navigator];
    [self addSubview:_inspector];
    return self;
}
- (BOOL)isFlipped { return YES; }
- (void)layout { [super layout]; _inspector.frame = self.bounds; }
- (void)reloadQueue { [_inspector reloadInspector]; }
- (void)storeChanged:(SPChange *)change { (void)change; [_inspector reloadInspector]; }
@end

@implementation SPSpeakersPopover {
    SPStore *_store;
    __weak id<SPNavigator> _navigator;
    NSPopover *_popover;
}
- (instancetype)initWithStore:(SPStore *)store navigator:(id<SPNavigator>)navigator {
    if (!(self = [super init])) return nil;
    _store = store;
    _navigator = navigator;
    return self;
}
- (BOOL)isShown { return _popover.isShown; }
- (void)toggleFromView:(NSView *)anchorView {
    (void)anchorView;
    [_navigator openSpeakers];
}
- (void)close {
    [_popover close];
    _popover = nil;
}
@end
