// Owns the video and audio players' views and their lifecycle.
#import <AVFoundation/AVFoundation.h>
#import <dlfcn.h>

#import "render/format.h"
#import "render/icon.h"
#import "render/images.h"
#import "render/strings.h"
#import "ui/files/filenet.h"
#import "ui/files/mediaview.h"
#import "ui/kit/button.h"
#import "ui/kit/label.h"
#import "ui/kit/popover.h"

@interface SNFileView (Actions)
- (void)showMoreFrom:(NSView *)button;
@end

/// Slack's playback speeds, offered in the speed menu.
static NSArray<NSNumber *> *Speeds(void) { return @[ @0.25, @0.5, @0.75, @1, @1.25, @1.5, @1.75, @2 ]; }

static NSString *SpeedLabel(float rate) { return [NSString stringWithFormat:@"%@x", @(rate)]; }

static CGFloat TextWidth(NSString *text, NSFont *font) { return ceil(SNTextWidth(text, font)); }

#pragma mark - Player lifecycle

@implementation SNMediaFileView {
    float _rate;
    BOOL _muted;
}

- (instancetype)initWithFile:(SNFile *)file style:(SNFileStyle)style context:(NSString *)context {
    if (!(self = [super initWithFile:file style:style context:context])) return nil;
    _rate = 1;
    return self;
}

- (float)rate { return _rate; }
- (BOOL)muted { return _media ? _media.muted : _muted; }

- (void)setRate:(float)rate {
    _rate = rate;
    _media.rate = rate;
    [self playbackChanged];
}

- (void)toggleMute {
    _muted = !self.muted;
    _media.muted = _muted;
    [self playbackChanged];
}

- (void)togglePlayback {
    if (!_media) {
        _media = [SNMediaPlayer playerForFile:self.file];
        if (!_media) return;
        _media.muted = _muted;
        _media.rate = _rate;
        __weak SNMediaFileView *weakSelf = self;
        _media.onChange = ^(SNMediaPlayer *player) { [weakSelf playbackChanged]; };
        // It resumes where the reader stopped last time (media_progress).
        if (self.file.playbackOffset > 0) [_media seekToTime:self.file.playbackOffset];
        [self attachPlayer];
    }
    if (_media.playing) [_media pause];
    else [_media play];
}

/// What the reader has heard or seen so far: the player's time, else where they stopped before.
- (NSTimeInterval)elapsed { return _media ? _media.currentTime : self.file.playbackOffset; }
- (NSTimeInterval)length { return _media ? _media.duration : self.file.duration; }
- (BOOL)isPlaying { return _media.playing; }

/// Videos show their picture here; audio has none.
- (void)attachPlayer {}
- (void)detachPlayer {}

- (void)playbackChanged { self.needsDisplay = YES; }

- (void)releasePlayer {
    if (!_media) return;
    [_media pause];
    _media.onChange = nil;
    _media = nil;
    [self detachPlayer];
    [self playbackChanged];
}

// Off screen nothing plays: the list hides the rows it recycles and removes the views of
// messages it no longer shows.
- (void)viewDidHide {
    [super viewDidHide];
    [self releasePlayer];
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (!self.window) [self releasePlayer];
}

- (void)removeFromSuperview {
    [self releasePlayer];
    [super removeFromSuperview];
}

- (void)mouseUp:(NSEvent *)event {
    BOOL clicked = self.pressed;
    self.pressed = NO;
    if (clicked) [self clickAt:[self convertPoint:event.locationInWindow fromView:nil]];
}

- (void)clickAt:(NSPoint)point { [self togglePlayback]; }

- (void)showSpeedsFrom:(NSRect)rect {
    __weak SNMediaFileView *weakSelf = self;
    NSMutableArray<SNMenuItem *> *items = [NSMutableArray new];
    for (NSNumber *speed in Speeds()) {
        SNMenuItem *item = [SNMenuItem itemWithTitle:SpeedLabel(speed.floatValue) action:^{ [weakSelf setRate:speed.floatValue]; }];
        item.checked = speed.floatValue == _rate;
        [items addObject:item];
    }
    [[[SNMenu alloc] initWithItems:items width:160] showForRect:rect inView:self placement:SNPlacementAbove];
}

