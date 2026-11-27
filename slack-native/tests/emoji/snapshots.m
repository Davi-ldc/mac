// The emoji picker against the official app's captures: tabs and search, sections, a hovered
// cell and tab, the footer.
#import "app/launch.h"
#import "render/emoji.h"
#import "snapshot.h"
#import "test.h"
#import "ui/emoji/picker.h"
#import "ui/kit/tooltip.h"

static SNEmojiPickerView *Picker(id<SNSource> source) {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:(NSRect){NSZeroPoint, SNEmojiPickerSize} styleMask:NSWindowStyleMaskBorderless
                                                     backing:NSBackingStoreBuffered defer:YES];
    window.releasedWhenClosed = NO;
    NSView *host = [[NSView alloc] initWithFrame:(NSRect){NSZeroPoint, SNEmojiPickerSize}];
    host.wantsLayer = YES;
    host.layer.backgroundColor = SNCGColor(SNMeasuredMessagePaneBg);
    window.contentView = host;
    SNEmojiPickerView *picker = [[SNEmojiPickerView alloc] initWithSource:source];
    [host addSubview:picker];
    [picker focusSearch];
    return picker;
}

static NSArray<SNRegion *> *SectionRegions(void) {
    return @[
        [SNRegion region:@"frequently used title" rect:NSMakeRect(16, 0, 200, 24) budget:6],
        [SNRegion ignored:@"frequently used (the user's own)" rect:NSMakeRect(1, 24, 361, 36)],
        [SNRegion region:@"where work happens" rect:NSMakeRect(1, 60, 361, 132) budget:10],
        [SNRegion region:@"smileys and people" rect:NSMakeRect(1, 192, 361, 69) budget:10],
    ];
}

SN_SNAPSHOT(EmojiPickerMatchesTheCaptures) {
    id<SNSource> source = SNOpenFixture(SNPrivateFixture() ?: SNPublicFixture());
    // Frequently used as in the capture, most used first.
    NSArray *frequent = @[ @"+1", @"eyes", @"man-facepalming", @"smiley", @"slightly_smiling_face" ];
    for (NSUInteger i = 0; i < frequent.count; i++)
        for (NSUInteger n = 0; n < frequent.count - i; n++) [source noteEmojiUsed:frequent[i]];
    SNEmojiPickerView *picker = Picker(source);
    SNPixels *pixels = SNRenderView(picker, SNEmojiPickerSize);
    SNSaveSnapshot(@"emoji_picker", pixels);
    SNCompareWithReference(@"emoji_picker_top", pixels, @"emoji_picker_top", NSZeroPoint, 1, @[
        [SNRegion region:@"border" rect:NSMakeRect(0, 0, 363, 2) budget:2],
        [SNRegion region:@"tabs" rect:NSMakeRect(1, 2, 330, 46) budget:6],
        [SNRegion region:@"custom tab" rect:NSMakeRect(331, 2, 31, 46) budget:6],
        [SNRegion region:@"search field" rect:NSMakeRect(12, 47, 339, 50) budget:6],
    ]);
    // Without the promotion banner the capture has, the sections start 62 pt higher.
    SNCompareWithReference(@"emoji_picker_sections", pixels, @"emoji_picker_sections", NSMakePoint(0, 104), 2, SectionRegions());
    SNCompareWithReference(@"emoji_picker_footer", pixels, @"emoji_picker_footer", NSMakePoint(0, 426.5), 1, @[
        [SNRegion region:@"add emoji" rect:NSMakeRect(1, 0, 180, 61) budget:8],
        [SNRegion region:@"skin tone" rect:NSMakeRect(181, 0, 181, 61) budget:10],
    ]);

    picker.highlightedEmoji = @"white_check_mark";
    picker.tabs[1].hovered = YES;
    SNSettle(0.3);
    // The tooltip has its own snapshot (CommonOverlays); here it would cover the search field.
    [SNTooltip hide];
    pixels = SNRenderView(picker, SNEmojiPickerSize);
    SNSaveSnapshot(@"emoji_picker_hover", pixels);
    SNCompareWithReference(@"emoji_picker_cell_hover", pixels, @"emoji_picker_cell_hover", NSMakePoint(0, 104), 2, SectionRegions());
    SNCompareWithReference(@"emoji_picker_tab_hover", pixels, @"emoji_picker_tab_hover", NSZeroPoint, 1, @[
        [SNRegion region:@"tabs" rect:NSMakeRect(1, 2, 330, 46) budget:6],
        [SNRegion region:@"hovered tab" rect:NSMakeRect(42, 10, 34, 30) budget:10],
    ]);
}

SN_TEST(EmojiPickerSearchAndChoose) {
    id<SNSource> source = SNOpenFixture(SNPublicFixture());
    SNEmojiPickerView *picker = Picker(source);
    __block NSString *chosen = nil;
    picker.completion = ^(NSString *name) { chosen = name; };
    picker.query = @"thumbsu";
    SNExpect([picker.highlightedEmoji hasPrefix:@"+1"], "search highlights the first result");
    picker.highlightedEmoji = @"wave";
    SNExpect(picker.highlightedEmoji == nil || [picker.highlightedEmoji hasPrefix:@"wave"], "highlight follows the name when it is shown");
    picker.query = @"";
    picker.highlightedEmoji = @"wave";
    SNExpect([picker.highlightedEmoji hasPrefix:@"wave"], "browsing shows every emoji");
    SNExpect(SNEmojiNamed(@"wave").hasSkinTones, "wave has skin tones");
}
