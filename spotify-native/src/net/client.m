// Pathfinder GraphQL and spclient REST transport.
#import "net/client.h"
#import "model/json.h"

NSString *const SPNetErrorDomain = @"local.spotify-native.net";

static NSString *const kSPAppPlatform = @"OSX_ARM64";
static NSString *const kSPOrigin = @"https://xpui.app.spotify.com";

static NSError *NetError(SPNetErrorCode code, NSString *msg) {
    return [NSError errorWithDomain:SPNetErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey : msg ?: @"Network error"}];
}

@implementation SPCancelToken {
    BOOL _cancelled;
    NSURLSessionTask *_task;
}

- (BOOL)isCancelled {
    @synchronized(self) { return _cancelled; }
}

- (void)attachTask:(NSURLSessionTask *)task {
    BOOL shouldCancel = NO;
    @synchronized(self) {
        _task = task;
        shouldCancel = _cancelled;
    }
    if (shouldCancel) [task cancel];
}

- (void)cancel {
    NSURLSessionTask *t = nil;
    @synchronized(self) {
        if (_cancelled) return;
        _cancelled = YES;
        t = _task;
        _task = nil;
    }
    [t cancel];
}

@end

@implementation SPNetClient

- (instancetype)initWithAuth:(SPAuth *)auth {
    return [self initWithAuth:auth urlSession:nil];
}

- (instancetype)initWithAuth:(SPAuth *)auth urlSession:(NSURLSession *)urlSession {
    if (!(self = [super init])) return nil;
    _auth = auth;
    _pathfinderURL = [NSURL URLWithString:@"https://api-partner.spotify.com/pathfinder/v2/query"];
    _spclientBaseURL = [NSURL URLWithString:@"https://spclient.wg.spotify.com"];
    _seektableBaseURL = [NSURL URLWithString:@"https://seektables.spotifycdn.com"];
    _retryDelays = @[ @1.0, @3.0 ];

    if (urlSession) {
        _urlSession = urlSession;
    } else {
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        cfg.URLCache = nil;
        cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        cfg.timeoutIntervalForRequest = 20.0;
        _urlSession = [NSURLSession sessionWithConfiguration:cfg];
    }
    return self;
}

#pragma mark - Signed Transport with Retries

static BOOL IsPassingError(NSError *err) {
    if (!err || ![err.domain isEqualToString:NSURLErrorDomain]) return NO;
    return err.code == NSURLErrorNetworkConnectionLost || err.code == NSURLErrorCannotConnectToHost;
}

- (void)executeOnceRequest:(NSURLRequest *)baseRequest
                     token:(SPCancelToken *)cancelToken
                completion:(void (^)(NSData *data, NSHTTPURLResponse *http, NSString *usedClientToken, NSError *err))completion {
    if (cancelToken.isCancelled) {
        completion(nil, nil, nil, NetError(SPNetErrorCancelled, @"Cancelled"));
        return;
    }
    [_auth accessTokenWithCompletion:^(NSString *bearer, NSError *bearerErr) {
        if (cancelToken.isCancelled) { completion(nil, nil, nil, NetError(SPNetErrorCancelled, @"Cancelled")); return; }
        if (bearerErr || !bearer.length) { completion(nil, nil, nil, bearerErr); return; }

        [self->_auth clientTokenWithCompletion:^(NSString *ct, NSError *ctErr) {
            if (cancelToken.isCancelled) { completion(nil, nil, nil, NetError(SPNetErrorCancelled, @"Cancelled")); return; }
            if (ctErr || !ct.length) { completion(nil, nil, nil, ctErr); return; }

            NSMutableURLRequest *signedReq = [baseRequest mutableCopy];
            [signedReq setValue:kSPAppPlatform forHTTPHeaderField:@"App-Platform"];
            if (![signedReq valueForHTTPHeaderField:@"Origin"]) [signedReq setValue:kSPOrigin forHTTPHeaderField:@"Origin"];
            if (![signedReq valueForHTTPHeaderField:@"Referer"]) [signedReq setValue:kSPOrigin forHTTPHeaderField:@"Referer"];
            [signedReq setValue:[NSString stringWithFormat:@"Bearer %@", bearer] forHTTPHeaderField:@"Authorization"];
            [signedReq setValue:ct forHTTPHeaderField:@"Client-Token"];

            NSURLSessionDataTask *task = [self->_urlSession dataTaskWithRequest:signedReq
                                                              completionHandler:^(NSData *data, NSURLResponse *resp, NSError *netErr) {
                NSHTTPURLResponse *http = [resp isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)resp : nil;
                completion(data, http, ct, netErr);
            }];
            [cancelToken attachTask:task];
            if (!cancelToken.isCancelled) [task resume];
        }];
    }];
}

- (void)executeWithTokenRetry:(NSURLRequest *)baseRequest
                        token:(SPCancelToken *)cancelToken
                   completion:(void (^)(NSData *data, NSHTTPURLResponse *http, NSError *err))completion {
    [self executeOnceRequest:baseRequest token:cancelToken completion:^(NSData *data, NSHTTPURLResponse *http, NSString *usedCT, NSError *err) {
        if (err || !http || cancelToken.isCancelled) {
            completion(data, http, err);
            return;
        }
        NSString *ctError = [http valueForHTTPHeaderField:@"client-token-error"];
        BOOL refused = (http.statusCode == 401) || (ctError.length > 0 && (http.statusCode < 200 || http.statusCode >= 300));
        if (!refused) {
            completion(data, http, nil);
            return;
        }
        [self->_auth invalidateClientTokenIfMatching:usedCT];
        [self executeOnceRequest:baseRequest token:cancelToken completion:^(NSData *d2, NSHTTPURLResponse *h2, NSString *ct2, NSError *e2) {
            (void)ct2;
            completion(d2, h2, e2);
        }];
    }];
}