@end

#pragma mark - Video

/// getDimensions: no side under 108; at most the column (716 pt wide at most), at most a height
/// cap by breakpoint (large from 636 pt, medium from 472, small from 448, else tiny) and
/// orientation (landscape, portrait, square).
static const CGFloat kVideoMinSide = 108, kVideoGalleryMax = 716;
static const CGFloat kVideoCaps[4][3] = {{235, 354, 314}, {154, 276, 206}, {115, 206, 206}, {115, 206, 154}};

static NSSize VideoSize(SNFile *file, CGFloat column) {
    CGFloat gallery = MIN(column, kVideoGalleryMax);
    CGSize size = file.videoThumbnailSize;
    if (size.width <= 0 || size.height <= 0) size = file.originalSize;
    if (size.width <= 0 || size.height <= 0) size = CGSizeMake(kVideoMinSide, kVideoMinSide);
    int breakpoint = gallery >= 636 ? 0 : gallery >= 472 ? 1 : gallery >= 448 ? 2 : 3;
    int orientation = size.width > size.height ? 0 : size.width < size.height ? 1 : 2;
    CGFloat ratio = size.width / size.height;
    CGFloat width = MAX(MIN(size.width, gallery), kVideoMinSide);
    CGFloat height = MAX(floor(MIN(MIN(width / ratio, kVideoCaps[breakpoint][orientation]), size.height)), kVideoMinSide);
    width = MAX(MIN(floor(height * ratio), width), kVideoMinSide);
    return NSMakeSize(width, height);
}

/// The controls (.p-video_controls_overlay, design polish): a container 8 pt in from the bottom
/// with 4 pt padding, #1d1c1d at 70% while hovered, holding the scrubber row (hover only) and the
/// controls row: the pill (play/pause and time; #1d1c1d at 80% at rest, clear while hovered,
/// hidden while playing unhovered), mute, then speed and captions at the right.
static const CGFloat kControlsInset = 8, kControlsPadding = 4, kControlsRow = 32, kScrubberRow = 20, kVideoPill = 28, kVideoButton = 32;
static const CGFloat kCornerButton = 28, kCornerInset = 8;
static const SNColorToken kControlsFill = 0x1d1c1db3, kVideoPillFill = 0x1d1c1dcc, kCornerFill = 0x1d1c1dd9, kVideoTrack = 0xffffff80;
static const SNColorToken kDisabledControl = 0xffffff80;

@interface SNVideoFileView : SNMediaFileView
- (void)drawControls;
@end

/// Draws the controls above the playing picture; clicks go to the video view under it.
@interface SNVideoControls : NSView
@property (nonatomic, weak) SNVideoFileView *video;
@end

@implementation SNVideoControls

- (BOOL)isFlipped { return YES; }
- (NSView *)hitTest:(NSPoint)point { return nil; }
- (void)drawRect:(NSRect)dirtyRect { [self.video drawControls]; }

@end

@implementation SNVideoFileView {
    AVPlayerLayer *_playerLayer;
    SNVideoControls *_controls;
    SNButton *_more;
}

