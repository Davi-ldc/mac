// Owns the VIP list of the Preferences: its search, rows and recommendations.
#import "model/json.h"
#import "render/strings.h"
#import "ui/kit/avatar.h"
#import "ui/kit/button.h"
#import "ui/kit/label.h"
#import "ui/kit/people.h"
#import "ui/prefs/vips.h"
#import "ui/profile/vip.h"

/// .p-vip_prefs__content: 24 pt under the search; headers 13 pt bold content-sec, 8 pt above the
/// rows; c-base_list_entity--medium rows: 12 pt padding (none at the left) around a 36 pt picture;
/// the divider 8 pt below the VIPs and 12 above "Recommended"; the empty state 96 tall, its label
/// 16 pt down. Six recommendations at most.
static const CGFloat kContentTop = 24, kHeaderLine = 18, kHeaderGap = 8, kRowPadding = 12, kAvatar = 36, kTextGap = 12;
static const CGFloat kEmpty = 96, kEmptyTop = 16, kDividerTop = 8, kDividerBottom = 12;
static const NSUInteger kRecommended = 6;
/// .p-vip_prefs__list_item:hover: rgba(foreground_min, .04).
static const SNColorToken kRowHover = 0xffffff0a;

/// One person: picture, name, what Slack says under it, and the row's button.
@interface SNPrefsVIPRow : SNHoverView
@property (nonatomic) SNUser *user;
@property (nonatomic, copy) NSString *detail;
@property (nonatomic) SNAvatarView *avatar;
@property (nonatomic) SNButton *button;
@end

@implementation SNPrefsVIPRow

- (instancetype)initWithUser:(SNUser *)user detail:(NSString *)detail button:(NSString *)title {
    if (!(self = [super initWithFrame:NSZeroRect])) return nil;
    _user = user;
    _detail = [detail copy];
    self.hoverColor = kRowHover;
    self.pressedColor = kRowHover;
    self.cursor = NSCursor.arrowCursor;
    _avatar = [[SNAvatarView alloc] initWithFrame:NSMakeRect(0, kRowPadding, kAvatar, kAvatar)];
    _avatar.imageURL = [user avatarURLForPixels:kAvatar * 2];
    [self addSubview:_avatar];
    _button = [SNButton outlineButtonWithTitle:title];
    [self addSubview:_button];
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)layout {
    [super layout];
    CGFloat width = ceil(self.button.fittingContentSize.width) + 24;
    self.button.frame = NSMakeRect(NSWidth(self.bounds) - kRowPadding - width, (NSHeight(self.bounds) - 28) / 2, width, 28);
}

- (void)drawRect:(NSRect)dirtyRect {
    CGContextSetShouldSmoothFonts(NSGraphicsContext.currentContext.CGContext, false);
    CGFloat x = kAvatar + kTextGap, width = NSMinX(self.button.frame) - kTextGap - x;
    CGFloat top = self.detail.length ? kRowPadding : kRowPadding + 7;
    SNDrawText(self.user.visibleName, SNFont(SNFontSizeBase, SNFontWeightBold), SNColorContentPry, 22, NSTextAlignmentLeft, 1, NSMakeRect(x, top, width, 22));
    if (self.detail.length)
        SNDrawText(self.detail, SNFont(SNFontSizeMicro, SNFontWeightRegular), SNColorContentSec, 14, NSTextAlignmentLeft, 1, NSMakeRect(x, top + 22, width, 14));
}

@end

@interface SNPrefsVIPList () <SNChangeObserver>
@end

@implementation SNPrefsVIPList {
    id<SNSource> _source;
    SNPeoplePicker *_picker;
    NSArray<NSDictionary *> *_recommendations;
    NSArray<SNPrefsVIPRow *> *_vipRows, *_recommendedRows;
    /// Everyone the rows were made from, shown or still unknown: their changes make them again.
    NSMutableSet<NSString *> *_lookedUp;
    SNLabel *_addedHeader, *_recommendedHeader, *_empty;
    NSView *_divider;
}

