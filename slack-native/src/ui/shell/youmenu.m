// Owns the user's menu: its items for the user's status and presence, and where each goes.
#import "render/emoji.h"
#import "render/strings.h"
#import "ui/shell/actions.h"
#import "ui/shell/status.h"
#import "ui/shell/youmenu.h"

NSArray<SNMenuItem *> *SNYouMenuItems(id<SNSource> source, id<SNNavigator> navigator, NSWindow *window) {
    SNUser *me = source.me;
    NSMutableArray<SNMenuItem *> *items = [NSMutableArray new];
    NSString *emoji = [me.statusEmoji stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@":"]];
    BOOL hasStatus = me.statusText.length || emoji.length;
    NSString *glyph = emoji.length ? SNEmojiUnicode(emoji) : nil;
    NSString *statusTitle = nil;
    if (!hasStatus) statusTitle = SNLocalized(@"shell.you.status");
    else if (glyph.length) statusTitle = me.statusText.length ? [NSString stringWithFormat:@"%@ %@", glyph, me.statusText] : glyph;
    else if (me.statusText.length) statusTitle = me.statusText;
    else statusTitle = [NSString stringWithFormat:@":%@:", emoji];
    SNMenuItem *status = [SNMenuItem itemWithTitle:statusTitle action:^{ [SNStatusDialog showInWindow:window source:source now:NSDate.date]; }];
    if (!hasStatus) status.icon = @"emoji";
    [items addObject:status];
    if (hasStatus) [items addObject:[SNMenuItem itemWithTitle:SNLocalized(@"shell.you.clearStatus") action:^{ [source setMyStatusText:@"" canonical:nil emoji:@"" expiration:0]; }]];
    BOOL away = [source presenceOfUser:me.userID] == SNPresenceAway;
    [items addObject:[SNMenuItem itemWithTitle:SNLocalized(away ? @"shell.you.active" : @"shell.you.away")
                                        action:^{ [source setMyPresence:away ? SNPresenceActive : SNPresenceAway]; }]];
    [items addObject:SNMenuItem.separator];
    __weak id<SNNavigator> weakNavigator = navigator;
    [items addObject:[SNMenuItem itemWithTitle:SNLocalized(@"shell.you.profile") action:^{
               id<SNNavigator> to = weakNavigator;
               if (me.userID && to.location) [to go:[to.location locationWithPanel:SNPanelProfile(me.userID)]];
           }]];
    SNMenuItem *preferences = [SNMenuItem itemWithTitle:SNLocalized(@"shell.workspace.preferences") action:^{
        [NSApp sendAction:@selector(showPreferences:) to:nil from:nil];
    }];
    preferences.shortcut = @"⌘,";
    [items addObject:preferences];
    [items addObject:SNMenuItem.separator];
    [items addObject:[SNMenuItem itemWithTitle:SNLocalizedFormat(@"shell.you.signout", source.workspace.name ?: @"")
                                        action:^{ [NSApp sendAction:@selector(signOut:) to:nil from:nil]; }]];
    return items;
}

SNPopover *SNShowYouMenu(NSView *view, id<SNSource> source, id<SNNavigator> navigator) {
    if (!view.window) return nil;
    SNMenu *menu = [[SNMenu alloc] initWithItems:SNYouMenuItems(source, navigator, view.window) width:0];
    return [menu showForRect:view.bounds inView:view placement:SNPlacementRight];
}
