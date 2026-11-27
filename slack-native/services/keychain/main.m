// The Keychain service (auth/keychainitems.h says why it exists): reads and writes the session's
// Keychain items for the app it is bundled in. Its bytes must stay the same while the app's
// change, so it is built from this file and auth/keychainitems.m alone (Makefile).
#import <Security/Security.h>

#import "auth/keychainitems.h"

@interface SNKeychainServer : NSObject <NSXPCListenerDelegate, SNKeychainService>
@end

@implementation SNKeychainServer {
    NSString *_peerRequirement;
    SNKeychainItems *_items;
}

- (instancetype)initWithPeerRequirement:(NSString *)requirement {
    if ((self = [super init])) {
        _peerRequirement = requirement;
        _items = [SNKeychainItems sessionItems];
    }
    return self;
}

- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)connection {
    // Checked on every message; a peer that fails it gets the connection invalidated.
    [connection setCodeSigningRequirement:_peerRequirement];
    connection.exportedInterface = [NSXPCInterface interfaceWithProtocol:@protocol(SNKeychainService)];
    connection.exportedObject = self;
    [connection resume];
    return YES;
}

- (void)dataForAccount:(NSString *)account reply:(void (^)(NSData *))reply { reply([_items dataForAccount:account]); }
- (void)setData:(NSData *)data forAccount:(NSString *)account reply:(void (^)(BOOL))reply { reply([_items setData:data forAccount:account]); }

- (void)deleteAccount:(NSString *)account reply:(void (^)(void))reply {
    [_items deleteAccount:account];
    reply();
}

- (void)accountsWithReply:(void (^)(NSArray<NSString *> *))reply { reply([_items accounts]); }

@end

/// The service's own designated requirement: it is signed with the app's identifier, so this is
/// the app's (identifier and certificate) and the only peer it answers. An ad hoc signature's
/// requirement is its own cdhash, which no app meets.
static NSString *PeerRequirement(void) {
    SecCodeRef code = NULL;
    SecRequirementRef requirement = NULL;
    CFStringRef text = NULL;
    if (SecCodeCopySelf(kSecCSDefaultFlags, &code) == errSecSuccess && SecCodeCopyDesignatedRequirement(code, kSecCSDefaultFlags, &requirement) == errSecSuccess)
        SecRequirementCopyString(requirement, kSecCSDefaultFlags, &text);
    if (requirement) CFRelease(requirement);
    if (code) CFRelease(code);
    return CFBridgingRelease(text);
}

int main(void) {
    @autoreleasepool {
        NSString *requirement = PeerRequirement();
        if (!requirement) return 1;
        SNKeychainServer *server = [[SNKeychainServer alloc] initWithPeerRequirement:requirement];
        NSXPCListener *listener = NSXPCListener.serviceListener;
        listener.delegate = server;
        // Never returns.
        [listener resume];
    }
    return 0;
}
