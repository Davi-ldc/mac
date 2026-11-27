// Owns the workspace menu's sections, highlight, keys and actions.
#import "model/json.h"
#import "render/document.h"
#import "render/icon.h"
#import "render/strings.h"
#import "ui/kit/avatar.h"
#import "ui/kit/hoverview.h"
#import "ui/kit/label.h"
#import "ui/kit/popover.h"
#import "ui/shell/actions.h"
#import "ui/shell/workspacemenu.h"

/// Measured on the capture: 320 pt wide; the header 72 tall with the 36 pt icon 24 in and 20
/// down and the name and domain from 72; the plan note 64.5 tall (13 pt on 18 pt lines, 14 above);
/// the upsell 114 (a 15 pt title on 20 pt lines 10.5 down at 48, 13 pt text under it, the glyph
/// at 16); rows 28 tall with labels 24 in, groups padded 8 (9 under the mobile app, 12 under the
/// last) between 1 pt lines.
static const CGFloat kWidth = 320, kInset = 24, kRow = 28, kHeader = 72, kIcon = 36, kIconTop = 20, kNameX = 72, kNote = 64.5,
                     kNoteTop = 14, kUpsell = 114, kUpsellTop = 10.5, kUpsellX = 48;
static const unsigned short kReturn = 36, kUp = 126, kDown = 125;

/// Slack's plan codes in team.info, as the menu names them.
static NSString *PlanName(NSString *code) {
    NSDictionary *names = @{@"std" : @"Pro", @"plus" : @"Business+", @"compliance" : @"Enterprise Grid", @"enterprise" : @"Enterprise Grid"};
    return names[code];
}