- (void)executeAttempt:(NSUInteger)attempt
               request:(NSURLRequest *)baseRequest
            retryReads:(BOOL)retryReads
                 token:(SPCancelToken *)cancelToken
            completion:(void (^)(NSData *data, NSHTTPURLResponse *http, NSError *err))completion {
    [self executeWithTokenRetry:baseRequest token:cancelToken completion:^(NSData *data, NSHTTPURLResponse *http, NSError *err) {
        BOOL canRetry = retryReads && !cancelToken.isCancelled && attempt < self.retryDelays.count &&
                        ((http && http.statusCode >= 500 && http.statusCode <= 599) || IsPassingError(err));
        if (!canRetry) {
            completion(data, http, err);
            return;
        }
        NSTimeInterval delay = self.retryDelays[attempt].doubleValue;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            if (cancelToken.isCancelled) {
                completion(nil, nil, NetError(SPNetErrorCancelled, @"Cancelled"));
                return;
            }
            [self executeAttempt:attempt + 1 request:baseRequest retryReads:retryReads token:cancelToken completion:completion];
        });
    }];
}

- (SPCancelToken *)sendSignedRequest:(NSURLRequest *)request
                          retryReads:(BOOL)retryReads
                          completion:(void (^)(NSData *, NSHTTPURLResponse *, NSError *))completion {
    SPCancelToken *token = [SPCancelToken new];
    [self executeAttempt:0 request:request retryReads:retryReads token:token completion:completion];
    return token;
}

#pragma mark - Pathfinder GraphQL

- (SPCancelToken *)queryPathfinder:(SPPathfinderOp)op
                         variables:(NSDictionary *)variables
                        completion:(void (^)(NSDictionary *, NSError *))completion {
    NSString *opName = @(op.name);
    NSDictionary *payload = @{
        @"operationName" : opName,
        @"variables" : variables ?: @{},
        @"extensions" : @{
            @"persistedQuery" : @{
                @"version" : @1,
                @"sha256Hash" : @(op.sha256),
            },
        },
    };
    NSError *encErr = nil;
    NSData *body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&encErr];
    if (!body) {
        if (completion) completion(nil, encErr);
        return [SPCancelToken new];
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:self.pathfinderURL];
    req.HTTPMethod = @"POST";
    req.HTTPBody = body;
    [req setValue:@"application/json;charset=UTF-8" forHTTPHeaderField:@"Content-Type"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];

    return [self sendSignedRequest:req retryReads:op.retryPassingFailures completion:^(NSData *data, NSHTTPURLResponse *http, NSError *err) {
        if (err) { completion(nil, err); return; }
        if (!http || http.statusCode != 200) {
            NSString *detail = data.length ? [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(0, MIN(data.length, (NSUInteger)500))] encoding:NSUTF8StringEncoding] : @"";
            completion(nil, NetError(SPNetErrorHTTPStatus, [NSString stringWithFormat:@"%@ failed HTTP %ld: %@", opName, (long)(http ? http.statusCode : -1), detail ?: @""]));
            return;
        }
        NSDictionary *json = data.length ? SPJSONDict([NSJSONSerialization JSONObjectWithData:data options:0 error:nil]) : nil;
        if (!json) {
            completion(nil, NetError(SPNetErrorMalformedResponse, [NSString stringWithFormat:@"Malformed JSON for %@", opName]));
            return;
        }
        NSArray *errors = SPJSONArray(json[@"errors"]);
        if (errors.count > 0) {
            NSMutableArray<NSString *> *msgs = [NSMutableArray arrayWithCapacity:errors.count];
            BOOL retired = NO;
            for (id raw in errors) {
                NSDictionary *e = SPJSONDict(raw);
                NSString *m = SPJSONString(e[@"message"]);
                NSString *code = SPJSONString(SPJSONDict(e[@"extensions"])[@"code"]);
                if ([code isEqualToString:@"PERSISTED_QUERY_NOT_FOUND"] ||
                    (m && [m rangeOfString:@"persistedquerynotfound" options:NSCaseInsensitiveSearch].location != NSNotFound)) {
                    retired = YES;
                }
                if (m.length) [msgs addObject:m];
            }
            if (retired) {
                completion(nil, NetError(SPNetErrorPersistedQueryNotFound, [NSString stringWithFormat:@"PersistedQueryNotFound for %@", opName]));
            } else {
                completion(nil, NetError(SPNetErrorGraphQL, [msgs componentsJoinedByString:@"; "]));
            }
            return;
        }
        completion(json, nil);
    }];
}

- (SPCancelToken *)fetchHomeWithCompletion:(void (^)(SPHomePage *, NSError *))completion {
    NSDictionary *vars = @{
        @"timeZone" : NSTimeZone.localTimeZone.name ?: @"UTC",
        @"homeEndUserIntegration" : @"INTEGRATION_WEB_PLAYER",
        @"sp_t" : self.auth.deviceID ?: @"",
    };
    return [self queryPathfinder:SPPathfinderOpHome variables:vars completion:^(NSDictionary *json, NSError *err) {
        if (err) { completion(nil, err); return; }
        NSError *parseErr = nil;
        SPHomePage *page = [SPHomePage homePageFromPathfinderJSON:json errorOut:&parseErr];
        completion(page, parseErr);
    }];
}

- (SPCancelToken *)fetchProfileWithCompletion:(void (^)(SPUserProfile *, NSError *))completion {
    return [self queryPathfinder:SPPathfinderOpProfileAttributes variables:@{} completion:^(NSDictionary *json, NSError *err) {
        if (err) { completion(nil, err); return; }
        SPUserProfile *prof = [SPUserProfile profileFromPathfinderJSON:json];
        completion(prof, prof ? nil : NetError(SPNetErrorMalformedResponse, @"Missing profile"));
    }];
}

