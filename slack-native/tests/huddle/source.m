// Owns the huddle UI's fixture.
#import "render/images.h"
#import "render/strings.h"
#import "source.h"
#import "store/internal.h"
#import "test.h"

#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

NSDictionary *SNTestRoom(NSString *roomID, NSString *conversationID, NSArray<NSString *> *participants, BOOL ended) {
    return @{@"id" : roomID, @"channels" : @[ conversationID ], @"participants" : ended ? @[] : participants,
             @"participant_history" : participants, @"has_ended" : @(ended), @"date_start" : @1795294800,
             @"date_end" : ended ? @1795296300 : @0, @"created_by" : participants.firstObject ?: @"", @"media_backend_type" : @"free_willy"};
}

@implementation SNHuddleFixture {
    NSMutableDictionary<NSString *, SNHuddle *> *_huddles;
}

+ (instancetype)fixture {
    SNHuddleFixture *source = [self sourceWithFolder:SNPublicFixture()];
    SNSetLanguage(@"en");
    __weak SNHuddleFixture *weakSource = source;
    SNSetImageFetcher(^(NSURL *url, void (^completion)(NSData *)) {
        NSURL *file = url.isFileURL ? url : [weakSource imageFileForURL:url];
        completion(file ? [NSData dataWithContentsOfURL:file] : nil);
    });
    return source;
}

- (instancetype)initWithDatabase:(SNDatabase *)database api:(id<SNAPI>)api {
    if (!(self = [super initWithDatabase:database api:api])) return nil;
    _huddles = [NSMutableDictionary new];
    _usersInHuddles = [NSSet set];
    _invites = @[];
    _joinable = YES;
    _joined = [NSMutableArray new];
    _mutes = [NSMutableArray new];
    _dismissed = [NSMutableArray new];
    return self;
}

/// Delivered at once, as the end of the turn would.
- (void)announce:(SNChangeKind)kind values:(NSSet<NSString *> *)values {
    [self changed:kind value:nil];
    for (NSString *value in values) [self changed:kind value:value];
    SNFlushChanges();
}

- (void)setHuddle:(SNHuddle *)huddle inConversation:(NSString *)conversationID {
    _huddles[conversationID] = huddle;
    [self announce:SNChangeHuddles values:[NSSet setWithObject:conversationID]];
}

- (void)setUsersInHuddles:(NSSet<NSString *> *)usersInHuddles {
    _usersInHuddles = [usersInHuddles copy];
    [self announce:SNChangeUsers values:usersInHuddles];
}

- (void)setInvites:(NSArray<SNHuddleInvite *> *)invites {
    _invites = [invites copy];
    [self announce:SNChangeHuddleInvites values:[NSSet set]];
}

- (void)setFakeCall:(SNCall *)fakeCall {
    _fakeCall = fakeCall;
    [self announce:SNChangeCall values:[NSSet set]];
}

- (SNHuddle *)huddleInConversation:(NSString *)conversationID { return _huddles[conversationID]; }
- (BOOL)isUserInHuddle:(NSString *)userID { return [_usersInHuddles containsObject:userID]; }
- (NSArray<SNHuddleInvite *> *)huddleInvites { return _invites; }
- (BOOL)canJoinHuddles { return _joinable; }
- (SNCall *)call { return _fakeCall; }

- (void)dismissHuddleInvite:(SNHuddleInvite *)invite {
    [_dismissed addObject:invite];
    NSMutableArray *left = [_invites mutableCopy];
    [left removeObject:invite];
    self.invites = left;
}

- (void)joinHuddleInConversation:(NSString *)conversationID { [_joined addObject:conversationID]; }
- (void)setCallMuted:(BOOL)muted { [_mutes addObject:@(muted)]; }
- (void)leaveCall { _leaves++; }

@end