/// `text` cut by characters, not words, to fit `width` with an ellipsis, as the menu's CSS does.
static NSString *Fitted(NSString *text, NSFont *font, CGFloat width) {
    if (SNTextWidth(text, font) <= width) return text;
    NSString *fitted = text;
    while (fitted.length > 1) {
        fitted = [[fitted substringToIndex:fitted.length - 1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSString *candidate = [fitted stringByAppendingString:@"…"];
        if (SNTextWidth(candidate, font) <= width) return candidate;
    }
    return text;
}

typedef NS_ENUM(NSInteger, SNMenuPart) {
    SNMenuPartHeader,
    SNMenuPartNote,
    SNMenuPartUpsell,
    SNMenuPartLine,
    SNMenuPartGap,
    SNMenuPartItem,
};

@interface SNWorkspaceMenuPart : NSObject
@property (nonatomic) SNMenuPart kind;
@property (nonatomic) CGFloat height, top;
@property (nonatomic, copy, nullable) NSString *title, *shortcut, *trailingIcon;
/// Where the trailing icon is centred, from the menu's right edge, and its box.
@property (nonatomic) CGFloat trailingCentre, trailingIconSize;
@property (nonatomic, copy, nullable) void (^action)(void);
@end

@implementation SNWorkspaceMenuPart
@end

@interface SNWorkspaceMenu () <SNCursorProvider>
@end

@implementation SNWorkspaceMenu {
    id<SNSource> _source;
    NSArray<SNWorkspaceMenuPart *> *_parts;
    NSArray<SNWorkspaceMenuPart *> *_items;
    SNRenderLayout *_note, *_upsellTitle, *_upsellText;
    SNAvatarView *_icon;
    NSTrackingArea *_tracking;
    __weak SNPopover *_popover;
}

+ (instancetype)showForRect:(NSRect)rect inView:(NSView *)view placement:(SNPlacement)placement source:(id<SNSource>)source {
    SNWorkspaceMenu *menu = [[self alloc] initWithSource:source];
    SNPanelView *panel = [[SNPanelView alloc] initWithFill:SNColorCtrPry radius:SNRadiusMenuLive shadow:SNMenuShadow];
    panel.frame = menu.bounds;
    [panel.contentView addSubview:menu];
    menu->_popover = [SNPopover showContent:panel forRect:rect inView:view placement:placement gap:4];
    [menu.window makeFirstResponder:menu];
    return menu;
}

- (instancetype)initWithSource:(id<SNSource>)source {
    if (!(self = [super initWithFrame:NSZeroRect])) return nil;
    _source = source;
    _highlightedIndex = NSNotFound;
    SNWorkspace *workspace = source.workspace;
    NSString *plan = PlanName(SNJSONString(workspace.json, @"plan") ?: @"");
    NSURL *site = workspace.url ?: [NSURL URLWithString:[NSString stringWithFormat:@"https://%@.slack.com/", workspace.domain]];

    NSMutableArray<SNWorkspaceMenuPart *> *parts = [NSMutableArray new];
    SNWorkspaceMenuPart * (^add)(SNMenuPart, CGFloat) = ^SNWorkspaceMenuPart *(SNMenuPart kind, CGFloat height) {
        SNWorkspaceMenuPart *part = [SNWorkspaceMenuPart new];
        part.kind = kind;
        part.height = height;
        [parts addObject:part];
        return part;
    };
    SNWorkspaceMenuPart * (^item)(NSString *, void (^)(void)) = ^SNWorkspaceMenuPart *(NSString *title, void (^action)(void)) {
        SNWorkspaceMenuPart *part = add(SNMenuPartItem, kRow);
        part.title = title;
        part.action = action;
        return part;
    };
    void (^open)(NSString *) = ^(NSString *path) {
        NSURL *url = [NSURL URLWithString:path relativeToURL:site];
        if (url) [NSWorkspace.sharedWorkspace openURL:url];
    };
    add(SNMenuPartHeader, kHeader);
    if (plan) {
        add(SNMenuPartLine, 1);
        add(SNMenuPartNote, kNote);
    }
    add(SNMenuPartLine, 1);
    add(SNMenuPartUpsell, kUpsell);
    add(SNMenuPartLine, 1);
    add(SNMenuPartGap, 8);
    item(SNLocalizedFormat(@"shell.workspace.invite", workspace.name), ^{ open(@"admin/invites"); });
    add(SNMenuPartGap, 8);
    add(SNMenuPartLine, 1);
    add(SNMenuPartGap, 8);
    item(SNLocalized(@"shell.workspace.preferences"), ^{ [NSApp sendAction:@selector(showPreferences:) to:nil from:nil]; }).shortcut = @"⌘,";
    SNWorkspaceMenuPart *tools = item(SNLocalized(@"shell.workspace.tools"), ^{ open(@"admin"); });
    // The caret has no size of its own: it takes the row's 15 px.
    tools.trailingIcon = @"caret-right";
    tools.trailingIconSize = 15;
    tools.trailingCentre = 32;
    add(SNMenuPartGap, 8);
    add(SNMenuPartLine, 1);
    add(SNMenuPartGap, 8);
    // The phone follows the label, which is cut short for it. Slack draws it from its legacy icon
    // font; the outline set's phone stands in.
    SNWorkspaceMenuPart *mobile = item(SNLocalized(@"shell.workspace.mobile"), ^{ open(@"https://slack.com/downloads"); });
    mobile.trailingIcon = @"mobile";
    mobile.trailingIconSize = 20;
    mobile.trailingCentre = 53;
    add(SNMenuPartGap, 9);
    add(SNMenuPartLine, 1);
    add(SNMenuPartGap, 8);
    item(SNLocalized(@"shell.workspace.signout"), ^{ [NSApp sendAction:@selector(signOut:) to:nil from:nil]; });
    add(SNMenuPartGap, 12);
    CGFloat top = 0;
    for (SNWorkspaceMenuPart *part in parts) {
        part.top = top;
        top += part.height;
    }
    _parts = parts;
    _items = [parts filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"kind == %d", SNMenuPartItem]];
    self.frame = NSMakeRect(0, 0, kWidth, top);

    SNTextStyle small = {SNFontSizeCaption, SNFontWeightRegular, 18, SNColorContentPry};
    if (plan) {
        SNInlineText *note = [[SNInlineText alloc] initWithStyle:small];
        [note appendText:SNLocalized(@"shell.workspace.plan.before") style:0];
        [note appendText:SNLocalizedFormat(@"shell.workspace.plan.name", plan) style:SNInlineBold];
        [note appendText:SNLocalized(@"shell.workspace.plan.after") style:0];
        [note appendLink:[NSURL URLWithString:@"https://slack.com/pricing"] text:SNLocalized(@"shell.workspace.plan.more") style:0];
        _note = [[SNRenderDocument documentWithBlocks:@[ note.paragraph ]] layoutForWidth:kWidth - 2 * kInset];
    }
    SNInlineText *title = [[SNInlineText alloc] initWithStyle:(SNTextStyle){SNFontSizeBase, SNFontWeightRegular, 20, SNColorContentPry}];
    [title appendText:SNLocalized(@"shell.workspace.upsell.title") style:0];
    _upsellTitle = [[SNRenderDocument documentWithBlocks:@[ title.paragraph ]] layoutForWidth:kWidth - kUpsellX - kInset];
    SNInlineText *text = [[SNInlineText alloc] initWithStyle:(SNTextStyle){SNFontSizeCaption, SNFontWeightRegular, 18, SNColorContentSec}];
    [text appendText:SNLocalized(@"shell.workspace.upsell.text") style:0];
    _upsellText = [[SNRenderDocument documentWithBlocks:@[ text.paragraph ]] layoutForWidth:kWidth - kUpsellX - kInset];

    _icon = [[SNAvatarView alloc] initWithFrame:NSMakeRect(kInset, kIconTop, kIcon, kIcon)];
    _icon.imageURL = [workspace iconURLForPixels:kIcon * 2];
    _icon.placeholderColor = SNLegacyForegroundMaxSolid;
    [self addSubview:_icon];
    return self;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }

- (void)close { [_popover close]; }

- (NSArray<NSString *> *)itemTitles { return [_items valueForKey:@"title"]; }

- (void)setHighlightedIndex:(NSUInteger)highlightedIndex {
    _highlightedIndex = highlightedIndex;
    self.needsDisplay = YES;
}

#pragma mark Drawing

- (void)drawRect:(NSRect)dirtyRect {
    NSFont *label = SNFont(SNFontSizeBase, SNFontWeightRegular), *small = SNFont(SNFontSizeCaption, SNFontWeightRegular);
    for (SNWorkspaceMenuPart *part in _parts) {
        CGFloat top = part.top;
        switch (part.kind) {
        case SNMenuPartHeader:
            SNDrawText(self->_source.workspace.name, SNFont(SNFontSizeBase, SNFontWeightBold), SNColorContentPry, 22, NSTextAlignmentLeft, 1,
                       NSMakeRect(kNameX, top + 21, kWidth - kNameX - kInset, 22));
            SNDrawText([self->_source.workspace.domain stringByAppendingString:@".slack.com"], small, SNColorContentSec, 18, NSTextAlignmentLeft, 1,
                       NSMakeRect(kNameX, top + 41.5, kWidth - kNameX - kInset, 18));
            break;
        case SNMenuPartNote:
            [_note drawAtPoint:CGPointMake(kInset, top + kNoteTop) hovered:nil images:self.imageHolder];
            break;
        case SNMenuPartUpsell:
            SNDrawIcon(@"rocket", 20, SNColorContentPry, NSMakeRect(16, top + 12, 22, 22));
            [_upsellTitle drawAtPoint:CGPointMake(kUpsellX, top + kUpsellTop) hovered:nil images:self.imageHolder];
            [_upsellText drawAtPoint:CGPointMake(kUpsellX, top + kUpsellTop + _upsellTitle.size.height) hovered:nil images:self.imageHolder];
            break;
        case SNMenuPartLine:
            [SNColor(SNMeasuredMenuSeparator) setFill];
            NSRectFill(NSMakeRect(0, top, kWidth, 1));
            break;
        case SNMenuPartGap:
            break;
        case SNMenuPartItem: {
            BOOL highlighted = [_items indexOfObject:part] == self.highlightedIndex;
            if (highlighted) {
                [SNColor(SNMeasuredMenuHighlight) setFill];
                NSRectFill(NSMakeRect(0, top, kWidth, kRow));
            }
            CGFloat right = kWidth - kInset;
            if (part.shortcut) {
                CGFloat width = ceil(SNTextWidth(part.shortcut, small));
                SNDrawText(part.shortcut, small, highlighted ? SNColorContentPry : SNColorContentTer, kRow, NSTextAlignmentRight, 1,
                           NSMakeRect(right - width, top, width, kRow));
                right -= width + 8;
            }
            if (part.trailingIcon) {
                CGFloat centre = kWidth - part.trailingCentre;
                SNDrawIcon(part.trailingIcon, part.trailingIconSize, SNColorContentPry, NSMakeRect(centre - 10, top + 4, 20, 20));
                right = centre - 18;
            }
            SNDrawText(Fitted(part.title, label, right - kInset), label, SNColorContentPry, kRow, NSTextAlignmentLeft, 1,
                       NSMakeRect(kInset, top, right - kInset, kRow));
            break;
        }
        }
    }
}

#pragma mark Pointer and keys

- (NSUInteger)itemAtPoint:(NSPoint)point {
    for (NSUInteger i = 0; i < _items.count; i++)
        if (point.y >= _items[i].top && point.y < _items[i].top + kRow) return i;
    return NSNotFound;
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_tracking) [self removeTrackingArea:_tracking];
    _tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect
                                             options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
                                               owner:self
                                            userInfo:nil];
    [self addTrackingArea:_tracking];
}

