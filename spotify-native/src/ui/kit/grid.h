// Virtualized responsive borderless card grid (SPCardGridView) and horizontal card shelf (SPCardShelfView) matching Spotifly.
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface SPCardItem : NSObject <NSCopying>
@property (nonatomic, readonly, copy) NSString *key;
@property (nonatomic, readonly, copy) NSString *title;
@property (nonatomic, readonly, copy, nullable) NSString *subtitle;
@property (nonatomic, readonly, copy, nullable) NSString *artworkURL;
@property (nonatomic, readonly) BOOL circular;
@property (nonatomic, readonly, copy, nullable) NSString *contextURI;
@property (nonatomic, readonly, nullable) id representedObject;
@property (nonatomic) BOOL isLikedSongsTile;
@property (nonatomic, copy, nullable) NSString *placeholderSymbol;

- (instancetype)initWithKey:(NSString *)key
                      title:(NSString *)title
                   subtitle:(nullable NSString *)subtitle
                 artworkURL:(nullable NSString *)artworkURL
                   circular:(BOOL)circular
                 contextURI:(nullable NSString *)contextURI
          representedObject:(nullable id)representedObject NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

/// Non-layer-backed borderless Spotifly card (artwork + soft shadow + crisp title/subtitle underneath).
@interface SPCardCellView : NSView
@property (nonatomic, strong, nullable) SPCardItem *item;
@property (nonatomic, getter=isHovered) BOOL hovered;
@property (nonatomic, getter=isPlayHovered) BOOL playHovered;
@property (nonatomic, readonly) NSRect playButtonRect;
- (void)prepareForReuse;
@end

/// Virtualized scrolling card grid with responsive columns and a single hover tracking area.
@interface SPCardGridView : NSView
@property (nonatomic, readonly) NSScrollView *scrollView;
@property (nonatomic, copy) NSArray<SPCardItem *> *items;
@property (nonatomic) CGFloat cardWidth;
@property (nonatomic) CGFloat cardHeight;
@property (nonatomic) CGFloat cardGap;
@property (nonatomic) CGFloat horizontalPadding;
@property (nonatomic) CGFloat topPadding;
@property (nonatomic) CGFloat bottomPadding;
@property (nonatomic) BOOL scrollingEnabled;
@property (nonatomic, readonly) NSUInteger columnCount;
@property (nonatomic, readonly) NSUInteger visibleCellCount;

@property (nonatomic, copy, nullable) void (^onSelectItem)(SPCardItem *item);
@property (nonatomic, copy, nullable) void (^onPlayItem)(SPCardItem *item);

- (CGFloat)contentHeightForWidth:(CGFloat)width;
- (void)scrollToY:(CGFloat)y;
@end

/// Horizontal shelf section (Spotifly SectionHeader + CardRow) for Startpage & Search.
@interface SPCardShelfView : NSView
@property (nonatomic, copy) NSString *sectionTitle;
@property (nonatomic, copy, nullable) NSString *trailingActionTitle;
@property (nonatomic) CGFloat cardArtSize;
@property (nonatomic, copy) NSArray<SPCardItem *> *items;
@property (nonatomic, readonly) NSScrollView *scrollView;
@property (nonatomic, copy, nullable) void (^onSelectItem)(SPCardItem *item);
@property (nonatomic, copy, nullable) void (^onPlayItem)(SPCardItem *item);
@property (nonatomic, copy, nullable) void (^onTrailingAction)(void);
+ (CGFloat)preferredHeight;
+ (CGFloat)preferredHeightForArtSize:(CGFloat)artSize circular:(BOOL)circular;
@end

NS_ASSUME_NONNULL_END
