// Owns the header row: logo or back button, and the borderless search field.
#import "searchbar.h"
#import "theme.h"

static const CGFloat kPadding = 16, kFieldHeight = 24;

@implementation DKSearchBar {
    NSImageView *_logo;
    NSButton *_back;
}

- (instancetype)initWithLogo:(NSImage *)logo {
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, DKPanelWidth, DKHeaderHeight)])) return nil;
    CGFloat iconY = (DKHeaderHeight - DKIconSize) / 2;
    _logo = [NSImageView imageViewWithImage:logo];
    _logo.frame = NSMakeRect(kPadding, iconY, DKIconSize, DKIconSize);
    _logo.imageScaling = NSImageScaleProportionallyUpOrDown;
    _logo.contentTintColor = DKTextTertiary();
    [self addSubview:_logo];

    NSImage *chevron = [[NSImage imageWithSystemSymbolName:@"chevron.left" accessibilityDescription:@"Back"]
        imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:16 weight:NSFontWeightSemibold]];
    _back = [NSButton buttonWithImage:chevron target:self action:@selector(back)];
    _back.bordered = NO;
    _back.contentTintColor = DKTextSecondary();
    _back.frame = NSMakeRect(kPadding, iconY, DKIconSize, DKIconSize);
    _back.hidden = YES;
    [self addSubview:_back];

    // The field's text starts two points inside its frame, and Inter sits a point and a half
    // higher in it than Raycast's text sits in its bar.
    CGFloat fieldX = kPadding + DKIconSize + DKIconGap - 2;
    _field = [[NSTextField alloc] initWithFrame:NSMakeRect(fieldX, (DKHeaderHeight - kFieldHeight) / 2 + 1.5,
                                                           DKPanelWidth - fieldX - kPadding, kFieldHeight)];
    _field.bezeled = NO;
    _field.drawsBackground = NO;
    _field.focusRingType = NSFocusRingTypeNone;
    _field.font = DKFont(18, 400);
    _field.textColor = DKTextPrimary();
    [self addSubview:_field];
    _showsField = YES;
    return self;
}

- (void)setPlaceholder:(NSString *)placeholder {
    _field.placeholderAttributedString = [[NSAttributedString alloc]
        initWithString:placeholder
            attributes:@{NSForegroundColorAttributeName : DKTextTertiary(), NSFontAttributeName : _field.font}];
}

- (void)setShowsBack:(BOOL)showsBack {
    _showsBack = showsBack;
    _back.hidden = !showsBack;
    _logo.hidden = showsBack;
}

- (void)setShowsField:(BOOL)showsField {
    _showsField = showsField;
    _field.hidden = !showsField;
}

- (void)back {
    if (self.onBack) self.onBack();
}

@end