- (instancetype)initWithFile:(SNFile *)file style:(SNFileStyle)style context:(NSString *)context {
    if (!(self = [super initWithFile:file style:style context:context])) return nil;
    _controls = [[SNVideoControls alloc] initWithFrame:NSZeroRect];
    _controls.video = self;
    _controls.wantsLayer = YES;
    _controls.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;
    [self addSubview:_controls];
    // The corner's More actions: 28 pt, #1d1c1d at 85% with an otl-inv-ter border, radius 4.
    _more = [SNButton iconButtonNamed:@"ellipsis-vertical-filled" size:kCornerButton iconSize:16];
    _more.fillColor = kCornerFill;
    _more.hoverFillColor = SNColorBaseInvPry;
    _more.borderColor = SNColorOtlInvTer;
    _more.cornerRadius = SNRadiusBase;
    _more.contentColor = SNColorContentInvSec;
    _more.hoverContentColor = _more.pressedContentColor = SNColorContentInvPry;
    _more.tooltip = SNLocalized(@"channel.file.more");
    __weak SNVideoFileView *weakSelf = self;
    _more.action = ^(SNButton *button) { [weakSelf showMoreFrom:button]; };
    _more.alphaValue = 0;
    [self addSubview:_more];
    return self;
}

- (NSArray<NSView *> *)actionButtons { return @[ _more ]; }

- (void)layout {
    [super layout];
    NSRect bounds = self.bounds;
    _controls.frame = bounds;
    _playerLayer.frame = bounds;
    _more.frame = self.cornerFrame;
}

/// The corner slides 8 pt down into place as it fades in.
- (NSRect)cornerFrame {
    return NSMakeRect(NSMaxX(self.bounds) - kCornerInset - kCornerButton, self.hovered ? kCornerInset : 0, kCornerButton, kCornerButton);
}

- (void)stateDidChange {
    [super stateDidChange];
    _more.alphaValue = self.hovered;
    _more.frame = self.cornerFrame;
    _controls.needsDisplay = YES;
}

- (void)attachPlayer {
    void *av = SNLoadAVFoundation();
    Class layerClass = av ? NSClassFromString(@"AVPlayerLayer") : Nil;
    if (!layerClass) return;
    _playerLayer = [layerClass playerLayerWithPlayer:self.media.player];
    CFStringRef const *gravity = (CFStringRef const *)dlsym(av, "AVLayerVideoGravityResizeAspect");
    if (gravity && *gravity) _playerLayer.videoGravity = (__bridge NSString *)*gravity;
    _playerLayer.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
    _playerLayer.cornerRadius = SNRadiusLarge;
    _playerLayer.masksToBounds = YES;
    _playerLayer.frame = self.bounds;
    // Under the controls and the corner button, over the poster.
    [self.layer insertSublayer:_playerLayer atIndex:0];
}

- (void)detachPlayer {
    [_playerLayer removeFromSuperlayer];
    _playerLayer.player = nil;
    _playerLayer = nil;
}

- (void)playbackChanged {
    [super playbackChanged];
    _controls.needsDisplay = YES;
}

#pragma mark Geometry

- (BOOL)showsControls { return self.hovered; }

- (NSRect)containerRect {
    NSRect bounds = self.bounds;
    CGFloat height = 2 * kControlsPadding + kControlsRow + (self.showsControls ? kScrubberRow : 0);
    return NSMakeRect(kControlsInset, NSMaxY(bounds) - kControlsInset - height, bounds.size.width - 2 * kControlsInset, height);
}

- (CGFloat)rowTop { return NSMaxY(self.containerRect) - kControlsPadding - kControlsRow; }

- (NSString *)timeText {
    // The length at rest, the time played once playing, hovered or played before.
    NSTimeInterval elapsed = self.elapsed;
    if (self.isPlaying || self.hovered || elapsed > 0) return SNFormatDuration(elapsed);
    return self.length > 0 ? SNFormatDuration(self.length) : SNLocalized(@"channel.video.label");
}

- (NSFont *)pillFont { return SNFont(SNFontSizeBase, SNFontWeightBold); }

- (NSRect)pillRect {
    CGFloat width = 6 + 20 + 8 + TextWidth(self.timeText, self.pillFont) + 8;
    return NSMakeRect(NSMinX(self.containerRect) + kControlsPadding, self.rowTop + (kControlsRow - kVideoPill) / 2, width, kVideoPill);
}

