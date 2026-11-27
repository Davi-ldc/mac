// People: users, bots, user groups, presence, the user's own status, VIPs and full profiles (kept
// for the session). Lookups answer from what is known locally; the source asks Slack for more in
// the background and announces SNChangeUsers when it learns of others.
#import <Foundation/Foundation.h>

#import "model/bot.h"
#import "model/user.h"

NS_ASSUME_NONNULL_BEGIN

@protocol SNPeopleSource <NSObject>
@property (nonatomic, readonly) SNUser *me;
/// nil while unknown; the source then fetches the user and announces SNChangeUsers.
- (nullable SNUser *)userWithID:(NSString *)userID;
/// Presence and Do Not Disturb (or snoozed notifications) as Slack last streamed them in this
/// session (presence_change, dnd.teamInfo, dnd_updated); unknown and off until then.
- (SNPresence)presenceOfUser:(NSString *)userID;
- (BOOL)doNotDisturbOfUser:(NSString *)userID;
/// The bot or integration a message without a user came from; nil while unknown: the source then
/// asks Slack (bots.info) and announces SNChangeUsers with the bot's ID.
- (nullable SNBot *)botWithID:(NSString *)botID;
/// The user whose handle (SNUser.handle, as in "mpdm-alex--sam-1") this is; nil while unknown: the
/// source then searches Slack for it and announces SNChangeUsers when someone arrives.
- (nullable SNUser *)userWithHandle:(NSString *)handle;
/// A user group's handle ("designers" for @designers); nil until usergroups.list or a subteam
/// event names it.
- (nullable NSString *)usergroupHandleWithID:(NSString *)groupID;
/// People whose display name, real name or handle has a word starting with `query` (case and
/// accents ignored), best match first; deleted users left out.
- (NSArray<SNUser *> *)usersMatching:(NSString *)query limit:(NSUInteger)limit;
/// Active or away ("Set yourself as away").
- (void)setMyPresence:(SNPresence)presence;
/// users.profile.set's status; `canonical` is a suggested status's text in Slack's own words.
/// Empty text and emoji (and no canonical) clear it; `expiration` 0 never expires.
- (void)setMyStatusText:(NSString *)text canonical:(nullable NSString *)canonical emoji:(NSString *)emoji expiration:(NSTimeInterval)expiration;
/// The people the user made VIPs, in Slack's order (users.priority.list at boot, then each
/// vip_users_updated); kept across launches.
@property (nonatomic, readonly) NSArray<NSString *> *vipUserIDs;
/// The workspace offers VIPs: a paid plan (Slack's isPriorityVipAvailableForCurrentTeam).
@property (nonatomic, readonly) BOOL offersVIPs;
/// Adds or removes a VIP (users.priority.add / users.priority.remove) at once; undone if Slack
/// refuses. `completion` gets nil or Slack's error ("too_many_vips", "" without an answer) and the
/// limit Slack gave with it (max_vip_limit, else 0).
- (void)setUser:(NSString *)userID VIP:(BOOL)vip completion:(nullable void (^)(NSString *_Nullable error, NSInteger limit))completion;
/// The Preferences' "Recommended" VIPs (users.priority.getRecommendations): Slack's users as it sends
/// them ({user_id, source, reason: "manager", "skip_level", "frequent_collaborator",
/// "frequently_used"}), or nil when it failed.
- (void)fetchVIPRecommendations:(void (^)(NSArray<NSDictionary *> *_Nullable recommendations))completion;
/// The profile panel opened: asks Slack for the user's profile sections (users.profile.getSections),
/// the conversations shared with them (users.profile.getExtras im_mpim_ids) and, when their profile
/// has no fields yet, users.profile.get (merged into the user). Each answer arrives as
/// SNChangeProfiles (or SNChangeUsers).
- (void)loadProfileOfUser:(NSString *)userID;
/// users.profile.getSections' profileSections as Slack sends them ({id, type: "HEADER", "CONTACT",
/// "PEOPLE", "ADDITIONAL_INFO", "CUSTOM", ..., label, profileElements: [{__typename, elementKey,
/// label, text, uri, displayText, date, tags, persons, isMissing...}]}), in Slack's order; nil
/// until they arrive.
- (nullable NSArray<NSDictionary *> *)profileSectionsOfUser:(NSString *)userID;
/// The DMs and group DMs the user shares with `userID` (im_mpim_ids), nil until known; `more` says
/// whether Slack has more group DMs than it listed.
- (nullable NSArray<NSString *> *)recentConversationsWithUser:(NSString *)userID more:(nullable BOOL *)more;
@end

NS_ASSUME_NONNULL_END
