#import "livewall.h"

/// The renderer normally buffers one or two seconds ahead of the clock. Far beyond that it
/// is accepting samples without showing them (undecodable data), and feeding it would spin.
static const Float64 kMaxLookaheadSeconds = 10.0;

@implementation LWFeed {
    /// The whole movie, memory-mapped: samples are handed to the renderer as ranges of
    /// this mapping, so nothing is read, copied or allocated per frame, and after the
    /// first pass the pages come from the file cache. The cost is that truncating the
    /// file while it plays crashes the process instead of reporting an error.
    NSData *_file;
    /// Walks the sample table in decode order.
    AVSampleCursor *_cursor;
    /// Length of one pass: the decode timeline from the first sample to the end of the last.
    CMTime _period;
    /// Added to every timestamp of the current pass, so the timeline keeps growing across
    /// loops and the layer never has to be flushed at the seam.
    CMTime _loopOffset;
    /// Latest presentation end handed to the renderer, on the output timeline.
    CMTime _queuedUntil;
}

- (instancetype)initWithPath:(NSString *)path {
    if (!(self = [super init])) return nil;
    NSURL *url = [NSURL fileURLWithPath:path];
    NSError *error;
    _file = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedAlways error:&error];
    if (!_file) LWFail(1, @"%@", error.localizedDescription);
// Loading track properties synchronously is fine for a local file at startup; the async
// replacements would only add callback hops.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    AVAssetTrack *track =
        [[AVURLAsset URLAssetWithURL:url options:nil] tracksWithMediaType:AVMediaTypeVideo].firstObject;
    if (!track) LWFail(1, @"no video track in %@", path);
    if (!track.decodable) LWFail(1, @"this Mac has no decoder for the video in %@", path);
    // A track that points at other files has no samples inside the mapping.
    if (!track.selfContained) LWFail(1, @"the video data of %@ is stored in another file", path);
#pragma clang diagnostic pop

    AVSampleCursor *last = [track makeSampleCursorAtLastSampleInDecodeOrder];
    _cursor = [track makeSampleCursorAtFirstSampleInDecodeOrder];
    if (!_cursor || !last) LWFail(1, @"video track has no samples");
    _period = CMTimeSubtract(CMTimeAdd(last.decodeTimeStamp, last.currentSampleDuration),
                             _cursor.decodeTimeStamp);
    _loopOffset = kCMTimeZero;
    _queuedUntil = kCMTimeZero;
    return self;
}

- (NSString *)pumpInto:(AVSampleBufferVideoRenderer *)renderer timebase:(CMTimebaseRef)timebase {
    while (renderer.isReadyForMoreMediaData) {
        CMTime lookahead = CMTimeSubtract(_queuedUntil, CMTimebaseGetTime(timebase));
        if (CMTimeGetSeconds(lookahead) > kMaxLookaheadSeconds)
            return @"the renderer accepts samples but does not display them";

        CMSampleBufferRef sample = [self copyCurrentSample];
        if (!sample) return @"a video sample could not be read from the file";
        [renderer enqueueSampleBuffer:sample];
        CFRelease(sample);

        if ([_cursor stepInDecodeOrderByCount:1] == 0) {
            [_cursor stepInDecodeOrderByCount:-INT64_MAX];
            _loopOffset = CMTimeAdd(_loopOffset, _period);
        }
    }
    return nil;
}

/// Wraps the sample under the cursor, placed on the output timeline, without copying it.
- (CMSampleBufferRef)copyCurrentSample CF_RETURNS_RETAINED {
    AVSampleCursorStorageRange range = _cursor.currentSampleStorageRange;
    if (range.offset < 0 || range.length <= 0 ||
        (uint64_t)range.offset + (uint64_t)range.length > _file.length)
        return NULL;

    CMSampleTimingInfo timing = {
        .duration = _cursor.currentSampleDuration,
        .presentationTimeStamp = CMTimeAdd(_cursor.presentationTimeStamp, _loopOffset),
        .decodeTimeStamp = CMTimeAdd(_cursor.decodeTimeStamp, _loopOffset),
    };
    CMTime end = CMTimeAdd(timing.presentationTimeStamp, timing.duration);
    if (CMTimeCompare(end, _queuedUntil) > 0) _queuedUntil = end;

    // kCFAllocatorNull: the block buffer borrows the mapping, which lives as long as this
    // feed, and the feed lives as long as the renderer is being fed.
    CMBlockBufferRef bytes = NULL;
    CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, (uint8_t *)_file.bytes + range.offset,
                                       (size_t)range.length, kCFAllocatorNull, NULL, 0,
                                       (size_t)range.length, 0, &bytes);
    CMFormatDescriptionRef format = [_cursor copyCurrentSampleFormatDescription];
    size_t size = (size_t)range.length;
    CMSampleBufferRef sample = NULL;
    if (bytes && format)
        CMSampleBufferCreateReady(kCFAllocatorDefault, bytes, format, 1, 1, &timing, 1, &size, &sample);
    if (bytes) CFRelease(bytes);
    if (format) CFRelease(format);
    if (!sample) return NULL;

    // Tells the decoder which samples are keyframes and which depend on others.
    NSDictionary *dependencies = _cursor.currentSampleDependencyAttachments;
    if (dependencies) {
        CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, true);
        NSMutableDictionary *first = (__bridge NSMutableDictionary *)CFArrayGetValueAtIndex(attachments, 0);
        [first addEntriesFromDictionary:dependencies];
    }
    return sample;
}

@end