/// Narrow videos drop speed and captions (250 pt) and then mute (138 pt), as the client does.
- (NSRect)muteRect {
    if (!self.showsControls || self.containerRect.size.width <= 138) return NSZeroRect;
    return NSMakeRect(NSMaxX(self.pillRect) + 4 + 4, self.rowTop, kVideoButton, kVideoButton);
}

- (NSRect)captionsRect {
    if (!self.showsControls || self.containerRect.size.width <= 250) return NSZeroRect;
    return NSMakeRect(NSMaxX(self.containerRect) - kControlsPadding - 4 - kVideoButton, self.rowTop, kVideoButton, kVideoButton);
}

- (NSRect)speedRect {
    NSRect captions = self.captionsRect;
    if (NSIsEmptyRect(captions)) return NSZeroRect;
    CGFloat width = 8 + TextWidth(SpeedLabel(self.rate), self.pillFont) + 4 + 12 + 8;
    return NSMakeRect(NSMinX(captions) - 4 - 4 - width, self.rowTop, width, kVideoButton);
}

- (NSRect)scrubberRect {
    if (!self.showsControls) return NSZeroRect;
    NSRect container = self.containerRect;
    return NSMakeRect(NSMinX(container) + kControlsPadding + 8, NSMinY(container) + kControlsPadding, container.size.width - 2 * kControlsPadding - 16, kScrubberRow);
}

#pragma mark Clicks

- (void)clickAt:(NSPoint)point {
    NSRect scrubber = self.scrubberRect;
    if (NSPointInRect(point, scrubber)) {
        double fraction = (point.x - NSMinX(scrubber)) / MAX(1, scrubber.size.width);
        if (!self.media) [self togglePlayback];
        [self.media seekToFraction:fraction];
    } else if (NSPointInRect(point, self.muteRect)) {
        [self toggleMute];
    } else if (NSPointInRect(point, self.speedRect)) {
        [self showSpeedsFrom:self.speedRect];
    } else if (!NSPointInRect(point, self.captionsRect)) {
        [self togglePlayback];
    }
}

#pragma mark Drawing

- (void)drawRect:(NSRect)dirtyRect {
    NSRect bounds = self.bounds;
    NSBezierPath *box = [NSBezierPath bezierPathWithRoundedRect:bounds xRadius:SNRadiusLarge yRadius:SNRadiusLarge];
    [SNColor(SNColorBaseTer) setFill];
    [box fill];
    NSURL *url = self.file.videoThumbnailURL;
    if (!url) return;
    CGFloat pixels = MAX(bounds.size.width, bounds.size.height) * (self.window.backingScaleFactor ?: 2);
    CGImageRef poster = [self.imageHolder imageWithURL:url pixels:pixels];
    if (!poster) return;
    // The poster fits inside the box, centred, never enlarged (background-size by the client).
    CGSize size = self.file.videoThumbnailSize;
    if (size.width <= 0 || size.height <= 0) size = CGSizeMake(CGImageGetWidth(poster), CGImageGetHeight(poster));
    CGFloat scale = MIN(1, MIN(bounds.size.width / size.width, bounds.size.height / size.height));
    NSRect picture = NSMakeRect(NSMidX(bounds) - size.width * scale / 2, NSMidY(bounds) - size.height * scale / 2, size.width * scale, size.height * scale);
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    CGContextSaveGState(context);
    [box addClip];
    CGContextTranslateCTM(context, 0, NSMaxY(picture) + NSMinY(picture));
    CGContextScaleCTM(context, 1, -1);
    CGContextDrawImage(context, picture, poster);
    CGContextRestoreGState(context);
}

