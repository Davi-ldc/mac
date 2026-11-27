// Owns the test websocket server.
#import <Network/Network.h>

#import "server.h"
#import "test.h"

// Linked here, beside the only code that uses it, so the shared Makefile needs no change.
__asm__(".linker_option \"-framework\", \"Network\"");

@implementation SNTestSocketServer {
    nw_listener_t _listener;
    NSMutableArray<nw_connection_t> *_connections;
    NSMutableArray *_handshakes, *_received;
}

+ (instancetype)start {
    SNTestSocketServer *server = [self new];
    server->_connections = [NSMutableArray new];
    server->_handshakes = [NSMutableArray new];
    server->_received = [NSMutableArray new];
    server.answersPings = YES;

    nw_parameters_t parameters = nw_parameters_create_secure_tcp(NW_PARAMETERS_DISABLE_PROTOCOL, NW_PARAMETERS_DEFAULT_CONFIGURATION);
    nw_protocol_options_t ws = nw_ws_create_options(nw_ws_version_13);
    __weak SNTestSocketServer *weakServer = server;
    nw_ws_options_set_client_request_handler(ws, dispatch_get_main_queue(), ^nw_ws_response_t(nw_ws_request_t request) {
        NSMutableDictionary *headers = [NSMutableDictionary new];
        nw_ws_request_enumerate_additional_headers(request, ^bool(const char *name, const char *value) {
            headers[@(name).lowercaseString] = @(value);
            return true;
        });
        NSMutableArray<NSString *> *offered = [NSMutableArray new];
        nw_ws_request_enumerate_subprotocols(request, ^bool(const char *subprotocol) {
            [offered addObject:[@(subprotocol) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]];
            return true;
        });
        if (offered.count) headers[@"sec-websocket-protocol"] = [offered componentsJoinedByString:@", "];
        [weakServer noteHandshake:headers];
        NSString *accepted = weakServer.subprotocol;
        return nw_ws_response_create(nw_ws_response_status_accept, accepted && [offered containsObject:accepted] ? accepted.UTF8String : NULL);
    });
    nw_protocol_stack_prepend_application_protocol(nw_parameters_copy_default_protocol_stack(parameters), ws);
    nw_parameters_set_local_endpoint(parameters, nw_endpoint_create_host("127.0.0.1", "0"));
    server->_listener = nw_listener_create(parameters);
    nw_listener_set_queue(server->_listener, dispatch_get_main_queue());
    __block BOOL ready = NO, failed = NO;
    nw_listener_set_state_changed_handler(server->_listener, ^(nw_listener_state_t state, nw_error_t error) {
        ready = ready || state == nw_listener_state_ready;
        failed = failed || state == nw_listener_state_failed;
    });
    nw_listener_set_new_connection_handler(server->_listener, ^(nw_connection_t connection) { [weakServer accept:connection]; });
    nw_listener_start(server->_listener);
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1];
    while (!ready && !failed && deadline.timeIntervalSinceNow > 0) SNSettle(0.01);
    if (!ready) {
        nw_listener_cancel(server->_listener);
        return nil;
    }
    return server;
}

- (uint16_t)port { return nw_listener_get_port(_listener); }
- (NSString *)url { return [NSString stringWithFormat:@"ws://127.0.0.1:%u/", self.port]; }
- (NSUInteger)connectionCount { return _handshakes.count; }
- (NSArray *)handshakes { return [_handshakes copy]; }
- (NSArray *)received { return [_received copy]; }

- (void)noteHandshake:(NSDictionary *)headers { [_handshakes addObject:headers]; }

- (void)accept:(nw_connection_t)connection {
    [_connections addObject:connection];
    nw_connection_set_queue(connection, dispatch_get_main_queue());
    __weak SNTestSocketServer *weakSelf = self;
    nw_connection_set_state_changed_handler(connection, ^(nw_connection_state_t state, nw_error_t error) {
        SNTestSocketServer *server = weakSelf;
        if (state == nw_connection_state_ready && server.helloFrame) [server send:server.helloFrame on:connection];
    });
    nw_connection_start(connection);
    [self receiveOn:connection];
}

- (void)receiveOn:(nw_connection_t)connection {
    __weak SNTestSocketServer *weakSelf = self;
    nw_connection_receive_message(connection, ^(dispatch_data_t content, nw_content_context_t context, bool complete, nw_error_t error) {
        SNTestSocketServer *server = weakSelf;
        if (!server || error) return;
        NSData *data = content ? (NSData *)content : nil;
        nw_protocol_metadata_t metadata = context ? nw_content_context_copy_protocol_metadata(context, nw_protocol_copy_ws_definition()) : nil;
        if (metadata && nw_ws_metadata_get_opcode(metadata) == nw_ws_opcode_binary && server.onData) {
            server.onData(data ?: [NSData data]);
            return [server receiveOn:connection];
        }
        id frame = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if ([frame isKindOfClass:NSDictionary.class]) {
            [server->_received addObject:frame];
            if (server.answersPings && [frame[@"type"] isEqual:@"ping"]) [server send:@{@"type" : @"pong", @"reply_to" : frame[@"id"] ?: @0} on:connection];
        }
        [server receiveOn:connection];
    });
}

- (void)send:(NSDictionary *)frame on:(nw_connection_t)connection {
    NSData *json = [NSJSONSerialization dataWithJSONObject:frame options:0 error:nil];
    dispatch_data_t data = dispatch_data_create(json.bytes, json.length, dispatch_get_main_queue(), DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    nw_protocol_metadata_t metadata = nw_ws_create_metadata(nw_ws_opcode_text);
    nw_content_context_t context = nw_content_context_create("frame");
    nw_content_context_set_metadata_for_protocol(context, metadata);
    nw_connection_send(connection, data, context, true, ^(nw_error_t error) {});
}

- (void)send:(NSDictionary *)frame {
    if (_connections.lastObject) [self send:frame on:_connections.lastObject];
}

- (void)sendData:(NSData *)message {
    if (!_connections.lastObject) return;
    dispatch_data_t data = dispatch_data_create(message.bytes, message.length, dispatch_get_main_queue(), DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    nw_content_context_t context = nw_content_context_create("frame");
    nw_content_context_set_metadata_for_protocol(context, nw_ws_create_metadata(nw_ws_opcode_binary));
    nw_connection_send(_connections.lastObject, data, context, true, ^(nw_error_t error) {});
}

- (void)closeWithCode:(uint16_t)code {
    if (!_connections.lastObject) return;
    nw_protocol_metadata_t metadata = nw_ws_create_metadata(nw_ws_opcode_close);
    nw_ws_metadata_set_close_code(metadata, (nw_ws_close_code_t)code);
    nw_content_context_t context = nw_content_context_create("close");
    nw_content_context_set_metadata_for_protocol(context, metadata);
    nw_connection_send(_connections.lastObject, NULL, context, true, ^(nw_error_t error) {});
}

- (void)dropConnection {
    if (!_connections.lastObject) return;
    nw_connection_force_cancel(_connections.lastObject);
    [_connections removeLastObject];
}

- (void)stop {
    for (nw_connection_t connection in _connections) nw_connection_force_cancel(connection);
    [_connections removeAllObjects];
    nw_listener_cancel(_listener);
}

@end
