// Owns the Clipboard History screen: entries as rows with their details, and pasting an
// entry into the app the panel was opened over.
#import <ImageIO/ImageIO.h>
#import <stdatomic.h>

#import "clipboard.h"
#import "clipboardscreen.h"
#import "icons.h"
#import "paste.h"
#import "theme.h"

// Rows are made on every keystroke, so only this many are; a search still looks through
// every entry.
static const NSUInteger kMaxRows = 500;
// Most the previews kept in memory take together, in bytes of pixels: some twenty of them.
static const NSUInteger kPreviewCacheBytes = 32 << 20;

static NSString *SectionFor(NSDate *date) {
    NSCalendar *calendar = NSCalendar.currentCalendar;
    if ([calendar isDateInToday:date]) return @"Today";
    if ([calendar isDateInYesterday:date]) return @"Yesterday";
    return -date.timeIntervalSinceNow < 7 * 86400 ? @"This Week" : @"Older";
}

static NSString *FirstLine(NSString *text) {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSUInteger end = [trimmed rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location;
    return end == NSNotFound ? trimmed : [trimmed substringToIndex:end];
}

static BOOL IsLink(NSString *text) { return [NSURL URLWithString:text].scheme.length && ![text containsString:@" "]; }

static NSString *ImageTitle(DKClip *clip) {
    return [NSString stringWithFormat:@"%.0f×%.0f", clip.imageSize.width, clip.imageSize.height];
}

NSImage *DKClipPreview(NSData *png, NSSize room, CGFloat scale) {
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)png, NULL);
    if (!source) return nil;
    NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
    NSSize pixels = NSMakeSize([properties[(id)kCGImagePropertyPixelWidth] doubleValue],
                               [properties[(id)kCGImagePropertyPixelHeight] doubleValue]);
    // An image's size in points follows from its resolution: a Retina screenshot is half its pixels.
    NSSize points = NSMakeSize(pixels.width * 72 / ([properties[(id)kCGImagePropertyDPIWidth] doubleValue] ?: 72),
                               pixels.height * 72 / ([properties[(id)kCGImagePropertyDPIHeight] doubleValue] ?: 72));
    CGFloat fit = MIN(1, MIN(room.width / MAX(points.width, 1), room.height / MAX(points.height, 1)));
    NSSize fitted = NSMakeSize(points.width * fit, points.height * fit);
    CGFloat longest = ceil(MAX(fitted.width, fitted.height) * scale);
    NSDictionary *options = @{(id)kCGImageSourceCreateThumbnailFromImageAlways : @YES,
                              (id)kCGImageSourceCreateThumbnailWithTransform : @YES,
                              (id)kCGImageSourceThumbnailMaxPixelSize : @(longest)};
    CGImageRef thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
    CFRelease(source);
    if (!thumbnail) return nil;
    // Scaled down, it has a pixel for each of the screen's, which rounding leaves a hair off
    // the fitted size. With fewer pixels than that it is stretched over the fitted size.
    BOOL scaledDown = MAX(pixels.width, pixels.height) > longest;
    NSSize shown = scaledDown ? NSMakeSize(CGImageGetWidth(thumbnail) / scale, CGImageGetHeight(thumbnail) / scale) : fitted;
    NSImage *preview = [[NSImage alloc] initWithCGImage:thumbnail size:shown];
    CGImageRelease(thumbnail);
    return preview;
}

