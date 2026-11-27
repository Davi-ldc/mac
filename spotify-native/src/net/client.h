// Pathfinder GraphQL and spclient REST transport (URLCache = nil, signed desktop headers, cancellable tasks).
#import <Foundation/Foundation.h>

#import "auth/auth.h"
#import "model/album.h"
#import "model/artist.h"
#import "model/playlist.h"
#import "model/search.h"
#import "model/shelf.h"
#import "model/track.h"
#import "net/hashes.h"

NS_ASSUME_NONNULL_BEGIN

extern NSString *const SPNetErrorDomain;

typedef NS_ENUM(NSInteger, SPNetErrorCode) {
    SPNetErrorHTTPStatus = 1,
    SPNetErrorPersistedQueryNotFound = 2,
    SPNetErrorGraphQL = 3,
    SPNetErrorMutationRejected = 4,
    SPNetErrorMalformedResponse = 5,
    SPNetErrorInvalidID = 6,
    SPNetErrorCancelled = 7,
};

typedef NS_ENUM(NSInteger, SPSearchCategory) {
    SPSearchCategoryTracks = 0,
    SPSearchCategoryAlbums = 1,
    SPSearchCategoryArtists = 2,
    SPSearchCategoryPlaylists = 3,
};

/// Cancellable handle that cancels the underlying NSURLSessionTask immediately, even if attached asynchronously.
@interface SPCancelToken : NSObject
@property (nonatomic, readonly, getter=isCancelled) BOOL cancelled;
- (void)attachTask:(NSURLSessionTask *)task;
- (void)cancel;
@end

@interface SPNetClient : NSObject
@property (nonatomic, readonly) SPAuth *auth;
@property (nonatomic, readonly) NSURLSession *urlSession;

/// Configurable endpoints & retry delays (overridden in offline mock tests).
@property (nonatomic, copy) NSURL *pathfinderURL;
@property (nonatomic, copy) NSURL *spclientBaseURL;
@property (nonatomic, copy) NSURL *seektableBaseURL;
@property (nonatomic, copy) NSArray<NSNumber *> *retryDelays;

- (instancetype)initWithAuth:(SPAuth *)auth urlSession:(nullable NSURLSession *)urlSession NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithAuth:(SPAuth *)auth;
- (instancetype)init NS_UNAVAILABLE;

/// Signs `request` with desktop Bearer + Client-Token headers, retrying once on 401/client-token-error
/// and retrying reads on passing 5xx/connection drops.
- (SPCancelToken *)sendSignedRequest:(NSURLRequest *)request
                          retryReads:(BOOL)retryReads
                          completion:(void (^)(NSData *_Nullable data, NSHTTPURLResponse *_Nullable response, NSError *_Nullable error))completion;

/// Low-level Pathfinder GraphQL persisted query call.
- (SPCancelToken *)queryPathfinder:(SPPathfinderOp)op
                         variables:(NSDictionary *)variables
                        completion:(void (^)(NSDictionary *_Nullable json, NSError *_Nullable error))completion;

// Pathfinder typed API
- (SPCancelToken *)fetchHomeWithCompletion:(void (^)(SPHomePage *_Nullable home, NSError *_Nullable error))completion;
- (SPCancelToken *)fetchProfileWithCompletion:(void (^)(SPUserProfile *_Nullable profile, NSError *_Nullable error))completion;
- (SPCancelToken *)fetchLikedSongsOffset:(NSInteger)offset
                                   limit:(NSInteger)limit
                              completion:(void (^)(NSArray<SPTrack *> *_Nullable tracks, NSArray<SPPlaylistItem *> *_Nullable items, NSInteger total, NSInteger rawCount, NSError *_Nullable error))completion;
- (SPCancelToken *)fetchLibraryFilter:(NSString *)filter
                               offset:(NSInteger)offset
                                limit:(NSInteger)limit
                                order:(nullable NSString *)order
                           completion:(void (^)(NSDictionary *_Nullable libraryV3Dict, NSError *_Nullable error))completion;
- (SPCancelToken *)fetchAlbumWithID:(NSString *)albumID
                         completion:(void (^)(SPAlbum *_Nullable album, NSArray<SPTrack *> *_Nullable tracks, NSError *_Nullable error))completion;
- (SPCancelToken *)fetchArtistOverviewWithID:(NSString *)artistID
                                  completion:(void (^)(SPArtist *_Nullable artist, NSArray<SPAlbum *> *_Nullable albums, NSError *_Nullable error))completion;
- (SPCancelToken *)fetchArtistOverviewWithID:(NSString *)artistID
                              fullCompletion:(void (^)(SPArtist *_Nullable artist, NSArray<SPAlbum *> *_Nullable albums, NSArray<SPTrack *> *_Nullable topTracks, NSError *_Nullable error))completion;
- (SPCancelToken *)fetchArtistDiscographyWithID:(NSString *)artistID
                                         offset:(NSInteger)offset
                                          limit:(NSInteger)limit
                                     completion:(void (^)(SPArtist *_Nullable artist, NSArray<SPAlbum *> *_Nullable albums, NSError *_Nullable error))completion;
