// Owns the sign-in window, the desktop (ASWebAuthenticationSession) flow and reading the tokens
// and cookies Slack's pages leave behind.
#import <AuthenticationServices/AuthenticationServices.h>
#import <WebKit/WebKit.h>
#import <dlfcn.h>

#import "auth/reauth.h"
#import "auth/signin.h"
#import "model/json.h"
#import "net/switches.h"
#import "render/strings.h"

static void LoadWebKit(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ dlopen("/System/Library/Frameworks/WebKit.framework/WebKit", RTLD_LAZY | RTLD_LOCAL); });
}

static void LoadAuthenticationServices(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ dlopen("/System/Library/Frameworks/AuthenticationServices.framework/AuthenticationServices", RTLD_LAZY | RTLD_LOCAL); });
}

NSString *SNSafariUserAgent(void) {
    static NSString *agent;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *version = [NSBundle bundleWithPath:@"/Applications/Safari.app"].infoDictionary[@"CFBundleShortVersionString"];
        // Safari's version follows macOS's since Safari 26.
        if (![version isKindOfClass:NSString.class] || !version.length)
            version = [NSString stringWithFormat:@"%ld.0", (long)NSProcessInfo.processInfo.operatingSystemVersion.majorVersion];
        // Safari has frozen the macOS version and the WebKit build in its user agent since 2020.
        agent = [NSString stringWithFormat:@"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) "
                                           @"Version/%@ Safari/605.1.15",
                                           version];
    });
    return agent;
}

#pragma mark Reading what Slack hands over

/// The fields SNSessionTeam keeps of a workspace description, under the session's names.
static SNSessionTeam *Team(NSString *teamID, NSString *token, NSString *url, NSString *name, NSString *domain, NSString *userID, NSString *enterpriseID) {
    if (!url && domain.length) url = [NSString stringWithFormat:@"https://%@.slack.com/", domain];
    NSMutableDictionary *json = [NSMutableDictionary new];
    json[@"id"] = teamID, json[@"token"] = token, json[@"url"] = url, json[@"name"] = name;
    json[@"domain"] = domain, json[@"user_id"] = userID, json[@"enterprise_id"] = enterpriseID;
    return teamID && token ? [SNSessionTeam teamWithJSON:json] : nil;
}

static NSArray<SNSessionTeam *> *Sorted(NSArray<SNSessionTeam *> *teams) {
    return [teams sortedArrayUsingComparator:^NSComparisonResult(SNSessionTeam *a, SNSessionTeam *b) { return [a.teamID compare:b.teamID]; }];
}

NSArray<SNSessionTeam *> *SNTeamsFromLocalConfig(NSString *json) {
    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    id config = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSMutableArray<SNSessionTeam *> *teams = [NSMutableArray new];
    [SNJSONObject(config, @"teams") enumerateKeysAndObjectsUsingBlock:^(NSString *key, id team, BOOL *stop) {
        SNSessionTeam *decoded = Team(SNJSONString(team, @"id") ?: key, SNJSONString(team, @"token"), SNJSONString(team, @"url"), SNJSONString(team, @"name"),
                                      SNJSONString(team, @"domain"), SNJSONString(team, @"user_id"), SNJSONString(team, @"enterprise_id"));
        if (decoded) [teams addObject:decoded];
    }];
    return Sorted(teams);
}

NSString *SNTeamIDFromClientURL(NSURL *url) {
    NSArray<NSString *> *parts = url.pathComponents;
    if (![url.host isEqualToString:@"app.slack.com"] || parts.count < 3 || ![parts[1] isEqualToString:@"client"]) return nil;
    NSString *teamID = parts[2];
    return [teamID hasPrefix:@"T"] || [teamID hasPrefix:@"E"] ? teamID : nil;
}

NSString *SNTokenFromAuthResponse(NSDictionary *response, NSString *teamID) {
    NSString *token = SNJSONString(SNJSONObject(SNJSONObject(response, @"teams"), teamID), @"token");
    return [token hasPrefix:@"xox"] ? token : nil;
}