/// Hands `show` an image entry's preview: read, decoded and scaled off the main thread, as
/// a screenshot takes tens of milliseconds and selecting its row should not wait for it,
/// and then kept, so that coming back to the row shows it at once.
static void LoadPreview(DKClip *clip, NSSize room, CGFloat scale, void (^show)(NSImage *_Nullable)) {
    static NSCache<DKClip *, NSImage *> *previews;
    static NSSize keptRoom;
    static CGFloat keptScale;
    static dispatch_queue_t queue;
    static _Atomic NSUInteger latest;
    if (!queue)
        queue = dispatch_queue_create("local.deskkit.previews",
                                      dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
    // Those kept were made for one room on one kind of screen. A preview still being made
    // for another goes to the cache it was asked for, which nobody reads any more.
    if (!previews || !NSEqualSizes(room, keptRoom) || scale != keptScale) {
        previews = [NSCache new];
        previews.totalCostLimit = kPreviewCacheBytes;
        keptRoom = room;
        keptScale = scale;
    }
    NSCache<DKClip *, NSImage *> *kept = previews;
    NSUInteger request = ++latest;
    NSImage *preview = [kept objectForKey:clip];
    if (preview) return show(preview);
    dispatch_async(queue, ^{
        // Moving down the list asks for every entry passed; only the last is still wanted.
        if (request != latest) return;
        // A selection can be announced twice, and the second asking finds the first's work.
        NSImage *made = [kept objectForKey:clip];
        if (!made) {
            NSData *png = [DKClipboardHistory.shared contentOf:clip];
            made = png ? DKClipPreview(png, room, scale) : nil;
            if (made) [kept setObject:made forKey:clip cost:made.size.width * made.size.height * scale * scale * 4];
        }
        dispatch_async(dispatch_get_main_queue(), ^{ show(made); });
    });
}

static DKDetail *ClipDetail(DKClip *clip) {
    DKDetail *detail = [DKDetail new];
    NSMutableArray *rows = [NSMutableArray new];
    if (clip.application) [rows addObject:@[ @"Application", clip.application ]];
    if (clip.kind == DKClipImage) {
        detail.imageLoader = ^(NSSize room, CGFloat scale, void (^show)(NSImage *)) {
            LoadPreview(clip, room, scale, show);
        };
        [rows addObject:@[ @"Content type", @"Image" ]];
        [rows addObject:@[ @"Dimensions", ImageTitle(clip) ]];
    } else if (clip.kind == DKClipFiles) {
        NSUInteger count = [clip.text componentsSeparatedByString:@"\n"].count;
        detail.text = clip.text;
        [rows addObject:@[ @"Content type", count == 1 ? @"File" : @"Files" ]];
        [rows addObject:@[ @"Files", @(count).stringValue ]];
    } else {
        NSUInteger words = [clip.text componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].count;
        detail.text = clip.text;
        [rows addObject:@[ @"Content type", IsLink(clip.text) ? @"Link" : @"Text" ]];
        [rows addObject:@[ @"Characters", @(clip.text.length).stringValue ]];
        [rows addObject:@[ @"Words", @(words).stringValue ]];
    }
    [rows addObject:@[ @"Copied", DKFormatDate(clip.date) ]];
    detail.metadata = rows;
    return detail;
}

/// An image entry's thumbnail at row size, decoded once for as long as the entry lives:
/// rows are made again on every key press.
static NSImage *ImageIcon(DKClip *clip) {
    static NSMapTable<DKClip *, NSImage *> *icons;
    if (!icons) icons = [NSMapTable weakToStrongObjectsMapTable];
    NSImage *icon = [icons objectForKey:clip];
    if (icon) return icon;
    NSImage *image = clip.thumbnail ? [[NSImage alloc] initWithData:clip.thumbnail] : nil;
    icon = image ? DKIconThumbnail(image) : DKSymbolIcon(@"photo");
    [icons setObject:icon forKey:clip];
    return icon;
}

static DKItem *ClipItem(DKPicker *picker, DKClip *clip) {
    DKClipboardHistory *history = DKClipboardHistory.shared;
    __weak DKPicker *weakPicker = picker;
    DKItem *item = [DKItem new];
    item.key = [NSString stringWithFormat:@"clip:%p", clip];
    item.section = SectionFor(clip.date);
    item.detail = ^DKDetail *{ return ClipDetail(clip); };
    if (clip.kind == DKClipImage) {
        item.title = [NSString stringWithFormat:@"Image (%@)", ImageTitle(clip)];
        item.iconLoader = ^NSImage *{ return ImageIcon(clip); };
    } else {
        NSString *firstLine = FirstLine(clip.text);
        item.title = firstLine;
        BOOL files = clip.kind == DKClipFiles;
        item.iconLoader = ^NSImage *{
            return files ? DKFileIcon(firstLine) : DKSymbolIcon(IsLink(firstLine) ? @"link" : @"doc.plaintext");
        };
    }
    // A history is hundreds of rows, and only the selected one is asked for its actions.
    item.actionsLoader = ^NSArray<DKAction *> *{
        NSString *app = weakPicker.previousApplication.localizedName ?: @"App";
        DKAction *remove = [DKAction actionWithTitle:@"Delete Entry" symbol:@"trash" shortcut:@"ctrl+x" handler:^{
            [history remove:clip];
            [weakPicker reload];
        }];
        remove.destructive = YES;
        DKAction *removeAll = [DKAction actionWithTitle:@"Delete All Entries" symbol:@"trash" shortcut:@"ctrl+shift+x" handler:^{
            [history removeAll];
            [weakPicker reload];
        }];
        removeAll.destructive = YES;
        return @[
            [DKAction actionWithTitle:[@"Paste to " stringByAppendingString:app] symbol:@"doc.on.clipboard" shortcut:@"return"
                              handler:^{
                NSRunningApplication *target = weakPicker.previousApplication;
                BOOL copied = [history copyToPasteboard:clip];
                [weakPicker dismiss];
                if (copied && target) DKPasteInto(target);
            }],
            [DKAction actionWithTitle:@"Copy to Clipboard" symbol:@"doc.on.doc" shortcut:@"cmd+return" handler:^{
                [history copyToPasteboard:clip];
                [weakPicker dismiss];
            }],
            remove,
            removeAll,
        ];
    };
    return item;
}

DKPage *DKClipboardPage(DKPicker *picker) {
    DKPage *page = [DKPage new];
    page.title = @"Clipboard History";
    page.icon = DKCommandIcon(DKCommandClipboardHistory);
    page.placeholder = @"Type to filter entries...";
    page.showsDetail = YES;
    __weak DKPicker *weakPicker = picker;
    page.items = ^NSArray *(NSString *query) {
        NSMutableArray *items = [NSMutableArray new];
        for (DKClip *clip in [DKClipboardHistory.shared clipsMatching:query limit:kMaxRows])
            [items addObject:ClipItem(weakPicker, clip)];
        return items;
    };
    return page;
}
