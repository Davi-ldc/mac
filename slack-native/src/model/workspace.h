// A Slack workspace (team), decoded from team.info's "team" or client.userBoot's "team".
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SNWorkspace : NSObject <NSCopying>
@property (nonatomic, readonly) NSString *workspaceID;
@property (nonatomic, readonly) NSString *name;
@property (nonatomic, readonly) NSString *domain;
/// https://<domain>.slack.com/, where API calls for this workspace go.
@property (nonatomic, readonly, nullable) NSURL *url;
@property (nonatomic, readonly, nullable) NSString *enterpriseID, *enterpriseName;
/// icon.image_<size> URLs by size in pixels (34, 44, 68, 88, 102, 132, 230).
@property (nonatomic, readonly) NSDictionary<NSNumber *, NSURL *> *iconURLs;
/// Slack draws the initials instead when the workspace has no icon of its own.
@property (nonatomic, readonly) BOOL iconIsDefault;
/// The statuses the "Set a status" dialog suggests (prefs.custom_status_presets), each
/// @[emoji with colons, text, canonical text, duration key]; empty when the team sends none.
@property (nonatomic, readonly) NSArray<NSArray<NSString *> *> *statusPresets;

+ (nullable instancetype)workspaceWithJSON:(NSDictionary *)json;
@property (nonatomic, readonly) NSDictionary *json;
/// The smallest icon at least `pixels` wide, else the largest.
- (nullable NSURL *)iconURLForPixels:(CGFloat)pixels;
@end

/// Of a map of sizes to URLs, the smallest size at least `pixels`, else the largest.
NSURL *_Nullable SNBestURL(NSDictionary<NSNumber *, NSURL *> *urls, CGFloat pixels);

NS_ASSUME_NONNULL_END