NSArray<NSString *> *SNMagicTokensFromCallbackURL(NSURL *url) {
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    // Where the token sits in the callback is not documented (I): any path part or query value.
    NSMutableArray<NSString *> *candidates = [NSMutableArray new];
    if (components.host) [candidates addObject:components.host];
    [candidates addObjectsFromArray:[components.path componentsSeparatedByString:@"/"]];
    for (NSURLQueryItem *item in components.queryItems)
        if (item.value) [candidates addObject:item.value];
    NSMutableOrderedSet<NSString *> *tokens = [NSMutableOrderedSet new];
    for (NSString *candidate in candidates)
        for (NSString *part in [candidate componentsSeparatedByString:@","])
            if ([part hasPrefix:@"z-app-"]) [tokens addObject:part];
    // The browser hands back slack://<team>/magic-login/<key>; loginMagicBulk wants z-app-<team>-<key>.
    NSArray<NSString *> *path = [components.path componentsSeparatedByString:@"/"];
    NSUInteger marker = [path indexOfObject:@"magic-login"];
    if (!tokens.count && components.host.length && marker != NSNotFound && marker + 1 < path.count && path[marker + 1].length)
        [tokens addObject:[NSString stringWithFormat:@"z-app-%@-%@", components.host, path[marker + 1]]];
    return tokens.array;
}

/// The callback's path and query names with every value longer than 12 characters replaced by its
/// length, for the trace: enough to see where a key sits without writing the key.
static NSString *SNCallbackShape(NSURL *url) {
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    NSMutableArray<NSString *> *parts = [NSMutableArray new];
    for (NSString *part in [components.path componentsSeparatedByString:@"/"])
        [parts addObject:part.length > 12 ? [NSString stringWithFormat:@"<%lu>", (unsigned long)part.length] : part];
    NSMutableArray<NSString *> *names = [NSMutableArray new];
    for (NSURLQueryItem *item in components.queryItems) [names addObject:item.name];
    return [NSString stringWithFormat:@"%@?%@", [parts componentsJoinedByString:@"/"], [names componentsJoinedByString:@"&"]];
}

NSArray<SNSessionTeam *> *SNSessionTeamsFromLoginMagicBulk(NSDictionary *response) {
    // Shape inferred (I): {token_results: {<team ID>: {ok, token, team: {id, name, domain, url,
    // enterprise_id}, user_id or user: {id}}}}.
    NSMutableArray<SNSessionTeam *> *teams = [NSMutableArray new];
    [SNJSONObject(response, @"token_results") enumerateKeysAndObjectsUsingBlock:^(NSString *key, id result, BOOL *stop) {
        if ([result isKindOfClass:NSDictionary.class] && result[@"ok"] && !SNJSONBool(result, @"ok")) return;
        NSDictionary *team = SNJSONObject(result, @"team");
        NSString *userID = SNJSONString(result, @"user_id") ?: SNJSONString(SNJSONObject(result, @"user"), @"id") ?: SNJSONString(result, @"user");
        SNSessionTeam *decoded = Team(SNJSONString(team, @"id") ?: key, SNJSONString(result, @"token"), SNJSONString(team, @"url"),
                                      SNJSONString(team, @"name"), SNJSONString(team, @"domain"), userID, SNJSONString(team, @"enterprise_id"));
        if (decoded) [teams addObject:decoded];
    }];
    return Sorted(teams);
}

/// A JSON answer's structure for the trace: keys, and values only where they carry no secret
/// (ok, error, warning and similar flags); every other string becomes its length.
static NSString *SNJSONShape(id value, NSString *key) {
    static NSSet *plain;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ plain = [NSSet setWithArray:@[ @"ok", @"error", @"warning", @"needed", @"provided", @"type", @"reason" ]]; });
    if ([value isKindOfClass:NSDictionary.class]) {
        NSMutableArray *parts = [NSMutableArray new];
        for (NSString *name in [[value allKeys] sortedArrayUsingSelector:@selector(compare:)])
            // Keys can be secrets too (loginMagicBulk keys its results by magic token).
            [parts addObject:[NSString stringWithFormat:@"%@:%@", name.length > 24 ? [NSString stringWithFormat:@"<key %lu>", (unsigned long)name.length] : name,
                                                         SNJSONShape(value[name], name)]];
        return [NSString stringWithFormat:@"{%@}", [parts componentsJoinedByString:@","]];
    }
    if ([value isKindOfClass:NSArray.class])
        return [NSString stringWithFormat:@"[%lu×%@]", (unsigned long)[value count], [value count] ? SNJSONShape([value firstObject], key) : @""];
    if ([value isKindOfClass:NSString.class]) return [plain containsObject:key] ? value : [NSString stringWithFormat:@"<%lu>", (unsigned long)[value length]];
    if (value == (id)kCFBooleanTrue || value == (id)kCFBooleanFalse) return [value boolValue] ? @"true" : @"false";
    return @"<n>";
}

