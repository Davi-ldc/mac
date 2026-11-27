// Owns refreshing a token from the d cookie.
#import "auth/reauth.h"
#import "auth/signin.h"

NSURL *SNClientAuthURL(NSString *teamID) {
    NSURLComponents *components = [NSURLComponents componentsWithString:@"https://app.slack.com/auth"];
    components.queryItems = @[ [NSURLQueryItem queryItemWithName:@"app" value:@"client"], [NSURLQueryItem queryItemWithName:@"response_type" value:@"json"],
                               [NSURLQueryItem queryItemWithName:@"return_to" value:[@"/client/" stringByAppendingString:teamID]],
                               [NSURLQueryItem queryItemWithName:@"teams" value:teamID] ];
    return components.URL;
}

void SNRefreshToken(SNSession *session, NSString *teamID, NSURLSession *urlSession, void (^completion)(BOOL refreshed)) {
    NSURLRequest *request = [session requestWithURL:SNClientAuthURL(teamID)];
    [[urlSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if ([response isKindOfClass:NSHTTPURLResponse.class]) [session takeCookiesFromResponse:(NSHTTPURLResponse *)response];
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSString *token = SNTokenFromAuthResponse([json isKindOfClass:NSDictionary.class] ? json : nil, teamID);
        dispatch_async(dispatch_get_main_queue(), ^{
            // The token Slack just refused, handed back, would only be refused again.
            NSString *held = [session teamWithID:teamID].token;
            BOOL refreshed = token && held && ![token isEqualToString:held];
            if (refreshed) [session setToken:token forTeam:teamID];
            completion(refreshed);
        });
    }] resume];
}