- (SPCancelToken *)fetchLikedSongsOffset:(NSInteger)offset
                                   limit:(NSInteger)limit
                              completion:(void (^)(NSArray<SPTrack *> *, NSArray<SPPlaylistItem *> *, NSInteger, NSInteger, NSError *))completion {
    NSDictionary *vars = @{
        @"uri" : SPLikedSongsPlaylistURI,
        @"offset" : @(MAX(0, offset)),
        @"limit" : @(limit > 0 ? limit : 50),
        @"enableWatchFeedEntrypoint" : @NO,
    };
    return [self queryPathfinder:SPPathfinderOpFetchPlaylistContents variables:vars completion:^(NSDictionary *json, NSError *err) {
        if (err) { completion(nil, nil, 0, 0, err); return; }
        NSDictionary *unionDict = SPJSONDict(SPJSONDict(json[@"data"])[@"playlistV2"]);
        NSArray<SPPlaylistItem *> *items = nil;
        NSInteger total = 0, rawCount = 0;
        NSArray<SPTrack *> *tracks = [SPPlaylist tracksFromPathfinderContentsUnion:unionDict
                                                                          itemsOut:&items
                                                                          totalOut:&total
                                                                       rawCountOut:&rawCount];
        completion(tracks, items, total, rawCount, nil);
    }];
}

- (SPCancelToken *)fetchLibraryFilter:(NSString *)filter
                               offset:(NSInteger)offset
                                limit:(NSInteger)limit
                                order:(NSString *)order
                           completion:(void (^)(NSDictionary *, NSError *))completion {
    NSMutableDictionary *vars = [@{
        @"filters" : @[ filter ?: @"Playlists" ],
        @"offset" : @(MAX(0, offset)),
        @"limit" : @(limit > 0 ? limit : 50),
        @"textFilter" : @"",
        @"flatten" : @YES,
        @"expandedFolders" : @[],
        @"includeFoldersWhenFlattening" : @NO,
    } mutableCopy];
    if (order.length) vars[@"order"] = order;
    return [self queryPathfinder:SPPathfinderOpLibraryV3 variables:vars completion:^(NSDictionary *json, NSError *err) {
        if (err) { completion(nil, err); return; }
        NSDictionary *lib = SPJSONDict(SPJSONDict(SPJSONDict(json[@"data"])[@"me"])[@"libraryV3"]);
        completion(lib, lib ? nil : NetError(SPNetErrorMalformedResponse, @"Missing libraryV3"));
    }];
}

- (SPCancelToken *)fetchAlbumWithID:(NSString *)albumID
                         completion:(void (^)(SPAlbum *, NSArray<SPTrack *> *, NSError *))completion {
    NSDictionary *vars = @{
        @"uri" : [NSString stringWithFormat:@"spotify:album:%@", albumID],
        @"locale" : @"",
        @"offset" : @0,
        @"limit" : @300,
    };
    return [self queryPathfinder:SPPathfinderOpGetAlbum variables:vars completion:^(NSDictionary *json, NSError *err) {
        if (err) { completion(nil, nil, err); return; }
        NSDictionary *u = SPJSONDict(SPJSONDict(json[@"data"])[@"albumUnion"]);
        NSArray<SPTrack *> *tracks = nil;
        NSError *parseErr = nil;
        SPAlbum *album = [SPAlbum albumFromPathfinderUnion:u tracksOut:&tracks errorOut:&parseErr];
        completion(album, tracks, parseErr);
    }];
}

- (SPCancelToken *)fetchArtistOverviewWithID:(NSString *)artistID
                                  completion:(void (^)(SPArtist *, NSArray<SPAlbum *> *, NSError *))completion {
    return [self fetchArtistOverviewWithID:artistID fullCompletion:^(SPArtist *artist, NSArray<SPAlbum *> *albums, NSArray<SPTrack *> *topTracks, NSError *err) {
        (void)topTracks;
        if (completion) completion(artist, albums, err);
    }];
}

- (SPCancelToken *)fetchArtistOverviewWithID:(NSString *)artistID
                              fullCompletion:(void (^)(SPArtist *, NSArray<SPAlbum *> *, NSArray<SPTrack *> *, NSError *))completion {
    NSDictionary *vars = @{
        @"uri" : [NSString stringWithFormat:@"spotify:artist:%@", artistID],
        @"locale" : @"",
        @"offset" : @0,
        @"limit" : @100,
    };
    return [self queryPathfinder:SPPathfinderOpQueryArtistOverview variables:vars completion:^(NSDictionary *json, NSError *err) {
        if (err) { completion(nil, nil, nil, err); return; }
        NSDictionary *u = SPJSONDict(SPJSONDict(json[@"data"])[@"artistUnion"]);
        NSArray<SPAlbum *> *albums = nil;
        NSArray<SPTrack *> *topTracks = nil;
        NSError *parseErr = nil;
        SPArtist *artist = [SPArtist artistFromPathfinderUnion:u albumsOut:&albums topTracksOut:&topTracks errorOut:&parseErr];
        completion(artist, albums, topTracks, parseErr);
    }];
}

- (SPCancelToken *)fetchArtistDiscographyWithID:(NSString *)artistID
                                         offset:(NSInteger)offset
                                          limit:(NSInteger)limit
                                     completion:(void (^)(SPArtist *, NSArray<SPAlbum *> *, NSError *))completion {
    NSDictionary *vars = @{
        @"uri" : [NSString stringWithFormat:@"spotify:artist:%@", artistID],
        @"locale" : @"",
        @"offset" : @(MAX(0, offset)),
        @"limit" : @(limit > 0 ? limit : 100),
    };
    return [self queryPathfinder:SPPathfinderOpQueryArtistDiscographyAll variables:vars completion:^(NSDictionary *json, NSError *err) {
        if (err) { completion(nil, nil, err); return; }
        NSDictionary *u = SPJSONDict(SPJSONDict(json[@"data"])[@"artistUnion"]);
        NSArray<SPAlbum *> *albums = nil;
        NSError *parseErr = nil;
        SPArtist *artist = [SPArtist artistFromPathfinderUnion:u albumsOut:&albums errorOut:&parseErr];
        completion(artist, albums, parseErr);
    }];
}

