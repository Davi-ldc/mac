// The shared overlays and controls drawn on their own, for review (no reference crop yet).
#import "snapshot.h"
#import "test.h"
#import "ui/kit/avatar.h"
#import "ui/kit/button.h"
#import "ui/kit/hovercard.h"
#import "ui/kit/popover.h"
#import "ui/kit/tooltip.h"

SN_SNAPSHOT(CommonOverlays) {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 760, 420) styleMask:NSWindowStyleMaskBorderless
                                                     backing:NSBackingStoreBuffered defer:YES];
    window.releasedWhenClosed = NO;
    NSView *content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 760, 420)];
    content.wantsLayer = YES;
    content.layer.backgroundColor = SNCGColor(SNColorBasePry);
    window.contentView = content;

    SNButton *star = [SNButton iconButtonNamed:@"star" size:28 iconSize:18];
    star.frame = NSMakeRect(20, 360, 28, 28);
    star.tooltip = @"Star conversation";
    [content addSubview:star];
    SNButton *hovered = [SNButton iconButtonNamed:@"notifications" size:28 iconSize:18];
    hovered.frame = NSMakeRect(56, 360, 28, 28);
    [content addSubview:hovered];
    SNButton *primary = [SNButton primaryButtonWithTitle:@"Save"];
    primary.frame = (NSRect){NSMakePoint(100, 356), primary.intrinsicContentSize};
    [content addSubview:primary];
    SNButton *outline = [SNButton outlineButtonWithTitle:@"Cancel"];
    outline.frame = (NSRect){NSMakePoint(200, 356), outline.intrinsicContentSize};
    [content addSubview:outline];
    for (SNAvatarPresence presence = SNAvatarPresenceNone; presence <= SNAvatarPresenceAway; presence++)
        for (int dnd = 0; dnd < 2; dnd++) {
            SNAvatarView *avatar = [[SNAvatarView alloc] initWithFrame:NSMakeRect(320 + (presence * 2 + dnd) * 48, 356, 36, 36)];
            avatar.presence = presence;
            avatar.doNotDisturb = dnd;
            [content addSubview:avatar];
        }

    hovered.hovered = YES;
    star.hovered = YES;
    SNMenu *menu = [[SNMenu alloc] initWithItems:@[
        [SNMenuItem headerWithTitle:@"Conversation"], [SNMenuItem itemWithTitle:@"Copy link" action:nil],
        [SNMenuItem itemWithTitle:@"Mark unread" action:nil], [SNMenuItem separator],
        ({
            SNMenuItem *item = [SNMenuItem itemWithTitle:@"Leave" action:nil];
            item.danger = YES;
            item;
        }),
    ]
                                           width:0];
    [menu showForRect:NSMakeRect(20, 300, 28, 28) inView:content placement:SNPlacementBelow];
    menu.highlightedIndex = 2;
    [SNHoverCard hoverBeganOverRect:NSMakeRect(400, 300, 36, 36) inView:content key:@"U1" content:^NSView * {
        return [[NSView alloc] initWithFrame:NSMakeRect(0, 0, SNHoverCardWidth, 180)];
    }];
    SNSettle(SNHoverCardDelay + 0.2);
    SNSaveSnapshot(@"common_overlays", SNRenderView(content, content.frame.size));
    [SNPopover.current close];
    [SNHoverCard close];
    [SNTooltip hide];
}