void SNExchangeMagicTokens(NSArray<NSString *> *tokens, NSString *userAgent, NSURLSession *urlSession, void (^completion)(SNSession *session)) {
    NSURLComponents *components = [NSURLComponents componentsWithString:@"https://slack.com/api/auth.loginMagicBulk"];
    components.queryItems = @[ [NSURLQueryItem queryItemWithName:@"magic_tokens" value:[tokens componentsJoinedByString:@","]],
                               [NSURLQueryItem queryItemWithName:@"ssb" value:@"1"] ];
    // An empty jar to collect the cookies the answer sets (d first of all).
    SNSession *jar = [[SNSession alloc] initWithCookies:@[] teams:@[] userAgent:userAgent];
    [[urlSession dataTaskWithRequest:[jar requestWithURL:components.URL] completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if ([response isKindOfClass:NSHTTPURLResponse.class]) [jar takeCookiesFromResponse:(NSHTTPURLResponse *)response];
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSArray *teams = SNSessionTeamsFromLoginMagicBulk([json isKindOfClass:NSDictionary.class] ? json : nil);
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        NSString *slackError = [json isKindOfClass:NSDictionary.class] && [json[@"error"] isKindOfClass:NSString.class] ? json[@"error"] : nil;
        SNTrace(@"signin:loginMagicBulk", status, error ? error.localizedDescription : slackError ?: [NSString stringWithFormat:@"teams=%lu", (unsigned long)teams.count], -1, data.length);
        if (!teams.count && json) SNTrace([@"signin:loginMagicBulk shape " stringByAppendingString:SNJSONShape(json, @"")], status, @"-", -1, 0);
        BOOL signedIn = NO;
        for (NSHTTPCookie *cookie in jar.cookies) signedIn |= [cookie.name isEqualToString:@"d"];
        // Without teams in the answer but with its d cookie, the session exists: the caller reads the
        // token from /auth like the web client does.
        SNSession *session = teams.count || signedIn ? [[SNSession alloc] initWithCookies:jar.cookies teams:teams userAgent:userAgent] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{ completion(session); });
    }] resume];
}

/// The cookies of slack.com and its subdomains; the sign-in pages also collect Google's and others.
static NSArray<NSHTTPCookie *> *SlackCookies(NSArray<NSHTTPCookie *> *cookies) {
    NSMutableArray *kept = [NSMutableArray new];
    for (NSHTTPCookie *cookie in cookies) {
        NSString *domain = [cookie.domain hasPrefix:@"."] ? [cookie.domain substringFromIndex:1] : cookie.domain;
        if ([domain isEqualToString:@"slack.com"] || [domain hasSuffix:@".slack.com"]) [kept addObject:cookie];
    }
    return kept;
}

#pragma mark The window

/// Sign-in stores made and not known to be deleted yet. Only when it lists one does a launch ask
/// WebKit (which starts its own processes) what is on disk.
static NSString *const SNSignInStoresKey = @"SNSignInDataStores";

static void NoteStore(NSString *identifier, BOOL exists) {
    NSMutableArray *identifiers = [[NSUserDefaults.standardUserDefaults stringArrayForKey:SNSignInStoresKey] ?: @[] mutableCopy];
    [identifiers removeObject:identifier];
    if (exists) [identifiers addObject:identifier];
    [NSUserDefaults.standardUserDefaults setObject:identifiers forKey:SNSignInStoresKey];
}