- (SPCancelToken *)fetchPlaylistWithID:(NSString *)playlistID
                                offset:(NSInteger)offset
                                 limit:(NSInteger)limit
                            completion:(void (^)(SPPlaylist *, NSArray<SPTrack *> *, NSError *))completion {
    NSDictionary *vars = @{
        @"uri" : [NSString stringWithFormat:@"spotify:playlist:%@", playlistID],
        @"offset" : @(MAX(0, offset)),
        @"limit" : @(limit > 0 ? limit : 300),
        @"enableWatchFeedEntrypoint" : @NO,
    };
    return [self queryPathfinder:SPPathfinderOpFetchPlaylist variables:vars completion:^(NSDictionary *json, NSError *err) {
        if (err) { completion(nil, nil, err); return; }
        NSDictionary *u = SPJSONDict(SPJSONDict(json[@"data"])[@"playlistV2"]);
        NSArray<SPTrack *> *tracks = nil;
        NSError *parseErr = nil;
        SPPlaylist *pl = [SPPlaylist playlistFromPathfinderUnion:u tracksOut:&tracks errorOut:&parseErr];
        completion(pl, tracks, parseErr);
    }];
}

- (SPCancelToken *)checkEntitiesInLibrary:(NSArray<NSString *> *)uris
                               completion:(void (^)(NSDictionary<NSString *, NSNumber *> *, NSError *))completion {
    return [self queryPathfinder:SPPathfinderOpAreEntitiesInLibrary
                       variables:@{@"uris" : uris ?: @[]}
                      completion:^(NSDictionary *json, NSError *err) {
        if (err) { completion(nil, err); return; }
        NSArray *lookup = SPJSONArray(SPJSONDict(json[@"data"])[@"lookup"]);
        NSMutableDictionary<NSString *, NSNumber *> *statuses = [NSMutableDictionary dictionaryWithCapacity:MIN(uris.count, lookup.count)];
        NSUInteger count = MIN(uris.count, lookup.count);
        for (NSUInteger i = 0; i < count; i++) {
            NSString *eid = SPURIIDFromURI(uris[i]);
            if (!eid.length) continue;
            NSDictionary *entry = SPJSONDict(lookup[i]);
            BOOL saved = SPJSONBool(SPJSONDict(entry[@"data"])[@"saved"], NO);
            statuses[eid] = @(saved);
        }
        completion(statuses, nil);
    }];
}

- (SPCancelToken *)mutateLibraryOp:(SPPathfinderOp)op
                              uris:(NSArray<NSString *> *)uris
                     responseField:(NSString *)responseField
                      expectedType:(NSString *)expectedType
                        completion:(void (^)(NSError *))completion {
    return [self queryPathfinder:op
                       variables:@{@"libraryItemUris" : uris ?: @[]}
                      completion:^(NSDictionary *json, NSError *err) {
        if (err) { completion(err); return; }
        NSDictionary *res = SPJSONDict(SPJSONDict(json[@"data"])[responseField]);
        NSString *tn = SPJSONString(res[@"__typename"]);
        if ([tn isEqualToString:expectedType]) {
            completion(nil);
        } else {
            NSString *msg = SPJSONString(res[@"message"]) ?: tn ?: @"Missing mutation response";
            completion(NetError(SPNetErrorMutationRejected, msg));
        }
    }];
}

- (SPCancelToken *)addToLibraryURIs:(NSArray<NSString *> *)uris completion:(void (^)(NSError *))completion {
    return [self mutateLibraryOp:SPPathfinderOpAddToLibrary uris:uris responseField:@"addLibraryItems" expectedType:@"AddLibraryItemsResponse" completion:completion];
}

- (SPCancelToken *)removeFromLibraryURIs:(NSArray<NSString *> *)uris completion:(void (^)(NSError *))completion {
    return [self mutateLibraryOp:SPPathfinderOpRemoveFromLibrary uris:uris responseField:@"removeLibraryItems" expectedType:@"RemoveLibraryItemsResponse" completion:completion];
}

#pragma mark - Search

- (SPCancelToken *)searchDesktop:(NSString *)query
                          offset:(NSInteger)offset
                           limit:(NSInteger)limit
                      completion:(void (^)(SPSearchResults *, NSError *))completion {
    NSDictionary *vars = @{
        @"searchTerm" : query ?: @"",
        @"offset" : @(MAX(0, offset)),
        @"limit" : @(limit > 0 ? limit : 10),
        @"numberOfTopResults" : @5,
        @"includeAudiobooks" : @YES,
        @"includeArtistHasConcertsField" : @NO,
        @"includePreReleases" : @YES,
        @"includeAlbumPreReleases" : @NO,
        @"includeAuthors" : @NO,
        @"includeEpisodeContentRatingsV2" : @NO,
        @"isPrefix" : NSNull.null,
        @"sectionFilters" : @[ @"GENERIC" ],
    };
    return [self queryPathfinder:SPPathfinderOpSearchDesktop variables:vars completion:^(NSDictionary *json, NSError *err) {
        if (err) { completion(nil, err); return; }
        completion([SPSearchResults resultsFromSearchDesktopJSON:json query:query], nil);
    }];
}

- (SPCancelToken *)searchSuggestions:(NSString *)query
                               limit:(NSInteger)limit
                          completion:(void (^)(NSArray<SPSearchSuggestion *> *, NSError *))completion {
    NSDictionary *vars = @{
        @"query" : query ?: @"",
        @"limit" : @(limit > 0 ? limit : 20),
        @"numberOfTopResults" : @(limit > 0 ? limit : 20),
        @"offset" : @0,
        @"includeAuthors" : @NO,
        @"includeAlbumPreReleases" : @NO,
        @"includeEpisodeContentRatingsV2" : @NO,
    };
    return [self queryPathfinder:SPPathfinderOpSearchSuggestions variables:vars completion:^(NSDictionary *json, NSError *err) {
        if (err) { completion(nil, err); return; }
        completion([SPSearchResults suggestionsFromSearchSuggestionsJSON:json], nil);
    }];
}

