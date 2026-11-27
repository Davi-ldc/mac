// A slash command, decoded from client.appCommands "commands" (Slack's own, apps', custom ones).
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SNCommand : NSObject
/// "/remind", with the slash.
@property (nonatomic, readonly) NSString *name;
/// Other names that run it ("/part" for "/leave"); entries with alias_of fold into their command.
@property (nonatomic, readonly) NSArray<NSString *> *aliases;
/// desc (or description), and the usage hint shown after the name ("[text] [time]").
@property (nonatomic, readonly) NSString *summary, *usage;
/// "core", "app", "custom" or "service"; "client" for the ones Slack's client runs itself.
@property (nonatomic, readonly) NSString *type;
/// The app's ID for an app's command; service_name for a legacy integration's.
@property (nonatomic, readonly, nullable) NSString *appID, *serviceName;
/// Offered by the list (autocomplete is false for some).
@property (nonatomic, readonly) BOOL autocompletes;
/// Slack runs it from a thread: its own commands that work there, and the ones whose app says
/// is_runnable_from_thread; the rest answer that threads are not supported.
@property (nonatomic, readonly) BOOL runsInThreads;
/// The commands of client.appCommands' "commands", aliases folded in.
+ (NSArray<SNCommand *> *)commandsWithJSON:(NSArray *)json;
/// Its name or one of its aliases, compared without case.
- (BOOL)isNamed:(NSString *)name;
@end

NS_ASSUME_NONNULL_END
