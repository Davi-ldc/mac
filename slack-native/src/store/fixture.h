// The store over a folder of API responses saved as files, for tests, snapshots and running the
// UI without an account: the same state, events and requests as a signed-in store, with calls
// answered from the folder (writes succeed in memory) and nothing persisted.
//
// The folder holds, each file the JSON body of the method it is named after:
//   auth.test.json, team.info.json, users.list.json, conversations.list.json,
//   client.counts.json, users.channelSections.list.json, dnd.teamInfo.json,
//   optionally users.prefs.get.json, emoji.list.json, usergroups.list.json, client.appCommands.json,
//   users.priority.list.json (the VIPs), and <method>.json for any other method's answer
//   and activity.feed.json
//   (answered when the feed is loaded; activity.feed-<cursor>.json answers the page after it;
//   messages.list answers from the histories, threads and messages.list.json; the channel
//   browser's search.modules.channels from the channels; the files explorer's
//   search.modules.files from the histories' files and search.modules.files.json),
//   conversations.searchLinks/<conversation ID>.json (the links shared in it),
//   conversations.history/<conversation ID>.json (newest first, as Slack lists it; the newest
//   page of 42 is loaded at once, older pages through loadOlderMessagesInConversation:),
//   conversations.replies/<conversation ID>-<thread ts>.json, bots.info/<bot ID>.json,
//   users.profile.getSections/<user ID>.json and users.profile.getExtras/<user ID>.json,
//   images/<last path component of an image URL> (see -imageFileForURL:).
#import "store/store.h"

NS_ASSUME_NONNULL_BEGIN

@interface SNFixtureSource : SNStore
/// nil when the folder lacks auth.test.json, team.info.json or the signed-in user.
+ (nullable instancetype)sourceWithFolder:(NSURL *)folder;
@property (nonatomic, readonly) NSURL *folder;
/// The fixture's copy of an image URL, by its last path component, if it has one.
- (nullable NSURL *)imageFileForURL:(NSURL *)url;
/// Seconds before each call is answered (0: on the next run loop turn).
@property (nonatomic) NSTimeInterval latency;
/// Connected from the start; set it to show the window without a connection.
@property (nonatomic, readwrite) SNConnectionState connectionState;
/// Every call fails with a network error (shows failed sends, reverted reactions).
@property (nonatomic) BOOL failsRequests;
/// Methods called so far, oldest first, for tests: @[method, params].
@property (nonatomic, readonly) NSArray<NSArray *> *calls;
@end

NS_ASSUME_NONNULL_END
