// Owns the session's cookie jar, tokens and their serialisation.
#import "model/json.h"
#import "net/session.h"

@implementation SNSessionTeam

+ (instancetype)teamWithJSON:(NSDictionary *)json {
    NSString *teamID = SNJSONString(json, @"id"), *token = SNJSONString(json, @"token");
    NSURL *url = SNJSONURL(json, @"url");
    if (!teamID.length || ![token hasPrefix:@"xox"] || !url) return nil;
    SNSessionTeam *team = [self new];
    team->_json = [json copy];
    team->_teamID = teamID;
    team->_token = token;
    team->_url = url;
    team->_name = SNJSONString(json, @"name");
    team->_domain = SNJSONString(json, @"domain");
    team->_userID = SNJSONString(json, @"user_id");
    team->_enterpriseID = SNJSONString(json, @"enterprise_id");
    return team;
}

@end

static NSDictionary *CookieJSON(NSHTTPCookie *cookie) {
    NSMutableDictionary *json = [@{@"name" : cookie.name, @"value" : cookie.value, @"domain" : cookie.domain, @"path" : cookie.path ?: @"/",
                                   @"secure" : @(cookie.isSecure), @"http_only" : @(cookie.isHTTPOnly)} mutableCopy];
    if (cookie.expiresDate) json[@"expires"] = @(cookie.expiresDate.timeIntervalSince1970);
    return json;
}

static NSHTTPCookie *CookieFromJSON(NSDictionary *json) {
    NSString *name = SNJSONString(json, @"name"), *value = SNJSONString(json, @"value"), *domain = SNJSONString(json, @"domain");
    if (!name.length || !value || !domain.length) return nil;
    NSMutableDictionary *properties = [@{NSHTTPCookieName : name, NSHTTPCookieValue : value, NSHTTPCookieDomain : domain,
                                         NSHTTPCookiePath : SNJSONString(json, @"path") ?: @"/"} mutableCopy];
    if (SNJSONBool(json, @"secure")) properties[NSHTTPCookieSecure] = @"TRUE";
    if (SNJSONBool(json, @"http_only")) properties[@"HttpOnly"] = @"TRUE";
    double expires = SNJSONDouble(json, @"expires");
    if (expires > 0) properties[NSHTTPCookieExpires] = [NSDate dateWithTimeIntervalSince1970:expires];
    return [NSHTTPCookie cookieWithProperties:properties];
}

/// RFC 6265 domain match: a host-only cookie matches its host, a domain cookie its subdomains too.
static BOOL DomainMatches(NSHTTPCookie *cookie, NSString *host) {
    NSString *domain = cookie.domain.lowercaseString;
    host = host.lowercaseString;
    if ([domain hasPrefix:@"."]) {
        NSString *bare = [domain substringFromIndex:1];
        return [host isEqualToString:bare] || [host hasSuffix:domain];
    }
    return [host isEqualToString:domain];
}

static BOOL PathMatches(NSHTTPCookie *cookie, NSString *path) {
    NSString *cookiePath = cookie.path.length ? cookie.path : @"/";
    if (!path.length) path = @"/";
    if ([path isEqualToString:cookiePath]) return YES;
    return [path hasPrefix:cookiePath] && ([cookiePath hasSuffix:@"/"] || [path characterAtIndex:cookiePath.length] == '/');
}

static BOOL Expired(NSHTTPCookie *cookie) { return cookie.expiresDate && cookie.expiresDate.timeIntervalSinceNow <= 0; }

static BOOL SameCookie(NSHTTPCookie *a, NSHTTPCookie *b) {
    return [a.name isEqualToString:b.name] && [a.domain.lowercaseString isEqualToString:b.domain.lowercaseString] &&
           [(a.path ?: @"/") isEqualToString:(b.path ?: @"/")];
}

BOOL SNIsSlackHost(NSString *host) {
    host = host.lowercaseString;
    return [host isEqualToString:@"slack.com"] || [host hasSuffix:@".slack.com"];
}

NSArray<SNSessionTeam *> *SNTeamsWithFirst(NSArray<SNSessionTeam *> *teams, NSString *teamID) {
    NSUInteger index = [teams indexOfObjectPassingTest:^BOOL(SNSessionTeam *team, NSUInteger i, BOOL *stop) { return [team.teamID isEqualToString:teamID]; }];
    if (index == NSNotFound) return teams;
    NSMutableArray *ordered = [teams mutableCopy];
    [ordered removeObjectAtIndex:index];
    [ordered insertObject:teams[index] atIndex:0];
    return ordered;
}