/// A store goes only once its web content process has let go of it, hence the retries; one that
/// never goes stays noted for the next launch.
static void RemoveStore(NSUUID *identifier, NSInteger attempts) {
    LoadWebKit();
    [NSClassFromString(@"WKWebsiteDataStore") removeDataStoreForIdentifier:identifier completionHandler:^(NSError *error) {
        if (!error) NoteStore(identifier.UUIDString, NO);
        else if (attempts > 1)
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ RemoveStore(identifier, attempts - 1); });
    }];
}

void SNRemoveSignInDataStores(NSUUID *keep) {
    NSMutableArray<NSString *> *noted = [[NSUserDefaults.standardUserDefaults stringArrayForKey:SNSignInStoresKey] ?: @[] mutableCopy];
    [noted removeObject:keep.UUIDString ?: @""];
    if (!noted.count) return;
    LoadWebKit();
    Class storeClass = NSClassFromString(@"WKWebsiteDataStore");
    // fetchAllDataStoreIdentifiers answers through WebKit's main run loop, which only exists once
    // WebKit has been used on the main thread; at launch nothing has, and the answer crashed.
    (void)[storeClass nonPersistentDataStore];
    [storeClass fetchAllDataStoreIdentifiers:^(NSArray<NSUUID *> *identifiers) {
        NSMutableSet<NSString *> *gone = [NSMutableSet setWithArray:noted];
        for (NSUUID *identifier in identifiers) {
            [gone removeObject:identifier.UUIDString];
            if (![identifier isEqual:keep]) RemoveStore(identifier, 1);
        }
        for (NSString *identifier in gone) NoteStore(identifier, NO);
    }];
}

@interface SNSignInWindowController () <WKNavigationDelegate, WKUIDelegate, NSWindowDelegate, ASWebAuthenticationPresentationContextProviding>
@end

@implementation SNSignInWindowController {
    void (^_completion)(SNSession *);
    WKWebView *_webView;
    NSUUID *_storeID;
    NSURLSession *_urlSession;
    ASWebAuthenticationSession *_desktopSignIn;
    BOOL _capturing, _finished, _pageRequested;
    NSInteger _attempts, _clientAttempts;
}

- (instancetype)initWithSession:(SNSession *)previous completion:(void (^)(SNSession *))completion {
    NSWindowStyleMask style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 980, 760) styleMask:style backing:NSBackingStoreBuffered defer:YES];
    window.title = SNLocalized(@"auth.window.title");
    window.releasedWhenClosed = NO;
    if (!(self = [super initWithWindow:window])) return nil;
    _completion = [completion copy];
    window.delegate = self;
    // A new store every time, and none kept from before: a leftover holds cookies that belong in
    // the Keychain only.
    _storeID = NSUUID.UUID;
    NoteStore(_storeID.UUIDString, YES);
    SNRemoveSignInDataStores(_storeID);

    LoadWebKit();
    WKWebViewConfiguration *configuration = [NSClassFromString(@"WKWebViewConfiguration") new];
    configuration.websiteDataStore = [NSClassFromString(@"WKWebsiteDataStore") dataStoreForIdentifier:_storeID];
    _webView = [[NSClassFromString(@"WKWebView") alloc] initWithFrame:window.contentView.bounds configuration:configuration];
    _webView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _webView.customUserAgent = SNSafariUserAgent();
    _webView.navigationDelegate = self;
    _webView.UIDelegate = self;
    [window.contentView addSubview:_webView];

    // Cookies are the session's to manage, never the URL loading system's.
    NSURLSessionConfiguration *loading = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    loading.HTTPShouldSetCookies = NO;
    loading.HTTPCookieAcceptPolicy = NSHTTPCookieAcceptPolicyNever;
    _urlSession = [NSURLSession sessionWithConfiguration:loading];

    [window center];
    [self showWindow:nil];
    // An ended session's cookies go back to Slack's pages, so a session Slack still holds is
    // continued instead of a second one starting beside it.
    dispatch_group_t seeded = dispatch_group_create();
    for (NSHTTPCookie *cookie in previous.cookies) {
        dispatch_group_enter(seeded);
        [configuration.websiteDataStore.httpCookieStore setCookie:cookie completionHandler:^{ dispatch_group_leave(seeded); }];
    }
    // The official desktop app signs in through the system browser and a magic link; the web
    // client inside a web view can loop between app.slack.com and the workspace without ever
    // settling, so the page here is only the fallback when the browser flow ends without a link.
    __weak SNSignInWindowController *weakSelf = self;
    dispatch_group_notify(seeded, dispatch_get_main_queue(), ^{ [weakSelf startDesktopSignIn]; });
    return self;
}

- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)action decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSURL *url = action.request.URL;
    SNTrace([@"signin:navigate " stringByAppendingString:url.host ?: url.scheme ?: @"?"], 0, @"ok", -1, 0);
    // The waiting page's two links.
    if ([url.scheme isEqualToString:@"sn-signin"]) {
        decisionHandler(WKNavigationActionPolicyCancel);
        if ([url.resourceSpecifier isEqualToString:@"page"]) [self loadSignInPage];
        else {
            [_desktopSignIn cancel];
            _desktopSignIn = nil;
            [self startDesktopSignIn];
        }
        return;
    }
    if ([url.scheme isEqualToString:@"slack"]) {
        decisionHandler(WKNavigationActionPolicyCancel);
        NSArray *tokens = SNMagicTokensFromCallbackURL(url);
        SNTrace(@"signin:callback", 0, [NSString stringWithFormat:@"tokens=%lu", (unsigned long)tokens.count], -1, 0);
        if (tokens.count) [self exchange:tokens];
        return;
    }
    // Google refuses embedded web views (disallowed_useragent).
    if ([url.host isEqualToString:@"accounts.google.com"]) {
        decisionHandler(WKNavigationActionPolicyCancel);
        [self startDesktopSignIn];
        return;
    }
    if ([url.host isEqualToString:@"app.slack.com"] && action.targetFrame.isMainFrame) {
        NSString *teamID = SNTeamIDFromClientURL(url);
        SNTrace([NSString stringWithFormat:@"signin:client team=%@", teamID ? @"yes" : @"no"], 0, url.path.length > 40 ? [url.path substringToIndex:8] : url.path, -1, 0);
        if (teamID && !_capturing && _clientAttempts++ < 3) {
            _capturing = YES;
            [self fetchTokenFromWebViewForTeam:teamID];
        }
    }
    decisionHandler(WKNavigationActionPolicyAllow);
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    if ([webView.URL.host isEqualToString:@"app.slack.com"] && [webView.URL.path hasPrefix:@"/client"]) [self capture];
}

/// Pages that open a new window (SSO buttons) open in this one.
- (WKWebView *)webView:(WKWebView *)webView createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration
    forNavigationAction:(WKNavigationAction *)action windowFeatures:(WKWindowFeatures *)features {
    [webView loadRequest:action.request];
    return nil;
}

#pragma mark Capture

- (void)capture {
    if (_capturing || _finished) return;
    _capturing = YES;
    _attempts = 0;
    [self readLocalConfig];
}

- (void)readLocalConfig {
    if (_finished) return;
    [_webView evaluateJavaScript:@"localStorage.getItem('localConfig_v2')" completionHandler:^(id result, NSError *error) {
        NSArray *teams = SNTeamsFromLocalConfig([result isKindOfClass:NSString.class] ? result : nil);
        if (teams.count) return [self finishWithTeams:teams];
        // The web client writes its config a moment after the page loads.
        if (++self->_attempts < 20) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self readLocalConfig]; });
            return;
        }
        [self fetchTokenFromAuth];
    }];
}

- (void)finishWithTeams:(NSArray<SNSessionTeam *> *)teams {
    // The web client is open on the workspace signed in to; on Grid the org's ID sorts first.
    teams = SNTeamsWithFirst(teams, SNTeamIDFromClientURL(_webView.URL));
    [_webView.configuration.websiteDataStore.httpCookieStore getAllCookies:^(NSArray<NSHTTPCookie *> *cookies) {
        [self finish:[[SNSession alloc] initWithCookies:SlackCookies(cookies) teams:teams userAgent:SNSafariUserAgent()] closeWindow:YES];
    }];
}

