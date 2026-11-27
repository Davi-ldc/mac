// Always-active global search controller: local-first + 80 ms debounced remote search with cancellation.
#import "net/search.h"

@implementation SPSearchController {
    SPStore *_store;
    SPNetClient *_client;
    dispatch_source_t _debounceTimer;
    SPCancelToken *_desktopTask;
    SPCancelToken *_suggestionsTask;
    SPSearchResults *_localResults;
    SPSearchResults *_remoteResults;
    NSArray<SPSearchSuggestion *> *_suggestions;
}

- (instancetype)initWithStore:(SPStore *)store client:(SPNetClient *)client {
    if (!(self = [super init])) return nil;
    _store = store;
    _client = client;
    _currentQuery = @"";
    _debounceInterval = 0.080;
    _remoteLimit = 10;
    return self;
}

- (void)dealloc {
    [self cancel];
}

- (void)cancelInFlight {
    if (_debounceTimer) {
        dispatch_source_cancel(_debounceTimer);
        _debounceTimer = nil;
    }
    [_desktopTask cancel];
    _desktopTask = nil;
    [_suggestionsTask cancel];
    _suggestionsTask = nil;
}

- (void)cancel {
    _generation++;
    [self cancelInFlight];
}

- (void)publishMerged {
    if (!_localResults) return;
    SPSearchResults *merged = [SPSearchResults mergedLocalResults:_localResults
                                                    remoteResults:_remoteResults
                                                      suggestions:_suggestions];
    _currentResults = merged;
    [_store.changes note:SPChangeSearch value:nil];
    [self.delegate searchController:self didUpdateResults:merged];
}

- (void)updateQuery:(NSString *)query {
    NSString *trimmed = [query ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    _generation++;
    uint64_t gen = _generation;
    [self cancelInFlight];
    _currentQuery = [trimmed copy];
    _remoteResults = nil;
    _suggestions = nil;

    if (!trimmed.length) {
        _localResults = [[SPSearchResults alloc] initWithQuery:@"" topHits:@[] tracks:@[] albums:@[] artists:@[] playlists:@[]
                                                   tracksTotal:0 albumsTotal:0 artistsTotal:0 playlistsTotal:0
                                                   suggestions:@[] isLocalOnly:YES];
        [self publishMerged];
        return;
    }

    // Immediate <1 ms local library results before any network call.
    _localResults = [_store searchLocal:trimmed];
    [self publishMerged];

    // Debounced remote searchDesktop + searchSuggestions.
    if (_debounceInterval <= 0) {
        [self fireRemoteQuery:trimmed generation:gen];
        return;
    }
    _debounceTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(_debounceTimer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(_debounceInterval * NSEC_PER_SEC)),
                              DISPATCH_TIME_FOREVER,
                              (uint64_t)(0.005 * NSEC_PER_SEC));
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_debounceTimer, ^{
        SPSearchController *strong = weakSelf;
        if (!strong || strong->_generation != gen) return;
        if (strong->_debounceTimer) {
            dispatch_source_cancel(strong->_debounceTimer);
            strong->_debounceTimer = nil;
        }
        [strong fireRemoteQuery:trimmed generation:gen];
    });
    dispatch_resume(_debounceTimer);
}

- (void)fireRemoteQuery:(NSString *)query generation:(uint64_t)gen {
    __weak typeof(self) weakSelf = self;
    _desktopTask = [_client searchDesktop:query offset:0 limit:_remoteLimit completion:^(SPSearchResults *remote, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            SPSearchController *strong = weakSelf;
            if (!strong || strong->_generation != gen) return; // Stale response dropped.
            if (err) {
                if ([strong.delegate respondsToSelector:@selector(searchController:didFailRemoteWithError:forQuery:)]) {
                    [strong.delegate searchController:strong didFailRemoteWithError:err forQuery:query];
                }
                return;
            }
            if (remote) {
                [strong->_store upsertTracks:remote.tracks];
                [strong->_store upsertAlbums:remote.albums];
                [strong->_store upsertArtists:remote.artists];
                [strong->_store upsertPlaylists:remote.playlists];
                strong->_remoteResults = remote;
                [strong publishMerged];
            }
        });
    }];

    _suggestionsTask = [_client searchSuggestions:query limit:15 completion:^(NSArray<SPSearchSuggestion *> *sugg, NSError *err) {
        if (err) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            SPSearchController *strong = weakSelf;
            if (!strong || strong->_generation != gen) return;
            strong->_suggestions = sugg;
            [strong publishMerged];
        });
    }];
}

@end