- (instancetype)initWithSource:(id<SNSource>)source {
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, 500, 300)])) return nil;
    _source = source;
    __weak SNPrefsVIPList *weakSelf = self;
    _picker = [[SNPeoplePicker alloc] initWithSource:source placeholder:SNLocalized(@"prefs.vip.search") rowHeight:32];
    _picker.maximum = 1;
    // VipListPref's searcher: people, bots, workflows and Slackbot, not the user; VIPs left out.
    _picker.offers = ^BOOL(SNUser *user) {
        SNPrefsVIPList *list = weakSelf;
        return list && !user.deleted && ![user.userID isEqualToString:list->_source.me.userID] && !SNIsVIP(list->_source, user.userID);
    };
    _picker.changed = ^{
        SNPrefsVIPList *list = weakSelf;
        NSString *chosen = list->_picker.userIDs.firstObject;
        if (!chosen) return;
        list->_picker.userIDs = @[];
        [list choose:chosen];
    };
    [self addSubview:_picker];
    _addedHeader = [self header:SNLocalized(@"prefs.vip.added")];
    _recommendedHeader = [self header:SNLocalized(@"prefs.vip.recommended")];
    _empty = [SNLabel labelWithText:SNLocalized(@"prefs.vip.empty") font:SNFont(SNFontSizeBase, SNFontWeightRegular) color:SNColorContentPry];
    _empty.alignment = NSTextAlignmentCenter;
    [self addSubview:_empty];
    _divider = [[NSView alloc] initWithFrame:NSZeroRect];
    _divider.wantsLayer = YES;
    _divider.layer.backgroundColor = SNCGColor(SNColorOtlTer);
    [self addSubview:_divider];
    _recommendations = @[];
    [self makeRows];
    [source fetchVIPRecommendations:^(NSArray<NSDictionary *> *recommendations) {
        SNPrefsVIPList *list = weakSelf;
        if (!list || !recommendations) return;
        list->_recommendations = recommendations;
        [list makeRows];
    }];
    [source addChangeObserver:self];
    return self;
}

- (BOOL)isFlipped { return YES; }

- (SNLabel *)header:(NSString *)text {
    SNLabel *label = [SNLabel labelWithText:text font:SNFont(SNFontSizeCaption, SNFontWeightBold) color:SNColorContentSec];
    label.lineHeight = kHeaderLine;
    [self addSubview:label];
    return label;
}

- (void)sourceChanged:(SNChange *)change {
    if (change.vips || [change.users intersectsSet:_lookedUp]) [self makeRows];
}

/// The VIPs by name, deactivated ones left out; then the first recommendations who are not VIPs.
- (void)makeRows {
    for (NSView *row in [_vipRows arrayByAddingObjectsFromArray:_recommendedRows ?: @[]]) [row removeFromSuperview];
    NSMutableArray<SNUser *> *vips = [NSMutableArray new];
    _lookedUp = [NSMutableSet setWithArray:_source.vipUserIDs];
    for (NSString *userID in _source.vipUserIDs) {
        SNUser *user = [_source userWithID:userID];
        if (user && !user.deleted) [vips addObject:user];
    }
    [vips sortUsingComparator:^NSComparisonResult(SNUser *a, SNUser *b) { return [a.visibleName localizedCaseInsensitiveCompare:b.visibleName]; }];
    NSMutableArray *rows = [NSMutableArray new];
    for (SNUser *user in vips) [rows addObject:[self rowFor:user detail:user.title ?: @"" button:SNLocalized(@"prefs.vip.remove")]];
    _vipRows = rows;
    rows = [NSMutableArray new];
    for (NSDictionary *recommendation in _recommendations) {
        if (rows.count == kRecommended) break;
        NSString *userID = SNJSONString(recommendation, @"user_id");
        if (userID) [_lookedUp addObject:userID];
        SNUser *user = [_source userWithID:userID];
        if (!user || user.deleted || SNIsVIP(_source, userID)) continue;
        NSString *reason = SNJSONString(recommendation, @"reason");
        NSString *key = reason ? [@"prefs.vip.reason." stringByAppendingString:reason] : nil;
        NSString *label = key ? SNLocalized(key) : @"";
        [rows addObject:[self rowFor:user detail:[label isEqualToString:key] ? @"" : label button:SNLocalized(@"prefs.vip.add")]];
    }
    _recommendedRows = rows;
    self.needsLayout = YES;
    if (self.heightChanged) self.heightChanged();
}

