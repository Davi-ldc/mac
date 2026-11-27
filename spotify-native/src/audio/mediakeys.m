// macOS Media Keys & Control Center bridge (MPNowPlayingInfoCenter + MPRemoteCommandCenter).
#import "audio/mediakeys.h"

#import <MediaPlayer/MediaPlayer.h>
#import <math.h>

@implementation SPMediaKeysBridge {
    BOOL _active;
    NSMutableArray<id> *_commandTargets;
}

- (instancetype)initWithEngine:(id<SPAudioEngine>)engine {
    if (!(self = [super init])) return nil;
    _engine = engine;
    _commandTargets = [NSMutableArray new];
    return self;
}

- (void)dealloc {
    [self deactivate];
}

+ (NSDictionary<NSString *, id> *)nowPlayingInfoForState:(SPPlaybackState *)state
                                                   track:(SPTrack *)track
                                                   nowMs:(int64_t)nowMs {
    if (!state && !track) return @{};
    NSMutableDictionary<NSString *, id> *info = [NSMutableDictionary new];
    info[MPNowPlayingInfoPropertyMediaType] = @(MPNowPlayingInfoMediaTypeAudio);
    if (track.name.length) info[MPMediaItemPropertyTitle] = track.name;
    if (track.artistName.length) info[MPMediaItemPropertyArtist] = track.artistName;
    if (track.albumName.length) info[MPMediaItemPropertyAlbumTitle] = track.albumName;

    int64_t durationMs = state.durationMs > 0 ? state.durationMs : track.durationMs;
    if (durationMs > 0) info[MPMediaItemPropertyPlaybackDuration] = @((double)durationMs / 1000.0);

    int64_t elapsedMs = state ? [state interpolatedPositionMsAt:nowMs] : 0;
    info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @((double)elapsedMs / 1000.0);
    info[MPNowPlayingInfoPropertyPlaybackRate] = state.isPlaying ? @1.0 : @0.0;
    return [info copy];
}

- (void)updateNowPlayingWithState:(SPPlaybackState *)state track:(SPTrack *)track {
    int64_t nowMs = (int64_t)llround(NSDate.date.timeIntervalSince1970 * 1000.0);
    NSDictionary *info = [SPMediaKeysBridge nowPlayingInfoForState:state track:track nowMs:nowMs];
    MPNowPlayingInfoCenter *center = MPNowPlayingInfoCenter.defaultCenter;
    center.nowPlayingInfo = info.count ? info : nil;
    if (state.isPlaying) center.playbackState = MPNowPlayingPlaybackStatePlaying;
    else if (state.isPaused) center.playbackState = MPNowPlayingPlaybackStatePaused;
    else center.playbackState = MPNowPlayingPlaybackStateStopped;
}

- (void)dispatchRemoteCommand:(void (^)(id<SPAudioEngine> engine))action {
    if (!action) return;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        id<SPAudioEngine> eng = weakSelf.engine;
        if (eng) action(eng);
    });
}

- (void)activate {
    if (_active) return;
    _active = YES;
    MPRemoteCommandCenter *cc = MPRemoteCommandCenter.sharedCommandCenter;
    __weak typeof(self) weakSelf = self;

    cc.playCommand.enabled = YES;
    [_commandTargets addObject:[cc.playCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        (void)event;
        [weakSelf dispatchRemoteCommand:^(id<SPAudioEngine> eng) { [eng resume]; }];
        return MPRemoteCommandHandlerStatusSuccess;
    }]];

    cc.pauseCommand.enabled = YES;
    [_commandTargets addObject:[cc.pauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        (void)event;
        [weakSelf dispatchRemoteCommand:^(id<SPAudioEngine> eng) { [eng pause]; }];
        return MPRemoteCommandHandlerStatusSuccess;
    }]];

    cc.togglePlayPauseCommand.enabled = YES;
    [_commandTargets addObject:[cc.togglePlayPauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        (void)event;
        [weakSelf dispatchRemoteCommand:^(id<SPAudioEngine> eng) { [eng togglePlayPause]; }];
        return MPRemoteCommandHandlerStatusSuccess;
    }]];

    cc.nextTrackCommand.enabled = YES;
    [_commandTargets addObject:[cc.nextTrackCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        (void)event;
        [weakSelf dispatchRemoteCommand:^(id<SPAudioEngine> eng) { [eng skipNext]; }];
        return MPRemoteCommandHandlerStatusSuccess;
    }]];

    cc.previousTrackCommand.enabled = YES;
    [_commandTargets addObject:[cc.previousTrackCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        (void)event;
        [weakSelf dispatchRemoteCommand:^(id<SPAudioEngine> eng) { [eng skipPrevious]; }];
        return MPRemoteCommandHandlerStatusSuccess;
    }]];

    cc.changePlaybackPositionCommand.enabled = YES;
    [_commandTargets addObject:[cc.changePlaybackPositionCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        if ([event isKindOfClass:MPChangePlaybackPositionCommandEvent.class]) {
            NSTimeInterval pos = ((MPChangePlaybackPositionCommandEvent *)event).positionTime;
            int64_t ms = (int64_t)llround(pos * 1000.0);
            [weakSelf dispatchRemoteCommand:^(id<SPAudioEngine> eng) { [eng seekToMs:ms]; }];
            return MPRemoteCommandHandlerStatusSuccess;
        }
        return MPRemoteCommandHandlerStatusCommandFailed;
    }]];
}

- (void)deactivate {
    if (!_active) return;
    _active = NO;
    MPRemoteCommandCenter *cc = MPRemoteCommandCenter.sharedCommandCenter;
    for (id target in _commandTargets) {
        [cc.playCommand removeTarget:target];
        [cc.pauseCommand removeTarget:target];
        [cc.togglePlayPauseCommand removeTarget:target];
        [cc.nextTrackCommand removeTarget:target];
        [cc.previousTrackCommand removeTarget:target];
        [cc.changePlaybackPositionCommand removeTarget:target];
    }
    [_commandTargets removeAllObjects];
    cc.playCommand.enabled = NO;
    cc.pauseCommand.enabled = NO;
    cc.togglePlayPauseCommand.enabled = NO;
    cc.nextTrackCommand.enabled = NO;
    cc.previousTrackCommand.enabled = NO;
    cc.changePlaybackPositionCommand.enabled = NO;
    MPNowPlayingInfoCenter *center = MPNowPlayingInfoCenter.defaultCenter;
    center.nowPlayingInfo = nil;
    center.playbackState = MPNowPlayingPlaybackStateStopped;
}

@end
