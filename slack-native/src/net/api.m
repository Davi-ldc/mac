// Owns the API's error vocabulary.
#import "net/api.h"

NSErrorDomain const SNAPIErrorDomain = @"SNAPIErrorDomain";
NSErrorUserInfoKey const SNAPIErrorNameKey = @"SNAPIErrorName";
static NSErrorUserInfoKey const SNAPIErrorResponseKey = @"SNAPIErrorResponse";

NSError *SNAPIMakeError(SNAPIError code, NSString *name) {
    return [NSError errorWithDomain:SNAPIErrorDomain code:code userInfo:name ? @{SNAPIErrorNameKey : name, NSLocalizedDescriptionKey : name} : nil];
}

NSString *SNAPIErrorName(NSError *error) {
    return [error.domain isEqualToString:SNAPIErrorDomain] ? error.userInfo[SNAPIErrorNameKey] : nil;
}

NSError *SNAPISlackError(NSDictionary *body) {
    id name = body[@"error"];
    name = [name isKindOfClass:NSString.class] ? name : @"unknown_error";
    return [NSError errorWithDomain:SNAPIErrorDomain code:SNAPIErrorSlack userInfo:@{SNAPIErrorNameKey : name, NSLocalizedDescriptionKey : name, SNAPIErrorResponseKey : body}];
}

NSDictionary *SNAPIErrorResponse(NSError *error) {
    return [error.domain isEqualToString:SNAPIErrorDomain] ? error.userInfo[SNAPIErrorResponseKey] : nil;
}
