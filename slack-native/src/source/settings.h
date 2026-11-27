// Settings and live state: the connection, preferences and emoji (the workspace's custom emoji and
// aliases are in render/emoji.h, which the source fills).
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A boolean preference as Slack sends it (true, 1) or as it was set from here ("true");
/// `fallback` while it is missing.
BOOL SNPreferenceBool(NSDictionary *preferences, NSString *name, BOOL fallback);
/// A preference as text ("mentions_dms", "1"); nil while missing.
NSString *_Nullable SNPreferenceString(NSDictionary *preferences, NSString *name);
/// all_notifications_prefs (a JSON object in a string) "global" entry `name`: a string, number or
/// boolean; nil while missing.
id _Nullable SNNotificationPreference(NSDictionary *preferences, NSString *name);

typedef NS_ENUM(NSInteger, SNConnectionState) {
    /// Showing what was cached; no session or not started.
    SNConnectionOffline,
    /// Connecting or reconnecting after a drop (the UI may show its banner after a while).
    SNConnectionConnecting,
    SNConnectionConnected,
};

@protocol SNSettingsSource <NSObject>
@property (nonatomic, readonly) SNConnectionState connectionState;
/// users.prefs.get's "prefs" as Slack sends them (display_real_names, time24, sidebar options...).
@property (nonatomic, readonly) NSDictionary<NSString *, id> *preferences;
/// Sets one of them as Slack's client does (users.prefs.set name and value, the value as Slack
/// keeps it: "true", "false", a JSON object in a string); `preferences` has it at once.
- (void)setPreference:(NSString *)name value:(NSString *)value;
/// Several at once (users.prefs.set prefs=<JSON>), as the Preferences' grouped choices save;
/// undone if Slack refuses.
- (void)setPreferences:(NSDictionary<NSString *, NSString *> *)preferences;
/// Notification preferences for every conversation (users.prefs.setNotifications global=true, one
/// as name and value, several as a prefs list): kept in all_notifications_prefs' "global"; undone
/// if Slack refuses. `reason` is the client's _x_reason for the control that changed them.
- (void)setNotificationPreferences:(NSDictionary<NSString *, NSString *> *)preferences reason:(NSString *)reason;
/// The user's skin tone, 2-6 (as in "::skin-tone-N"), or 0 for none.
@property (nonatomic, readonly) NSInteger preferredSkinTone;
- (void)setPreferredSkinTone:(NSInteger)tone;
/// Emoji names the user picks most, most used first (the picker's "Frequently used").
@property (nonatomic, readonly) NSArray<NSString *> *frequentEmoji;
/// The user picked an emoji (picker or reaction); it counts towards frequentEmoji.
- (void)noteEmojiUsed:(NSString *)name;
@end

NS_ASSUME_NONNULL_END