// One lock (the session itself) guards the jar, the teams and the version: HTTP answers take
// cookies on URLSession's queue and the Keychain saver reads the whole session on its own.
@implementation SNSession {
    NSMutableArray<NSHTTPCookie *> *_jar;
    NSMutableArray<SNSessionTeam *> *_teamList;
    NSDictionary<NSString *, NSString *> *_version;
}

- (instancetype)initWithCookies:(NSArray<NSHTTPCookie *> *)cookies teams:(NSArray<SNSessionTeam *> *)teams userAgent:(NSString *)userAgent {
    if (!(self = [super init])) return nil;
    _jar = [cookies mutableCopy];
    _teamList = [teams mutableCopy];
    _userAgent = [userAgent copy];
    _version = @{};
    return self;
}

+ (instancetype)sessionWithData:(NSData *)data {
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:NSDictionary.class]) return nil;
    NSArray *cookies = SNJSONMap(json, @"cookies", ^id(NSDictionary *item) { return CookieFromJSON(item); });
    NSMutableArray *teams = [NSMutableArray new];
    [SNJSONObject(json, @"teams") enumerateKeysAndObjectsUsingBlock:^(NSString *teamID, id team, BOOL *stop) {
        SNSessionTeam *decoded = [team isKindOfClass:NSDictionary.class] ? [SNSessionTeam teamWithJSON:SNJSONMerge(team, @{@"id" : teamID})] : nil;
        if (decoded) [teams addObject:decoded];
    }];
    NSString *userAgent = SNJSONString(json, @"user_agent");
    if (!teams.count || !userAgent.length) return nil;
    [teams sortUsingComparator:^NSComparisonResult(SNSessionTeam *a, SNSessionTeam *b) { return [a.teamID compare:b.teamID]; }];
    SNSession *session = [[self alloc] initWithCookies:cookies teams:SNTeamsWithFirst(teams, SNJSONString(json, @"team")) userAgent:userAgent];
    NSMutableDictionary *version = [NSMutableDictionary new];
    [SNJSONObject(json, @"version") enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
        if ([key isKindOfClass:NSString.class] && [value isKindOfClass:NSString.class]) version[key] = value;
    }];
    session->_version = version;
    return session;
}

- (NSData *)data {
    NSMutableDictionary *teams = [NSMutableDictionary new];
    NSMutableArray *cookies = [NSMutableArray new];
    NSDictionary *version;
    @synchronized(self) {
        for (SNSessionTeam *team in _teamList) teams[team.teamID] = team.json;
        for (NSHTTPCookie *cookie in _jar)
            if (!Expired(cookie)) [cookies addObject:CookieJSON(cookie)];
        version = _version;
    }
    NSDictionary *json = @{@"cookies" : cookies, @"teams" : teams, @"team" : self.teams.firstObject.teamID ?: @"", @"user_agent" : self.userAgent, @"version" : version};
    return [NSJSONSerialization dataWithJSONObject:json options:NSJSONWritingSortedKeys error:nil] ?: [NSData data];
}

- (NSString *)account {
    SNSessionTeam *team = self.teams.firstObject;
    return [NSString stringWithFormat:@"%@:%@", team.enterpriseID ?: team.teamID ?: @"", team.userID ?: @""];
}

- (NSArray<NSHTTPCookie *> *)cookies {
    @synchronized(self) {
        return [_jar copy];
    }
}

- (NSArray<SNSessionTeam *> *)teams {
    @synchronized(self) {
        return [_teamList copy];
    }
}

- (SNSessionTeam *)teamWithID:(NSString *)teamID {
    for (SNSessionTeam *team in self.teams)
        if ([team.teamID isEqualToString:teamID]) return team;
    return nil;
}

- (NSDictionary<NSString *, NSString *> *)version {
    @synchronized(self) {
        return _version;
    }
}

- (void)setVersion:(NSDictionary<NSString *, NSString *> *)version {
    @synchronized(self) {
        if ([_version isEqualToDictionary:version]) return;
        _version = [version copy];
    }
    [self changed];
}

/// onChange is set and read on the main thread only.
- (void)changed {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self changed]; });
        return;
    }
    if (self.onChange) self.onChange(self);
}