- (SPCancelToken *)searchCategory:(SPSearchCategory)category
                            query:(NSString *)query
                           offset:(NSInteger)offset
                            limit:(NSInteger)limit
                       completion:(void (^)(NSDictionary *, NSError *))completion {
    SPPathfinderOp op = SPPathfinderOpSearchTracks;
    switch (category) {
        case SPSearchCategoryTracks: op = SPPathfinderOpSearchTracks; break;
        case SPSearchCategoryAlbums: op = SPPathfinderOpSearchAlbums; break;
        case SPSearchCategoryArtists: op = SPPathfinderOpSearchArtists; break;
        case SPSearchCategoryPlaylists: op = SPPathfinderOpSearchPlaylists; break;
    }
    NSDictionary *vars = @{
        @"searchTerm" : query ?: @"",
        @"offset" : @(MAX(0, offset)),
        @"limit" : @(limit > 0 ? limit : 20),
        @"numberOfTopResults" : @20,
        @"includePreReleases" : @YES,
        @"includeArtistHasConcertsField" : @NO,
        @"includeAudiobooks" : @YES,
        @"includeAuthors" : @YES,
        @"includeEpisodeContentRatingsV2" : @NO,
    };
    return [self queryPathfinder:op variables:vars completion:completion];
}

#pragma mark - spclient REST Helpers

- (NSURL *)spclientURLForPath:(NSString *)path {
    NSString *trimmed = [path hasPrefix:@"/"] ? [path substringFromIndex:1] : path;
    return [NSURL URLWithString:trimmed relativeToURL:[self.spclientBaseURL URLByAppendingPathComponent:@""]].absoluteURL;
}

- (void)sendPreflightForURL:(NSURL *)url
                      token:(SPCancelToken *)token
                 completion:(void (^)(NSError *_Nullable error))completion {
    if (token.isCancelled) { completion(NetError(SPNetErrorCancelled, @"Cancelled")); return; }
    NSMutableURLRequest *opt = [NSMutableURLRequest requestWithURL:url];
    opt.HTTPMethod = @"OPTIONS";
    [opt setValue:@"*/*" forHTTPHeaderField:@"Accept"];
    [opt setValue:@"GET" forHTTPHeaderField:@"Access-Control-Request-Method"];
    [opt setValue:@"app-platform,authorization,client-token,spotify-app-version"
        forHTTPHeaderField:@"Access-Control-Request-Headers"];
    [opt setValue:kSPOrigin forHTTPHeaderField:@"Origin"];
    [opt setValue:[kSPOrigin stringByAppendingString:@"/"] forHTTPHeaderField:@"Referer"];

    NSURLSessionDataTask *task = [_urlSession dataTaskWithRequest:opt
                                                completionHandler:^(NSData *data, NSURLResponse *resp, NSError *netErr) {
        (void)data;
        if (netErr) { completion(netErr); return; }
        NSHTTPURLResponse *http = [resp isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)resp : nil;
        if (!http || http.statusCode < 200 || http.statusCode >= 300) {
            completion(NetError(SPNetErrorHTTPStatus,
                                [NSString stringWithFormat:@"metadata/4 OPTIONS preflight HTTP %ld", (long)(http ? http.statusCode : -1)]));
            return;
        }
        completion(nil);
    }];
    [token attachTask:task];
    if (!token.isCancelled) [task resume];
}

- (SPCancelToken *)fetchTrackMetadataWithID:(NSString *)trackID
                                 completion:(void (^)(NSDictionary *, SPTrack *, NSError *))completion {
    NSString *gid = SPBase62ToHexGID(trackID);
    if (!gid) {
        completion(nil, nil, NetError(SPNetErrorInvalidID, @"Invalid Spotify base62 track id"));
        return [SPCancelToken new];
    }
    NSURL *url = [self spclientURLForPath:[NSString stringWithFormat:@"metadata/4/track/%@?market=from_token", gid]];
    SPCancelToken *token = [SPCancelToken new];
    [self sendPreflightForURL:url token:token completion:^(NSError *preErr) {
        if (preErr) { completion(nil, nil, preErr); return; }
        if (token.isCancelled) { completion(nil, nil, NetError(SPNetErrorCancelled, @"Cancelled")); return; }
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
        [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];
        [self executeAttempt:0 request:req retryReads:YES token:token completion:^(NSData *data, NSHTTPURLResponse *http, NSError *err) {
            if (err) { completion(nil, nil, err); return; }
            if (!http || http.statusCode != 200) {
                completion(nil, nil, NetError(SPNetErrorHTTPStatus, [NSString stringWithFormat:@"metadata/4 HTTP %ld", (long)(http ? http.statusCode : -1)]));
                return;
            }
            NSDictionary *raw = data.length ? SPJSONDict([NSJSONSerialization JSONObjectWithData:data options:0 error:nil]) : nil;
            if (!raw) { completion(nil, nil, NetError(SPNetErrorMalformedResponse, @"Invalid metadata/4 JSON")); return; }
            SPTrack *track = [SPTrack trackFromSpclientDict:raw requestedID:trackID];
            completion(raw, track, nil);
        }];
    }];
    return token;
}

static NSString *NextContextPagePath(NSString *nextURL) {
    if ([nextURL hasPrefix:@"hm://"]) {
        return [@"/" stringByAppendingString:[nextURL substringFromIndex:5]];
    }
    return [@"/context-resolve/v1/" stringByAppendingString:nextURL];
}

