// A Slack user, decoded from users.info's "user", users.list's "members" or a user_change event.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SNPresence) {
    SNPresenceUnknown,
    SNPresenceActive,
    SNPresenceAway,
};

/// Slack's "active" and "away" (presence_change, users.list with presence=true).
SNPresence SNPresenceNamed(NSString *_Nullable name);

/// Slack's Names preference ("Full & display names"): users show by their real names. The store
/// sets it from display_real_names_override and the workspace's display_real_names.
void SNSetShowsFullNames(BOOL fullNames);
BOOL SNShowsFullNames(void);

@interface SNUser : NSObject <NSCopying>
@property (nonatomic, readonly) NSString *userID;
@property (nonatomic, readonly, nullable) NSString *teamID;
/// The handle ("name"); Slack shows the display name, else the real name, else this.
@property (nonatomic, readonly) NSString *handle;
@property (nonatomic, readonly) NSString *realName, *displayName;
/// What Slack shows for the user: display name, else real name, else handle; the real name first
/// while SNShowsFullNames().
@property (nonatomic, readonly) NSString *visibleName;
@property (nonatomic, readonly, nullable) NSString *title;
/// The colour Slack gives the user's name in some places, as "rrggbb".
@property (nonatomic, readonly, nullable) NSString *color;
@property (nonatomic, readonly, nullable) NSString *timeZone;
@property (nonatomic, readonly) NSInteger timeZoneOffset;
/// Present when listed with include_locale ("pt-BR").
@property (nonatomic, readonly, nullable) NSString *locale;
@property (nonatomic, readonly, nullable) NSString *statusText, *statusEmoji;
/// 0 when the status does not expire.
@property (nonatomic, readonly) NSTimeInterval statusExpiration;
/// profile.huddle_state ("in_a_huddle"); Slack's client keeps pushing
/// huddle_state_expiration_ts (Unix seconds) 5 minutes ahead while in the huddle, so a state past
/// its expiration (or without one) is a huddle left without saying so.
@property (nonatomic, readonly, nullable) NSString *huddleState;
@property (nonatomic, readonly) NSTimeInterval huddleStateExpiration;
/// profile.huddle_state_channel_id: where the huddle is, when Slack tells.
@property (nonatomic, readonly, nullable) NSString *huddleChannelID;
/// In a huddle at `date` by the profile.
- (BOOL)isInHuddleAt:(NSDate *)date;
/// profile.image_<size> URLs by size in pixels (24, 32, 48, 72, 192, 512, 1024), else the same
/// sizes on Slack's avatar host from profile.avatar_hash.
@property (nonatomic, readonly) NSDictionary<NSNumber *, NSURL *> *avatarURLs;
@property (nonatomic, readonly) BOOL deleted, isBot, isAppUser, isAdmin, isOwner;
/// Guests: single-channel (ultra restricted) or multi-channel (restricted).
@property (nonatomic, readonly) BOOL isRestricted, isUltraRestricted;
@property (nonatomic, readonly) NSTimeInterval updated;

+ (nullable instancetype)userWithJSON:(NSDictionary *)json;
- (nullable NSURL *)avatarURLForPixels:(CGFloat)pixels;
/// The JSON the user was decoded from (reconstructed on demand from decoded fields).
@property (nonatomic, readonly) NSDictionary *json;
/// Whether every decoded field matches `other`.
- (BOOL)isEqualToUser:(SNUser *)other;
/// Decoded again from its JSON with `changes` laid over it; NSNull removes a key.
- (instancetype)userByMergingJSON:(NSDictionary *)changes;
@end

NS_ASSUME_NONNULL_END
