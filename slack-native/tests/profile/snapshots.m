// The profile hover card in its SNHoverCard against the official app's capture.
#import "app/launch.h"
#import "snapshot.h"
#import "test.h"
#import "ui/kit/hovercard.h"
#import "ui/profile/profilecard.h"

/// Someone with a title and no status, like the person in the capture.
static SNUser *TitledUser(id<SNSource> source) {
    NSMutableOrderedSet *ids = [NSMutableOrderedSet new];
    for (SNConversation *conversation in source.directMessages)
        if (conversation.userID) [ids addObject:conversation.userID];
    for (NSString *userID in ids) {
        SNUser *user = [source userWithID:userID];
        if (user.title.length && !user.statusText.length && !user.statusEmoji.length) return user;
    }
    return [source userWithID:ids.firstObject ?: source.me.userID] ?: source.me;
}

SN_SNAPSHOT(ProfileCardMatchesTheCapture) {
    id<SNSource> source = SNOpenFixture(SNPrivateFixture() ?: SNPublicFixture());
    // profile_hover_card: the card's ring starts 2 pt into the crop. The card opens 11 pt under
    // the avatar it is about, aligned with its left edge: an avatar ending 11 pt above the
    // card's inner top at 20,60 (window, from the top) puts the crop's origin at 17,57.
    NSSize size = NSMakeSize(400, 320);
    NSWindow *window = [[NSWindow alloc] initWithContentRect:(NSRect){NSZeroPoint, size} styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:YES];
    window.releasedWhenClosed = NO;
    NSView *content = [[NSView alloc] initWithFrame:(NSRect){NSZeroPoint, size}];
    content.wantsLayer = YES;
    content.layer.backgroundColor = SNCGColor(SNMeasuredMessagePaneBg);
    window.contentView = content;
    SNUser *user = TitledUser(source);
    // 1:16 in the person's time zone, as in the capture.
    NSCalendar *calendar = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
    calendar.timeZone = (user.timeZone ? [NSTimeZone timeZoneWithName:user.timeZone] : nil) ?: [NSTimeZone timeZoneForSecondsFromGMT:user.timeZoneOffset];
    NSDate *date = [calendar dateBySettingHour:1 minute:16 second:0 ofDate:[NSDate dateWithTimeIntervalSince1970:1795000000] options:0];
    [SNHoverCard hoverBeganOverRect:NSMakeRect(20, size.height - (60 - 11), 36, 36) inView:content key:@"U1" content:^NSView * {
        SNProfileCardView *card = [[SNProfileCardView alloc] initWithUser:user source:source];
        card.date = date;
        return card;
    }];
    SNSettle(SNHoverCardDelay + 0.3);
    SNPixels *pixels = SNRenderWindow(window);
    SNCompareWithReference(@"profile_card", pixels, @"profile_hover_card", NSMakePoint(17, 57), 2, @[
        [SNRegion region:@"ring" rect:NSMakeRect(2, 2, 342, 1) budget:3],
        [SNRegion ignored:@"avatar (made-up picture)" rect:NSMakeRect(18, 18, 74, 74)],
        [SNRegion ignored:@"name and title (made-up person)" rect:NSMakeRect(100, 30, 244, 50)],
        [SNRegion region:@"top section" rect:NSMakeRect(3, 92, 340, 18) budget:2],
        [SNRegion region:@"divider" rect:NSMakeRect(3, 110, 340, 3) budget:4],
        [SNRegion region:@"local time" rect:NSMakeRect(3, 125, 200, 30) budget:8],
        [SNRegion region:@"buttons" rect:NSMakeRect(3, 160, 340, 36) budget:12],
        [SNRegion ignored:@"outside the card (messages)" rect:NSMakeRect(0, 0, 346, 2)],
    ]);
    [SNHoverCard close];
}