/// Without localConfig_v2: the token from app.slack.com/auth, and the workspace's URL and user
/// from auth.test.
- (void)fetchTokenFromAuth {
    [self fetchTokenFromWebViewForTeam:SNTeamIDFromClientURL(_webView.URL)];
}

- (void)fetchTokenFromWebViewForTeam:(NSString *)teamID {
    if (!teamID) {
        _capturing = NO;
        return;
    }
    [_webView.configuration.websiteDataStore.httpCookieStore getAllCookies:^(NSArray<NSHTTPCookie *> *cookies) {
        [self fetchTokenForTeam:teamID jar:[[SNSession alloc] initWithCookies:SlackCookies(cookies) teams:@[] userAgent:SNSafariUserAgent()]];
    }];
}

- (void)fetchTokenForTeam:(NSString *)teamID jar:(SNSession *)jar {
    [[_urlSession dataTaskWithRequest:[jar requestWithURL:SNClientAuthURL(teamID)] completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if ([response isKindOfClass:NSHTTPURLResponse.class]) [jar takeCookiesFromResponse:(NSHTTPURLResponse *)response];
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSString *token = SNTokenFromAuthResponse([json isKindOfClass:NSDictionary.class] ? json : nil, teamID);
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        SNTrace(@"signin:auth", status, token ? @"token" : error ? error.localizedDescription : @"no token", -1, data.length);
        if (!token && json) SNTrace([@"signin:auth shape " stringByAppendingString:SNJSONShape(json, @"")], status, @"-", -1, 0);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (token) [self identify:token team:teamID jar:jar];
            else {
                self->_capturing = NO;
                // From the browser flow, offer it again; on the page here, the page stays.
                if (!self->_pageRequested) [self showWaitingPage];
            }
        });
    }] resume];
}

- (void)identify:(NSString *)token team:(NSString *)teamID jar:(SNSession *)jar {
    NSMutableURLRequest *request = [jar requestWithURL:[NSURL URLWithString:@"https://slack.com/api/auth.test"]];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    NSString *encoded = [token stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.alphanumericCharacterSet] ?: token;
    request.HTTPBody = [[@"token=" stringByAppendingString:encoded] dataUsingEncoding:NSUTF8StringEncoding];
    [[_urlSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if ([response isKindOfClass:NSHTTPURLResponse.class]) [jar takeCookiesFromResponse:(NSHTTPURLResponse *)response];
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        SNSessionTeam *team = Team(SNJSONString(json, @"team_id") ?: teamID, token, SNJSONString(json, @"url"), SNJSONString(json, @"team"), nil,
                                   SNJSONString(json, @"user_id"), SNJSONString(json, @"enterprise_id"));
        SNTrace(@"signin:auth.test", [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0,
                team ? @"ok" : SNJSONString(json, @"error") ?: @"no team", -1, data.length);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (team) [self finish:[[SNSession alloc] initWithCookies:jar.cookies teams:@[ team ] userAgent:SNSafariUserAgent()] closeWindow:YES];
            else self->_capturing = NO;
        });
    }] resume];
}

#pragma mark The desktop flow (Google SSO)