- (SNPrefsVIPRow *)rowFor:(SNUser *)user detail:(NSString *)detail button:(NSString *)title {
    SNPrefsVIPRow *row = [[SNPrefsVIPRow alloc] initWithUser:user detail:detail button:title];
    __weak SNPrefsVIPList *weakSelf = self;
    row.button.action = ^(SNButton *button) { [weakSelf choose:user.userID]; };
    [self addSubview:row];
    return row;
}

- (void)choose:(NSString *)userID {
    SNUser *user = [_source userWithID:userID];
    if (user) SNToggleVIP(_source, user, self.window);
}

- (CGFloat)rowHeight { return kAvatar + 2 * kRowPadding; }

- (CGFloat)heightForWidth:(CGFloat)width {
    CGFloat height = _picker.preferredHeight + kContentTop + kHeaderLine + kHeaderGap;
    height += _vipRows.count ? _vipRows.count * self.rowHeight : kEmpty;
    if (_recommendedRows.count) height += kDividerTop + 1 + kDividerBottom + kHeaderLine + kHeaderGap + _recommendedRows.count * self.rowHeight;
    return height;
}

- (void)layout {
    [super layout];
    CGFloat width = NSWidth(self.bounds), y = 0;
    _picker.frame = NSMakeRect(0, y, width, _picker.preferredHeight);
    y += _picker.preferredHeight + kContentTop;
    _addedHeader.frame = NSMakeRect(0, y, width, kHeaderLine);
    y += kHeaderLine + kHeaderGap;
    _empty.hidden = _vipRows.count > 0;
    if (!_vipRows.count) {
        _empty.frame = NSMakeRect(0, y + kEmptyTop, width, 22);
        y += kEmpty;
    }
    for (SNPrefsVIPRow *row in _vipRows) {
        row.frame = NSMakeRect(0, y, width, self.rowHeight);
        y += self.rowHeight;
    }
    BOOL recommended = _recommendedRows.count > 0;
    _divider.hidden = _recommendedHeader.hidden = !recommended;
    if (!recommended) return;
    _divider.frame = NSMakeRect(0, y + kDividerTop, width, 1);
    y += kDividerTop + 1 + kDividerBottom;
    _recommendedHeader.frame = NSMakeRect(0, y, width, kHeaderLine);
    y += kHeaderLine + kHeaderGap;
    for (SNPrefsVIPRow *row in _recommendedRows) {
        row.frame = NSMakeRect(0, y, width, self.rowHeight);
        y += self.rowHeight;
    }
}

- (NSArray<NSString *> *)texts {
    NSMutableArray *texts = [NSMutableArray arrayWithObject:_addedHeader.text];
    if (!_vipRows.count) [texts addObject:_empty.text];
    for (SNPrefsVIPRow *row in _vipRows) [texts addObject:[NSString stringWithFormat:@"%@: %@", row.user.visibleName, row.button.title]];
    if (_recommendedRows.count) [texts addObject:_recommendedHeader.text];
    for (SNPrefsVIPRow *row in _recommendedRows) [texts addObject:[NSString stringWithFormat:@"%@: %@", row.user.visibleName, row.button.title]];
    return texts;
}

- (void)clickButtonOfUser:(NSString *)userID {
    for (SNPrefsVIPRow *row in [_vipRows arrayByAddingObjectsFromArray:_recommendedRows])
        if ([row.user.userID isEqualToString:userID] && row.button.action) row.button.action(row.button);
}

@end