- (void)drawControls {
    BOOL hovered = self.showsControls;
    if (hovered) {
        [SNColor(kControlsFill) setFill];
        [[NSBezierPath bezierPathWithRoundedRect:self.containerRect xRadius:SNRadiusLarge yRadius:SNRadiusLarge] fill];
        NSRect scrubber = self.scrubberRect;
        NSRect track = NSMakeRect(NSMinX(scrubber), NSMidY(scrubber) - 2, scrubber.size.width, 4);
        [SNColor(kVideoTrack) setFill];
        [[NSBezierPath bezierPathWithRoundedRect:track xRadius:2 yRadius:2] fill];
        double fraction = self.length > 0 ? MIN(1, self.elapsed / self.length) : 0;
        NSRect elapsed = NSMakeRect(NSMinX(track), NSMinY(track), track.size.width * fraction, 4);
        [SNColor(SNLegacyHighlight) setFill];
        [[NSBezierPath bezierPathWithRoundedRect:elapsed xRadius:2 yRadius:2] fill];
        // The knob at half its 8 pt size until the scrubber itself is hovered.
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(NSMaxX(elapsed) - 2, NSMidY(track) - 2, 4, 4)] fill];
    }
    // The pill hides while playing unless the pointer is over the video.
    if (self.isPlaying && !hovered) return;
    NSRect pill = self.pillRect;
    if (!hovered) {
        [SNColor(kVideoPillFill) setFill];
        [[NSBezierPath bezierPathWithRoundedRect:pill xRadius:SNRadiusBase yRadius:SNRadiusBase] fill];
    }
    SNDrawIcon(self.isPlaying ? @"pause" : @"play-filled", 20, 0xffffffff, NSMakeRect(NSMinX(pill) + 6, NSMinY(pill), 20, pill.size.height));
    SNDrawText(self.timeText, self.pillFont, 0xffffffff, pill.size.height, NSTextAlignmentLeft, 1,
               NSMakeRect(NSMinX(pill) + 6 + 20 + 8, NSMinY(pill), pill.size.width - 34, pill.size.height));
    NSRect mute = self.muteRect;
    if (!NSIsEmptyRect(mute)) SNDrawIcon(self.muted ? @"sound-off" : @"sound-up", 20, 0xffffffff, mute);
    NSRect speed = self.speedRect;
    if (!NSIsEmptyRect(speed)) {
        SNDrawText(SpeedLabel(self.rate), self.pillFont, 0xffffffff, kVideoButton, NSTextAlignmentLeft, 1, NSMakeRect(NSMinX(speed) + 8, NSMinY(speed), speed.size.width - 8, kVideoButton));
        SNDrawIcon(@"caret-down-filled", 12, 0xffffffff, NSMakeRect(NSMaxX(speed) - 8 - 12, NSMinY(speed), 12, kVideoButton));
    }
    // Captions come from a transcript Slack makes on request; without one the button is off.
    NSRect captions = self.captionsRect;
    if (!NSIsEmptyRect(captions)) SNDrawIcon(@"closed-caption", 20, kDisabledControl, captions);
}

@end

#pragma mark - Audio

/// The card: the flat player of a clip (34 pt blue play button, waveform, bold time, speed, More)
/// or the card player of an uploaded recording (36 pt pale button beside the name and length,
/// a bar under them).
static const CGFloat kAudioPadding = 13, kClipButton = 34, kCardButton = 36, kWaveHeight = 34, kDot = 3, kAudioMore = 32;
static const CGFloat kAudioCardWidth = 426, kAudioMinWidth = 200, kClipHeight = 60, kUploadHeight = 92, kTranscriptGap = 8, kTranscriptLine = 16.25;
static const SNColorToken kWaveDot = 0xe8e8e84d, kCardButtonFill = 0xe6eff6ff, kCardButtonIcon = 0x1264a3ff, kAudioTrack = 0x35373bff;
static const SNColorToken kAudioMeta = 0xd1d2d3b3, kSpeedColor = 0xe8e8e8b3;

static NSString *TranscriptText(SNFile *file) {
    if (![file.transcriptionStatus isEqualToString:@"complete"] || !file.transcriptionPreview.length) return nil;
    return file.transcriptionHasMore ? [file.transcriptionPreview stringByAppendingString:@"…"] : file.transcriptionPreview;
}