- (void)startDesktopSignIn {
    if (_desktopSignIn || _finished) return;
    if (!_pageRequested) [self showWaitingPage];
    NSString *host = _webView.URL.host;
    // From a workspace's own pages the flow starts there; from slack.com it asks for the workspace.
    BOOL workspace = [host hasSuffix:@".slack.com"] && ![host isEqualToString:@"app.slack.com"];
    // No dpop=1: it would bind the session to a key pair this client does not hold.
    NSString *link = [NSString stringWithFormat:@"https://%@/ssb/signin?from_desktop_app=1&aswebauth=1", workspace ? host : @"slack.com"];
    LoadAuthenticationServices();
    __weak SNSignInWindowController *weakSelf = self;
    __block __weak ASWebAuthenticationSession *weakSession = nil;
    _desktopSignIn = [[NSClassFromString(@"ASWebAuthenticationSession") alloc] initWithURL:[NSURL URLWithString:link]
                                                                                  callback:[NSClassFromString(@"ASWebAuthenticationSessionCallback") callbackWithCustomScheme:@"slack"]
                                                                         completionHandler:^(NSURL *callbackURL, NSError *error) {
                                                        dispatch_async(dispatch_get_main_queue(), ^{
                                                            SNSignInWindowController *controller = weakSelf;
                                                            if (!controller) return;
                                                            // A session replaced by "open the browser again" ends cancelled; the new one stays.
                                                            if (controller->_desktopSignIn && controller->_desktopSignIn != weakSession) return;
                                                            controller->_desktopSignIn = nil;
                                                            NSArray *tokens = callbackURL ? SNMagicTokensFromCallbackURL(callbackURL) : @[];
                                                            SNTrace(@"signin:desktop-done", 0, error ? [NSString stringWithFormat:@"%@ %ld", error.domain, (long)error.code] : [NSString stringWithFormat:@"callback host=%@ shape=%@ tokens=%lu", callbackURL.host.length > 24 ? @"(long)" : callbackURL.host ?: @"-", SNCallbackShape(callbackURL), (unsigned long)tokens.count], -1, 0);
                                                            if (tokens.count) [controller exchange:tokens];
                                                            else if (callbackURL) [controller loadSignInPage];
                                                        });
                                                    }];
    weakSession = _desktopSignIn;
    _desktopSignIn.presentationContextProvider = self;
    BOOL started = [_desktopSignIn start];
    SNTrace(@"signin:desktop-start", 0, started ? @"ok" : @"refused", -1, 0);
}

/// While the browser has the sign-in, this window says so instead of staying blank, and offers to
/// open the browser again or to sign in on the page here.
- (void)showWaitingPage {
    NSString *html = [NSString stringWithFormat:
        @"<html><body style='font:15px -apple-system;color:#1d1c1d;display:flex;flex-direction:column;"
        @"align-items:center;justify-content:center;height:90vh;text-align:center'>"
        @"<h2 style='font-size:26px'>%@</h2><p style='max-width:420px;color:#616061'>%@</p>"
        @"<p><a href='sn-signin:retry' style='color:#1264a3'>%@</a> &middot; "
        @"<a href='sn-signin:page' style='color:#1264a3'>%@</a></p></body></html>",
        SNLocalized(@"auth.waiting.title"), SNLocalized(@"auth.waiting.body"),
        SNLocalized(@"auth.waiting.retry"), SNLocalized(@"auth.waiting.page")];
    [_webView loadHTMLString:html baseURL:nil];
}

- (void)loadSignInPage {
    if (_finished || _pageRequested) return;
    _pageRequested = YES;
    [_webView loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"https://slack.com/signin"]]];
}

- (ASPresentationAnchor)presentationAnchorForWebAuthenticationSession:(ASWebAuthenticationSession *)session { return self.window; }

- (void)exchange:(NSArray<NSString *> *)tokens {
    // z-app-<team>-<key>
    NSArray<NSString *> *parts = [tokens.firstObject componentsSeparatedByString:@"-"];
    NSString *teamID = parts.count > 3 ? parts[2] : nil;
    SNExchangeMagicTokens(tokens, SNSafariUserAgent(), _urlSession, ^(SNSession *session) {
        if (session.teams.count) [self finish:session closeWindow:YES];
        else if (session && teamID) {
            self->_capturing = YES;
            [self fetchTokenForTeam:teamID jar:session];
        } else [self showWaitingPage];
    });
}

#pragma mark Ending

- (void)windowWillClose:(NSNotification *)notification { [self finish:nil closeWindow:NO]; }

- (void)finish:(SNSession *)session closeWindow:(BOOL)closeWindow {
    if (_finished) return;
    _finished = YES;
    void (^completion)(SNSession *) = _completion;
    _completion = nil;
    [_desktopSignIn cancel];
    _desktopSignIn = nil;
    _webView.navigationDelegate = nil;
    _webView.UIDelegate = nil;
    [_webView removeFromSuperview];
    _webView = nil;
    self.window.delegate = nil;
    if (closeWindow) [self.window close];
    // A session's cookies are kept in the Keychain only.
    RemoveStore(_storeID, 5);
    [_urlSession finishTasksAndInvalidate];
    completion(session);
}

@end