- (NSString *)cookieHeaderForURL:(NSURL *)url {
    NSString *host = url.host;
    if (!host) return nil;
    BOOL secure = [url.scheme isEqualToString:@"https"] || [url.scheme isEqualToString:@"wss"];
    NSMutableArray<NSString *> *pairs = [NSMutableArray new];
    @synchronized(self) {
        for (NSHTTPCookie *cookie in _jar) {
            if (Expired(cookie) || (cookie.isSecure && !secure) || !DomainMatches(cookie, host) || !PathMatches(cookie, url.path)) continue;
            [pairs addObject:[NSString stringWithFormat:@"%@=%@", cookie.name, cookie.value]];
        }
    }
    return pairs.count ? [pairs componentsJoinedByString:@"; "] : nil;
}

- (NSMutableURLRequest *)requestWithURL:(NSURL *)url {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPShouldHandleCookies = NO;
    [request setValue:self.userAgent forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"https://app.slack.com" forHTTPHeaderField:@"Origin"];
    NSString *cookie = [self cookieHeaderForURL:url];
    if (cookie) [request setValue:cookie forHTTPHeaderField:@"Cookie"];
    return request;
}

- (BOOL)takeCookiesFromResponse:(NSHTTPURLResponse *)response {
    NSURL *url = response.URL;
    // A CDN or another site's cookies are not the session's.
    if (!url || !SNIsSlackHost(url.host)) return NO;
    NSArray<NSHTTPCookie *> *cookies = [NSHTTPCookie cookiesWithResponseHeaderFields:(NSDictionary<NSString *, NSString *> *)response.allHeaderFields forURL:url];
    if (!cookies.count) return NO;
    BOOL changed = NO;
    @synchronized(self) {
        for (NSHTTPCookie *cookie in cookies) {
            NSUInteger index = [_jar indexOfObjectPassingTest:^BOOL(NSHTTPCookie *held, NSUInteger i, BOOL *stop) { return SameCookie(held, cookie); }];
            NSHTTPCookie *held = index == NSNotFound ? nil : _jar[index];
            if (held) [_jar removeObjectAtIndex:index];
            if (Expired(cookie)) changed = changed || held;
            else {
                [_jar addObject:cookie];
                changed = changed || !held || ![held.value isEqualToString:cookie.value];
            }
        }
    }
    if (changed) [self changed];
    return changed;
}

- (void)setToken:(NSString *)token forTeam:(NSString *)teamID {
    @synchronized(self) {
        NSUInteger index = [_teamList indexOfObjectPassingTest:^BOOL(SNSessionTeam *team, NSUInteger i, BOOL *stop) { return [team.teamID isEqualToString:teamID]; }];
        SNSessionTeam *team = index == NSNotFound ? nil : _teamList[index];
        SNSessionTeam *updated = team ? [SNSessionTeam teamWithJSON:SNJSONMerge(team.json, @{@"token" : token})] : nil;
        if (!updated || [team.token isEqualToString:token]) return;
        _teamList[index] = updated;
    }
    [self changed];
}

@end

/// Redirects: Set-Cookie on a 3xx is the session's too, and the hand-set Cookie header (meant for
/// the first host) is replaced by the jar's cookies for the next host, or dropped off Slack's.
@interface SNSessionRedirects : NSObject <NSURLSessionTaskDelegate>
@property (nonatomic) SNSession *session;
@end

@implementation SNSessionRedirects

- (void)URLSession:(NSURLSession *)urlSession
                          task:(NSURLSessionTask *)task
    willPerformHTTPRedirection:(NSHTTPURLResponse *)response
                    newRequest:(NSURLRequest *)request
             completionHandler:(void (^)(NSURLRequest *))completionHandler {
    [self.session takeCookiesFromResponse:response];
    NSMutableURLRequest *next = [request mutableCopy];
    [next setValue:SNIsSlackHost(next.URL.host) ? [self.session cookieHeaderForURL:next.URL] : nil forHTTPHeaderField:@"Cookie"];
    completionHandler(next);
}

@end

NSURLSession *SNMakeURLSession(SNSession *session) {
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.HTTPShouldSetCookies = NO;
    configuration.HTTPCookieAcceptPolicy = NSHTTPCookieAcceptPolicyNever;
    configuration.HTTPCookieStorage = nil;
    configuration.URLCache = nil;
    configuration.timeoutIntervalForRequest = 30;
    SNSessionRedirects *redirects = [SNSessionRedirects new];
    redirects.session = session;
    return [NSURLSession sessionWithConfiguration:configuration delegate:redirects delegateQueue:nil];
}