- (SPCancelToken *)fetchPlaylistWithID:(NSString *)playlistID
                                offset:(NSInteger)offset
                                 limit:(NSInteger)limit
                            completion:(void (^)(SPPlaylist *_Nullable playlist, NSArray<SPTrack *> *_Nullable tracks, NSError *_Nullable error))completion;
- (SPCancelToken *)checkEntitiesInLibrary:(NSArray<NSString *> *)uris
                               completion:(void (^)(NSDictionary<NSString *, NSNumber *> *_Nullable statusesByID, NSError *_Nullable error))completion;
- (SPCancelToken *)addToLibraryURIs:(NSArray<NSString *> *)uris
                         completion:(void (^)(NSError *_Nullable error))completion;
- (SPCancelToken *)removeFromLibraryURIs:(NSArray<NSString *> *)uris
                              completion:(void (^)(NSError *_Nullable error))completion;

// Single-request full search + typeahead + category pagination
- (SPCancelToken *)searchDesktop:(NSString *)query
                          offset:(NSInteger)offset
                           limit:(NSInteger)limit
                      completion:(void (^)(SPSearchResults *_Nullable results, NSError *_Nullable error))completion;
- (SPCancelToken *)searchSuggestions:(NSString *)query
                               limit:(NSInteger)limit
                          completion:(void (^)(NSArray<SPSearchSuggestion *> *_Nullable suggestions, NSError *_Nullable error))completion;
- (SPCancelToken *)searchCategory:(SPSearchCategory)category
                            query:(NSString *)query
                           offset:(NSInteger)offset
                            limit:(NSInteger)limit
                       completion:(void (^)(NSDictionary *_Nullable json, NSError *_Nullable error))completion;

// spclient REST helpers (metadata, context/radio resolve, playlist/v2 CRUD, FairPlay)
- (SPCancelToken *)fetchTrackMetadataWithID:(NSString *)trackID
                                 completion:(void (^)(NSDictionary *_Nullable rawMeta, SPTrack *_Nullable track, NSError *_Nullable error))completion;
- (SPCancelToken *)resolveContextURI:(NSString *)contextURI
                            deviceID:(NSString *)deviceID
                            maxPages:(NSInteger)maxPages
                          completion:(void (^)(NSArray<NSString *> *_Nullable trackURIs, NSString *_Nullable nextPageURL, NSError *_Nullable error))completion;
- (SPCancelToken *)fetchRadioSeedForTrackURI:(NSString *)trackURI
                                    deviceID:(NSString *)deviceID
                                  completion:(void (^)(NSArray<NSString *> *_Nullable radioURIs, NSError *_Nullable error))completion;

- (SPCancelToken *)createPlaylistWithName:(NSString *)name
                              description:(nullable NSString *)description
                               completion:(void (^)(NSString *_Nullable playlistID, NSError *_Nullable error))completion;
- (SPCancelToken *)updatePlaylistID:(NSString *)playlistID
                               name:(nullable NSString *)name
                        description:(nullable NSString *)description
                         completion:(void (^)(NSError *_Nullable error))completion;
- (SPCancelToken *)addPlaylistID:(NSString *)playlistID
           toRootlistForUsername:(NSString *)username
                      completion:(void (^)(NSError *_Nullable error))completion;
- (SPCancelToken *)removePlaylistID:(NSString *)playlistID
         fromRootlistForUsername:(NSString *)username
                      completion:(void (^)(NSError *_Nullable error))completion;
- (SPCancelToken *)addTrackURIs:(NSArray<NSString *> *)trackURIs
                   toPlaylistID:(NSString *)playlistID
                     completion:(void (^)(NSError *_Nullable error))completion;
- (SPCancelToken *)removeTrackURI:(NSString *)trackURI
                          atIndex:(NSInteger)index
                              uid:(nullable NSString *)uid
                   fromPlaylistID:(NSString *)playlistID
                       completion:(void (^)(NSError *_Nullable error))completion;

// FairPlay audio wire helpers
- (SPCancelToken *)fetchTrackCBCSManifestForURI:(NSString *)trackURI
                                     completion:(void (^)(NSDictionary *_Nullable manifestEntry, NSError *_Nullable error))completion;
- (SPCancelToken *)fetchFairPlayCertificateWithCompletion:(void (^)(NSData *_Nullable certDER, NSError *_Nullable error))completion;
- (SPCancelToken *)fetchSeektableForFileID:(NSString *)fileID
                                completion:(void (^)(NSDictionary *_Nullable seektable, NSError *_Nullable error))completion;
- (SPCancelToken *)resolveStorageForFileID:(NSString *)fileID
                                    format:(NSInteger)fileFormat
                                completion:(void (^)(NSString *_Nullable cdnURL, NSError *_Nullable error))completion;
- (SPCancelToken *)fetchFairPlayLicenseURLWithCompletion:(void (^)(NSString *_Nullable licenseURL, NSError *_Nullable error))completion;
- (SPCancelToken *)exchangeFairPlaySPC:(NSData *)spcData
                            licenseURL:(NSString *)licenseURL
                            completion:(void (^)(NSData *_Nullable ckcData, NSHTTPURLResponse *_Nullable response, NSError *_Nullable error))completion;
@end

NS_ASSUME_NONNULL_END