- (void)fetchContextPagePath:(NSString *)path
              remainingPages:(NSInteger)remaining
                 accumulated:(NSMutableArray<NSString *> *)acc
                       token:(SPCancelToken *)token
                  completion:(void (^)(NSArray<NSString *> *, NSString *, NSError *))completion {
    NSURL *url = [self spclientURLForPath:path];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    [req setValue:@"application/x-protobuf" forHTTPHeaderField:@"Accept"];

    [self executeAttempt:0 request:req retryReads:YES token:token completion:^(NSData *data, NSHTTPURLResponse *http, NSError *err) {
        if (err || !http || http.statusCode != 200) {
            if (acc.count > 0) {
                completion([acc copy], nil, nil);
            } else {
                NSError *outErr = err ?: NetError(SPNetErrorHTTPStatus, [NSString stringWithFormat:@"context-resolve HTTP %ld", (long)(http ? http.statusCode : -1)]);
                completion(nil, nil, outErr);
            }
            return;
        }
        NSDictionary *json = data.length ? SPJSONDict([NSJSONSerialization JSONObjectWithData:data options:0 error:nil]) : nil;
        NSArray *pages = SPJSONArray(json[@"pages"]) ?: (json ? @[ json ] : @[]);
        NSString *nextPage = nil;
        for (id rawPage in pages) {
            NSDictionary *p = SPJSONDict(rawPage);
            for (id rawTr in SPJSONArray(p[@"tracks"])) {
                NSString *uri = SPJSONString(SPJSONDict(rawTr)[@"uri"]);
                if (uri.length) [acc addObject:uri];
            }
            if (!nextPage) {
                NSString *np = SPJSONString(p[@"next_page_url"]);
                if (np.length) nextPage = np;
            }
        }
        if (nextPage.length && remaining > 1 && !token.isCancelled) {
            [self fetchContextPagePath:NextContextPagePath(nextPage) remainingPages:remaining - 1 accumulated:acc token:token completion:completion];
        } else {
            completion([acc copy], nextPage, nil);
        }
    }];
}

- (SPCancelToken *)resolveContextURI:(NSString *)contextURI
                            deviceID:(NSString *)deviceID
                            maxPages:(NSInteger)maxPages
                          completion:(void (^)(NSArray<NSString *> *, NSString *, NSError *))completion {
    NSString *encoded = [contextURI stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet] ?: contextURI;
    NSString *path = [NSString stringWithFormat:@"/context-resolve/v1/%@?device_id=%@", encoded, deviceID ?: self.auth.deviceID ?: @""];
    SPCancelToken *token = [SPCancelToken new];
    [self fetchContextPagePath:path remainingPages:MAX(1, maxPages) accumulated:[NSMutableArray new] token:token completion:completion];
    return token;
}

- (SPCancelToken *)fetchRadioSeedForTrackURI:(NSString *)trackURI
                                    deviceID:(NSString *)deviceID
                                  completion:(void (^)(NSArray<NSString *> *, NSError *))completion {
    NSString *tid = SPURITrackIDFromString(trackURI);
    if (!tid.length) {
        completion(nil, NetError(SPNetErrorInvalidID, @"Invalid track URI for radio seed"));
        return [SPCancelToken new];
    }
    NSString *station = [NSString stringWithFormat:@"spotify:station:track:%@", tid];
    return [self resolveContextURI:station deviceID:deviceID maxPages:1 completion:^(NSArray<NSString *> *tracks, NSString *next, NSError *err) {
        (void)next;
        completion(tracks, err);
    }];
}

- (SPCancelToken *)sendPlaylistV2Path:(NSString *)path
                                 body:(NSDictionary *)bodyDict
                           completion:(void (^)(NSData *, NSError *))completion {
    NSData *body = [NSJSONSerialization dataWithJSONObject:bodyDict options:0 error:nil];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[self spclientURLForPath:path]];
    req.HTTPMethod = @"POST";
    req.HTTPBody = body;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    return [self sendSignedRequest:req retryReads:NO completion:^(NSData *data, NSHTTPURLResponse *http, NSError *err) {
        if (err) { completion(nil, err); return; }
        if (!http || http.statusCode < 200 || http.statusCode >= 300) {
            completion(nil, NetError(SPNetErrorHTTPStatus, [NSString stringWithFormat:@"playlist/v2 HTTP %ld", (long)(http ? http.statusCode : -1)]));
            return;
        }
        completion(data, nil);
    }];
}

- (SPCancelToken *)createPlaylistWithName:(NSString *)name
                              description:(NSString *)description
                               completion:(void (^)(NSString *, NSError *))completion {
    NSMutableDictionary *vals = [@{@"name" : name ?: @""} mutableCopy];
    if (description) vals[@"description"] = description;
    NSDictionary *body = @{
        @"ops" : @[ @{
            @"kind" : @"UPDATE_LIST_ATTRIBUTES",
            @"updateListAttributes" : @{@"newAttributes" : @{@"values" : vals}},
        } ],
    };
    return [self sendPlaylistV2Path:@"playlist/v2/playlist" body:body completion:^(NSData *data, NSError *err) {
        if (err) { completion(nil, err); return; }
        NSDictionary *json = data.length ? SPJSONDict([NSJSONSerialization JSONObjectWithData:data options:0 error:nil]) : nil;
        NSString *pid = SPURIIDFromURIOfKind(SPJSONString(json[@"uri"]), @"playlist");
        completion(pid, pid ? nil : NetError(SPNetErrorMalformedResponse, @"Missing created playlist URI"));
    }];
}

- (SPCancelToken *)updatePlaylistID:(NSString *)playlistID
                               name:(NSString *)name
                        description:(NSString *)description
                         completion:(void (^)(NSError *))completion {
    NSMutableDictionary *vals = [NSMutableDictionary new];
    if (name) vals[@"name"] = name;
    if (description) vals[@"description"] = description;
    NSDictionary *op = @{
        @"kind" : @"UPDATE_LIST_ATTRIBUTES",
        @"updateListAttributes" : @{@"newAttributes" : @{@"values" : vals}},
    };
    NSDictionary *body = @{
        @"deltas" : @[ @{@"ops" : @[ op ], @"info" : @{@"source" : @{@"client" : @"WEBPLAYER"}}} ],
    };
    return [self sendPlaylistV2Path:[NSString stringWithFormat:@"playlist/v2/playlist/%@/changes", playlistID]
                               body:body
                         completion:^(NSData *data, NSError *err) { (void)data; completion(err); }];
}