- (void)mouseMoved:(NSEvent *)event { self.highlightedIndex = [self itemAtPoint:[self convertPoint:event.locationInWindow fromView:nil]]; }
- (NSCursor *)cursorAtPoint:(NSPoint)point { return [self itemAtPoint:point] == NSNotFound ? nil : NSCursor.pointingHandCursor; }
- (void)mouseExited:(NSEvent *)event { self.highlightedIndex = NSNotFound; }
- (void)mouseDown:(NSEvent *)event {}

- (void)mouseUp:(NSEvent *)event {
    NSUInteger index = [self itemAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
    if (index != NSNotFound) [self choose:index];
}

- (void)keyDown:(NSEvent *)event {
    if (event.keyCode == kReturn && self.highlightedIndex != NSNotFound) {
        [self choose:self.highlightedIndex];
    } else if (event.keyCode == kUp || event.keyCode == kDown) {
        NSInteger count = (NSInteger)_items.count, step = event.keyCode == kUp ? -1 : 1;
        NSInteger index = self.highlightedIndex == NSNotFound ? (step > 0 ? 0 : count - 1) : MAX(0, MIN(count - 1, (NSInteger)self.highlightedIndex + step));
        self.highlightedIndex = (NSUInteger)index;
    } else {
        [super keyDown:event];
    }
}

- (void)choose:(NSUInteger)index {
    void (^action)(void) = _items[index].action;
    [self close];
    if (action) action();
}

@end