static NSFont *TranscriptFont(void) { return SNFont(SNFontSizeCaption, SNFontWeightRegular); }

@interface SNAudioFileView : SNMediaFileView
@end

@implementation SNAudioFileView {
    SNButton *_more;
    NSArray<NSNumber *> *_bars;
    CGFloat _barsWidth;
}

- (instancetype)initWithFile:(SNFile *)file style:(SNFileStyle)style context:(NSString *)context {
    if (!(self = [super initWithFile:file style:style context:context])) return nil;
    if (self.isClip) {
        _more = [SNButton iconButtonNamed:@"ellipsis-vertical-filled" size:kAudioMore iconSize:18];
        _more.contentColor = SNLegacyForegroundMaxSolid;
        _more.hoverFillColor = 0xe8e8e80a;
        _more.hoverContentColor = _more.pressedContentColor = SNLegacyPrimaryForeground;
        _more.tooltip = SNLocalized(@"channel.file.more");
        __weak SNAudioFileView *weakSelf = self;
        _more.action = ^(SNButton *button) { [weakSelf showMoreFrom:button]; };
        [self addSubview:_more];
    }
    return self;
}

- (BOOL)isClip { return SNFileIsAudioClip(self.file); }

- (void)layout {
    [super layout];
    _more.frame = self.moreRect;
}

#pragma mark Geometry

- (NSRect)playRect {
    CGFloat side = self.isClip ? kClipButton : kCardButton;
    return NSMakeRect(kAudioPadding, kAudioPadding, side, side);
}

/// The card stops at 426 pt; a transcript under it may run to 500.
- (CGFloat)cardWidth { return MIN(self.bounds.size.width, kAudioCardWidth); }
- (NSRect)moreRect { return NSMakeRect(self.cardWidth - kAudioPadding - kAudioMore, kAudioPadding + 1, kAudioMore, kAudioMore); }

- (NSFont *)timeFont { return SNFont(SNFontSizeCaption, self.isClip ? SNFontWeightBold : SNFontWeightRegular); }

- (NSString *)timeText {
    NSTimeInterval elapsed = self.elapsed;
    return SNFormatDuration(self.isPlaying || elapsed > 0 ? elapsed : self.length);
}

- (NSRect)speedRect {
    if (!self.isClip) return NSZeroRect;
    CGFloat width = 8 + TextWidth(SpeedLabel(self.rate), self.timeFont) + 8;
    return NSMakeRect(NSMinX(self.moreRect) - width, kAudioPadding + 3, width, 28);
}

- (NSRect)timeRect {
    // Wide enough for the length, so the bar does not move as the time counts.
    CGFloat width = TextWidth(SNFormatDuration(MAX(self.length, self.elapsed)), self.timeFont) + 2;
    if (self.isClip) return NSMakeRect(NSMinX(self.speedRect) - width, kAudioPadding, width, kWaveHeight);
    return NSMakeRect(self.cardWidth - kAudioPadding - width, NSMaxY(self.playRect) + 12, width, 18);
}

- (NSRect)scrubberRect {
    if (self.isClip) {
        CGFloat x = NSMaxX(self.playRect) + 12;
        return NSMakeRect(x, kAudioPadding, NSMinX(self.timeRect) - 4 - x, kWaveHeight);
    }
    return NSMakeRect(kAudioPadding, NSMaxY(self.playRect) + 12, NSMinX(self.timeRect) - 4 - kAudioPadding, 18);
}