- (SPCancelToken *)addPlaylistID:(NSString *)playlistID
           toRootlistForUsername:(NSString *)username
                      completion:(void (^)(NSError *))completion {
    int64_t tsMs = (int64_t)llround(NSDate.date.timeIntervalSince1970 * 1000.0);
    NSDictionary *op = @{
        @"kind" : @"ADD",
        @"add" : @{
            @"addFirst" : @YES,
            @"items" : @[ @{
                @"uri" : [NSString stringWithFormat:@"spotify:playlist:%@", playlistID],
                @"attributes" : @{@"timestamp" : [NSString stringWithFormat:@"%lld", (long long)tsMs]},
            } ],
        },
    };
    NSDictionary *body = @{
        @"deltas" : @[ @{@"ops" : @[ op ], @"info" : @{@"source" : @{@"client" : @"WEBPLAYER"}}} ],
    };
    return [self sendPlaylistV2Path:[NSString stringWithFormat:@"playlist/v2/user/%@/rootlist/changes", username]
                               body:body
                         completion:^(NSData *data, NSError *err) { (void)data; completion(err); }];
}

- (SPCancelToken *)removePlaylistID:(NSString *)playlistID
            fromRootlistForUsername:(NSString *)username
                         completion:(void (^)(NSError *))completion {
    NSDictionary *op = @{
        @"kind" : @"REM",
        @"rem" : @{
            @"itemsAsKey" : @YES,
            @"items" : @[ @{@"uri" : [NSString stringWithFormat:@"spotify:playlist:%@", playlistID]} ],
        },
    };
    NSDictionary *body = @{
        @"deltas" : @[ @{@"ops" : @[ op ], @"info" : @{@"source" : @{@"client" : @"WEBPLAYER"}}} ],
    };
    return [self sendPlaylistV2Path:[NSString stringWithFormat:@"playlist/v2/user/%@/rootlist/changes", username]
                               body:body
                         completion:^(NSData *data, NSError *err) { (void)data; completion(err); }];
}

- (SPCancelToken *)addTrackURIs:(NSArray<NSString *> *)trackURIs
                   toPlaylistID:(NSString *)playlistID
                     completion:(void (^)(NSError *))completion {
    if (!trackURIs.count || !playlistID.length) {
        if (completion) completion(NetError(SPNetErrorInvalidID, @"Missing playlistID or trackURIs"));
        return [SPCancelToken new];
    }
    int64_t tsMs = (int64_t)llround(NSDate.date.timeIntervalSince1970 * 1000.0);
    NSMutableArray *items = [NSMutableArray arrayWithCapacity:trackURIs.count];
    for (NSString *uri in trackURIs) {
        if (!uri.length) continue;
        [items addObject:@{
            @"uri" : uri,
            @"attributes" : @{@"timestamp" : [NSString stringWithFormat:@"%lld", (long long)tsMs]},
        }];
    }
    NSDictionary *op = @{
        @"kind" : @"ADD",
        @"add" : @{@"addLast" : @YES, @"items" : items},
    };
    NSDictionary *body = @{
        @"deltas" : @[ @{@"ops" : @[ op ], @"info" : @{@"source" : @{@"client" : @"WEBPLAYER"}}} ],
    };
    return [self sendPlaylistV2Path:[NSString stringWithFormat:@"playlist/v2/playlist/%@/changes", playlistID]
                               body:body
                         completion:^(NSData *data, NSError *err) { (void)data; if (completion) completion(err); }];
}

- (SPCancelToken *)removeTrackURI:(NSString *)trackURI
                          atIndex:(NSInteger)index
                              uid:(NSString *)uid
                   fromPlaylistID:(NSString *)playlistID
                       completion:(void (^)(NSError *))completion {
    (void)uid;
    if (!trackURI.length || !playlistID.length) {
        if (completion) completion(NetError(SPNetErrorInvalidID, @"Missing playlistID or trackURI"));
        return [SPCancelToken new];
    }
    NSDictionary *rem = (index >= 0)
        ? @{
            @"fromIndex" : @(index),
            @"length" : @1,
            @"items" : @[ @{@"uri" : trackURI} ],
        }
        : @{
            @"itemsAsKey" : @YES,
            @"items" : @[ @{@"uri" : trackURI} ],
        };
    NSDictionary *op = @{
        @"kind" : @"REM",
        @"rem" : rem,
    };
    NSDictionary *body = @{
        @"deltas" : @[ @{@"ops" : @[ op ], @"info" : @{@"source" : @{@"client" : @"WEBPLAYER"}}} ],
    };
    return [self sendPlaylistV2Path:[NSString stringWithFormat:@"playlist/v2/playlist/%@/changes", playlistID]
                               body:body
                         completion:^(NSData *data, NSError *err) { (void)data; if (completion) completion(err); }];
}

#pragma mark - FairPlay Wire Helpers

- (SPCancelToken *)fetchTrackCBCSManifestForURI:(NSString *)trackURI
                                     completion:(void (^)(NSDictionary *, NSError *))completion {
    if (!trackURI.length) {
        completion(nil, NetError(SPNetErrorInvalidID, @"Missing track URI"));
        return [SPCancelToken new];
    }
    NSString *path = [NSString stringWithFormat:@"track-playback/v1/media/%@?manifestFileFormat=file_ids_mp4_cbcs", trackURI];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[self spclientURLForPath:path]];
    [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    return [self sendSignedRequest:req retryReads:YES completion:^(NSData *data, NSHTTPURLResponse *http, NSError *err) {
        if (err || !http || http.statusCode != 200 || !data.length) {
            completion(nil, err ?: NetError(SPNetErrorHTTPStatus, [NSString stringWithFormat:@"track-playback/v1/media HTTP %ld", (long)(http ? http.statusCode : -1)]));
            return;
        }
        NSDictionary *root = SPJSONDict([NSJSONSerialization JSONObjectWithData:data options:0 error:nil]);
        NSDictionary *mediaMap = SPJSONDict(root[@"media"]);
        NSDictionary *entry = SPJSONDict(mediaMap[trackURI]);
        if (!entry && mediaMap.count > 0) entry = SPJSONDict(mediaMap.allValues.firstObject);
        completion(entry, entry ? nil : NetError(SPNetErrorMalformedResponse, @"track-playback/v1/media missing entry"));
    }];
}

