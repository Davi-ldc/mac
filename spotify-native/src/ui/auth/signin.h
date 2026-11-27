// Clean browser PKCE OAuth Sign-In screen (zero Soloist key UI).
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface SPSignInView : NSView
@property (nonatomic) BOOL loading;
@property (nonatomic, copy, nullable) NSString *statusMessage;
@property (nonatomic, copy, nullable) NSString *errorMessage;
@property (nonatomic, copy, nullable) void (^onSignIn)(void);
@property (nonatomic, copy, nullable) void (^onCancel)(void);
@end

NS_ASSUME_NONNULL_END