/// The waveform's heights for the scrubber's width: one 3 pt dot every 6 pt, Slack's count.
- (NSArray<NSNumber *> *)barsForWidth:(CGFloat)width {
    if (_bars && _barsWidth == width) return _bars;
    NSArray<NSNumber *> *samples = self.file.waveform;
    NSInteger whole = (NSInteger)width - (NSInteger)width % 3, even = whole % 6 ? whole : whole - 3, count = MAX(0, (even + 3) / 6);
    NSMutableArray *bars = [NSMutableArray new];
    for (NSInteger i = 0; i < count && samples.count; i++) {
        double value;
        if ((NSInteger)samples.count >= count) {
            // Root mean square of the samples that fall in this bar.
            NSUInteger from = (NSUInteger)(i * samples.count / count), to = MAX(from + 1, (NSUInteger)((i + 1) * samples.count / count));
            double sum = 0;
            for (NSUInteger j = from; j < to; j++) sum += samples[j].doubleValue * samples[j].doubleValue;
            value = sqrt(sum / (to - from));
        } else {
            double position = count > 1 ? (double)i * (samples.count - 1) / (count - 1) : 0;
            NSUInteger low = (NSUInteger)floor(position), high = MIN(samples.count - 1, low + 1);
            value = samples[low].doubleValue + (samples[high].doubleValue - samples[low].doubleValue) * (position - low);
        }
        [bars addObject:@(MIN(6 + 34 * value / 100, kWaveHeight))];
    }
    _bars = bars;
    _barsWidth = width;
    return bars;
}

#pragma mark Clicks

- (void)clickAt:(NSPoint)point {
    NSRect scrubber = self.scrubberRect;
    if (NSPointInRect(point, self.playRect)) {
        [self togglePlayback];
    } else if (NSPointInRect(point, scrubber)) {
        if (!self.media) [self togglePlayback];
        [self.media seekToFraction:(point.x - NSMinX(scrubber)) / MAX(1, scrubber.size.width)];
    } else if (NSPointInRect(point, self.speedRect)) {
        [self showSpeedsFrom:self.speedRect];
    }
}

- (NSCursor *)cursorAtPoint:(NSPoint)point {
    for (NSValue *rect in @[ [NSValue valueWithRect:self.playRect], [NSValue valueWithRect:self.scrubberRect], [NSValue valueWithRect:self.speedRect] ])
        if (NSPointInRect(point, rect.rectValue)) return NSCursor.pointingHandCursor;
    return NSCursor.arrowCursor;
}

#pragma mark Drawing