- (SPCancelToken *)fetchFairPlayCertificateWithCompletion:(void (^)(NSData *, NSError *))completion {
    NSURL *url = [self spclientURLForPath:@"fairplay-license/v1/application-certificate"];
    SPCancelToken *token = [SPCancelToken new];
    NSURLSessionDataTask *task = [_urlSession dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSHTTPURLResponse *http = [resp isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)resp : nil;
        if (err || !http || http.statusCode != 200 || !data.length) {
            completion(nil, err ?: NetError(SPNetErrorHTTPStatus, [NSString stringWithFormat:@"FairPlay cert HTTP %ld", (long)(http ? http.statusCode : -1)]));
            return;
        }
        completion(data, nil);
    }];
    [token attachTask:task];
    [task resume];
    return token;
}

- (SPCancelToken *)fetchSeektableForFileID:(NSString *)fileID completion:(void (^)(NSDictionary *, NSError *))completion {
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"v1/seektable/%@", fileID]
                        relativeToURL:[self.seektableBaseURL URLByAppendingPathComponent:@""]].absoluteURL;
    SPCancelToken *token = [SPCancelToken new];
    NSURLSessionDataTask *task = [_urlSession dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSHTTPURLResponse *http = [resp isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)resp : nil;
        if (err || !http || http.statusCode != 200 || !data.length) {
            completion(nil, err ?: NetError(SPNetErrorHTTPStatus, [NSString stringWithFormat:@"seektable HTTP %ld", (long)(http ? http.statusCode : -1)]));
            return;
        }
        NSDictionary *st = SPJSONDict([NSJSONSerialization JSONObjectWithData:data options:0 error:nil]);
        completion(st, st ? nil : NetError(SPNetErrorMalformedResponse, @"Invalid seektable JSON"));
    }];
    [token attachTask:task];
    [task resume];
    return token;
}

- (SPCancelToken *)resolveStorageForFileID:(NSString *)fileID
                                    format:(NSInteger)fileFormat
                                completion:(void (^)(NSString *, NSError *))completion {
    NSString *path = [NSString stringWithFormat:@"storage-resolve/v2/files/audio/interactive/%ld/%@?version=10000000&product=9&platform=39&alt=json",
                      (long)fileFormat, fileID];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[self spclientURLForPath:path]];
    [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    return [self sendSignedRequest:req retryReads:YES completion:^(NSData *data, NSHTTPURLResponse *http, NSError *err) {
        if (err || !http || http.statusCode != 200) {
            completion(nil, err ?: NetError(SPNetErrorHTTPStatus, [NSString stringWithFormat:@"storage-resolve HTTP %ld", (long)(http ? http.statusCode : -1)]));
            return;
        }
        NSDictionary *sr = data.length ? SPJSONDict([NSJSONSerialization JSONObjectWithData:data options:0 error:nil]) : nil;
        NSString *cdnURL = SPJSONString(SPJSONArray(sr[@"cdnurl"]).firstObject);
        completion(cdnURL, cdnURL.length ? nil : NetError(SPNetErrorMalformedResponse, @"storage-resolve missing cdnurl"));
    }];
}

- (SPCancelToken *)fetchFairPlayLicenseURLWithCompletion:(void (^)(NSString *, NSError *))completion {
    NSString *path = @"melody/v1/license_url?keysystem=com.apple.fps.1_0&mediatype=audio&sdk_name=harmony&sdk_version=4.82.0-04bdb077a";
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[self spclientURLForPath:path]];
    [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    return [self sendSignedRequest:req retryReads:YES completion:^(NSData *data, NSHTTPURLResponse *http, NSError *err) {
        if (!err && http && http.statusCode == 200 && data.length) {
            NSDictionary *mel = SPJSONDict([NSJSONSerialization JSONObjectWithData:data options:0 error:nil]);
            NSString *uri = SPJSONString(mel[@"uri"]);
            if (uri.length) {
                NSString *full = [uri hasPrefix:@"http"] ? uri : [self spclientURLForPath:uri].absoluteString;
                completion(full, nil);
                return;
            }
        }
        // Fallback documented in Harmony vendor.js when melody resolver fails.
        completion([self spclientURLForPath:@"fairplay-license/v1/audio/license"].absoluteString, nil);
    }];
}

- (SPCancelToken *)exchangeFairPlaySPC:(NSData *)spcData
                            licenseURL:(NSString *)licenseURL
                            completion:(void (^)(NSData *, NSHTTPURLResponse *, NSError *))completion {
    NSString *sep = [licenseURL containsString:@"?"] ? @"&" : @"?";
    NSString *fullURL = [NSString stringWithFormat:@"%@%@assetId=hex", licenseURL, sep];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:fullURL]];
    req.HTTPMethod = @"POST";
    req.HTTPBody = spcData;
    [req setValue:@"application/octet-stream" forHTTPHeaderField:@"Content-Type"];
    return [self sendSignedRequest:req retryReads:NO completion:^(NSData *data, NSHTTPURLResponse *http, NSError *err) {
        if (err || !http || http.statusCode != 200 || !data.length) {
            NSString *bodyStr = data.length ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"";
            NSError *outErr = err ?: NetError(SPNetErrorHTTPStatus, [NSString stringWithFormat:@"FairPlay license HTTP %ld %@", (long)(http ? http.statusCode : -1), bodyStr ?: @""]);
            completion(nil, http, outErr);
            return;
        }
        completion(data, http, nil);
    }];
}

@end