- (void)drawRect:(NSRect)dirtyRect {
    CGFloat cardHeight = self.isClip ? kClipHeight : kUploadHeight;
    NSRect card = NSMakeRect(0, 0, self.cardWidth, cardHeight);
    NSBezierPath *frame = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(card, 0.5, 0.5) xRadius:SNRadiusXlarge - 0.5 yRadius:SNRadiusXlarge - 0.5];
    [SNColor(SNColorBasePry) setFill];
    [frame fill];
    [SNColor(self.hovered ? SNColorOtlSec : SNColorOtlTer) setStroke];
    [frame stroke];

    NSRect play = self.playRect;
    NSString *glyph = self.isPlaying ? @"pause" : @"play-filled";
    [SNColor(self.isClip ? SNLegacyHighlight : kCardButtonFill) setFill];
    [[NSBezierPath bezierPathWithOvalInRect:play] fill];
    SNDrawIcon(glyph, 18, self.isClip ? 0xffffffff : kCardButtonIcon, play);

    double fraction = self.length > 0 ? MIN(1, self.elapsed / self.length) : 0;
    NSRect scrubber = self.scrubberRect;
    if (self.isClip && self.file.waveform.count) {
        // Tracks inset 4 pt left and 8 pt right; the part played in the highlight blue.
        NSRect wave = NSMakeRect(NSMinX(scrubber) + 4, NSMinY(scrubber), MAX(0, scrubber.size.width - 12), kWaveHeight);
        NSArray<NSNumber *> *bars = [self barsForWidth:wave.size.width];
        CGFloat played = NSMinX(wave) + wave.size.width * fraction;
        for (NSUInteger i = 0; i < bars.count; i++) {
            CGFloat x = NSMinX(wave) + i * 2 * kDot, height = bars[i].doubleValue;
            [SNColor(x < played && fraction > 0 ? SNLegacyHighlight : kWaveDot) setFill];
            [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x, NSMidY(wave) - height / 2, kDot, height) xRadius:kDot / 2 yRadius:kDot / 2] fill];
        }
    } else {
        NSRect track = NSMakeRect(NSMinX(scrubber) + 4, NSMidY(scrubber) - 2, MAX(0, scrubber.size.width - 12), 4);
        [SNColor(kAudioTrack) setFill];
        [[NSBezierPath bezierPathWithRoundedRect:track xRadius:2 yRadius:2] fill];
        [SNColor(kCardButtonIcon) setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(NSMinX(track), NSMinY(track), track.size.width * fraction, 4) xRadius:2 yRadius:2] fill];
        [SNColor(self.isPlaying ? kCardButtonIcon : SNLegacyForegroundHighSolid) setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(NSMinX(track) + track.size.width * fraction - 4, NSMidY(track) - 6, 12, 12)] fill];
    }
    NSRect time = self.timeRect;
    SNDrawText(self.timeText, self.timeFont, self.isClip ? SNLegacyPrimaryForeground : kAudioMeta, time.size.height, NSTextAlignmentRight, 1, time);

    if (self.isClip) {
        NSRect speed = self.speedRect;
        SNDrawText(SpeedLabel(self.rate), self.timeFont, kSpeedColor, speed.size.height, NSTextAlignmentCenter, 1, speed);
        NSString *transcript = TranscriptText(self.file);
        if (transcript)
            SNDrawText(transcript, TranscriptFont(), kSpeedColor, kTranscriptLine, NSTextAlignmentLeft, 0,
                       NSMakeRect(0, cardHeight + kTranscriptGap, MIN(500, self.bounds.size.width), self.bounds.size.height - cardHeight - kTranscriptGap));
    } else {
        // The name and "1:23 (2 MB)" beside the button.
        CGFloat x = NSMaxX(play) + 12, width = self.cardWidth - x - kAudioPadding;
        NSString *name = self.file.title.length ? self.file.title : self.file.name;
        SNDrawText(name, SNFont(SNFontSizeBase, SNFontWeightBold), SNLegacyPrimaryForeground, 18.75, NSTextAlignmentLeft, 1, NSMakeRect(x, kAudioPadding, width, 18.75));
        NSString *size = SNFormatFileSize(self.file.size);
        NSString *meta = self.length > 0 ? [NSString stringWithFormat:@"%@ (%@)", SNFormatDuration(self.length), size] : size;
        SNDrawText(meta, SNFont(SNFontSizeCaption, SNFontWeightRegular), kAudioMeta, kTranscriptLine, NSTextAlignmentLeft, 1, NSMakeRect(x, kAudioPadding + 18.75, width, kTranscriptLine));
    }
}

@end

#pragma mark - Sizes

NSSize SNMediaViewSize(SNFile *file, SNFileStyle style, CGFloat width) {
    if (style == SNFileStyleVideo) return VideoSize(file, width);
    CGFloat cardWidth = MAX(kAudioMinWidth, MIN(width, kAudioCardWidth));
    if (!SNFileIsAudioClip(file)) return NSMakeSize(cardWidth, kUploadHeight);
    NSString *transcript = TranscriptText(file);
    // The transcript's preview runs under the card, up to 500 pt wide.
    CGFloat textWidth = MIN(500, MAX(width, cardWidth));
    CGFloat below = transcript ? kTranscriptGap + SNLineCount(transcript, TranscriptFont(), textWidth, 0) * kTranscriptLine : 0;
    return NSMakeSize(transcript ? textWidth : cardWidth, kClipHeight + ceil(below));
}

SNMediaFileView *SNMakeMediaView(SNFile *file, SNFileStyle style, NSString *context) {
    Class kind = style == SNFileStyleVideo ? SNVideoFileView.class : SNAudioFileView.class;
    return [[kind alloc] initWithFile:file style:style context:context];
}
