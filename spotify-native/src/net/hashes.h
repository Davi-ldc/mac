// Verified Spotify Pathfinder GraphQL persisted-query hashes (harvested 2026-11-19 / 2026-11-27).
// Keep every operation hash in this single table so web-player hash rotations are a 1-file edit.
#import <Foundation/Foundation.h>

#import "model/playlist.h"

NS_ASSUME_NONNULL_BEGIN

typedef struct {
    const char *name;
    const char *sha256;
    BOOL retryPassingFailures;
} SPPathfinderOp;

// Search (single-request desktop search + typeahead + category pagination)
static const SPPathfinderOp SPPathfinderOpSearchDesktop = {
    "searchDesktop",
    "eef7cc54888d91bdd6802623477873caa3948ae173a0c34fd86827b267e94c03",
    YES,
};
static const SPPathfinderOp SPPathfinderOpSearchSuggestions = {
    "searchSuggestions",
    "f244254b94c0e824d458ac216e0f8406a73f2f69a9ff52831a2f78fa774ff6ce",
    YES,
};
static const SPPathfinderOp SPPathfinderOpSearchTracks = {
    "searchTracks",
    "b02683192a98dde7966b5e6655a79eeb62713eab703eda9902c932818dd52751",
    YES,
};
static const SPPathfinderOp SPPathfinderOpSearchAlbums = {
    "searchAlbums",
    "202cb3305e31e5a0767ba7925f28bd728cf8f8b0217e6da43909056071cd70e9",
    YES,
};
static const SPPathfinderOp SPPathfinderOpSearchArtists = {
    "searchArtists",
    "7bf95d754fdbe32c8b161fbbe54d1ae50974900df4dce4c8f1afcbcad153224d",
    YES,
};
static const SPPathfinderOp SPPathfinderOpSearchPlaylists = {
    "searchPlaylists",
    "d520014e748f9ea44f7707d8df1819867ac1205e8b7f3e28f22fe5fc858921b1",
    YES,
};

// Home & Profile
static const SPPathfinderOp SPPathfinderOpHome = {
    "home",
    "5fb7da7a03ee2776c0670856609cb85a189a3cecc36cc160b91cde79063b9cf1",
    YES,
};
static const SPPathfinderOp SPPathfinderOpProfileAttributes = {
    "profileAttributes",
    "08ffb4730af3746e04a8301396f20875dbbce10c75243803091a9274eacc8ac0",
    YES,
};
static const SPPathfinderOp SPPathfinderOpUserTopContent = {
    "userTopContent",
    "61b7353d3625780022dbc63d459eb64cd609e7e5e2a820f9160d65030efe2e15",
    YES,
};

// Library & Favorites
static const SPPathfinderOp SPPathfinderOpLibraryV3 = {
    "libraryV3",
    "390c78e5b951029bad359785e69b07b536a509c581cbcd0aded5e5067f187455",
    YES,
};
static const SPPathfinderOp SPPathfinderOpAreEntitiesInLibrary = {
    "areEntitiesInLibrary",
    "134337999233cc6fdd6b1e6dbf94841409f04a946c5c7b744b09ba0dfe5a85ed",
    NO,
};
static const SPPathfinderOp SPPathfinderOpAddToLibrary = {
    "addToLibrary",
    "896ebcb47815681340860d121cb5d494e157e2a78d3950385cd54e0393c67148",
    NO,
};
static const SPPathfinderOp SPPathfinderOpRemoveFromLibrary = {
    "removeFromLibrary",
    "896ebcb47815681340860d121cb5d494e157e2a78d3950385cd54e0393c67148",
    NO,
};

// Album, Artist, Playlist
static const SPPathfinderOp SPPathfinderOpGetAlbum = {
    "getAlbum",
    "0b6ce3511e1b02e4a40fa95440f992acbe85080eb308af9194322d708fc1914f",
    YES,
};
static const SPPathfinderOp SPPathfinderOpQueryArtistOverview = {
    "queryArtistOverview",
    "eafb1620d783ece118e72fbfede2b0064483e029d3c1aafafa1c2de0e25a89e7",
    YES,
};
static const SPPathfinderOp SPPathfinderOpQueryArtistDiscographyAll = {
    "queryArtistDiscographyAll",
    "5e07d323febb57b4a56a42abbf781490e58764aa45feb6e3dc0591564fc56599",
    YES,
};
static const SPPathfinderOp SPPathfinderOpFetchPlaylist = {
    "fetchPlaylist",
    "21ea11a6ac75a5f3e01fd365d29c18e0a4a8b7dc09f89bbb5d73910190c6acaf",
    YES,
};
static const SPPathfinderOp SPPathfinderOpFetchPlaylistContents = {
    "fetchPlaylistContents",
    "21ea11a6ac75a5f3e01fd365d29c18e0a4a8b7dc09f89bbb5d73910190c6acaf",
    YES,
};
static const SPPathfinderOp SPPathfinderOpAddToPlaylist = {
    "addToPlaylist",
    "b907ad6b088d5bf7680fa81198996d58398c2d55dfcdf59fcc959e0be98a418a",
    NO,
};
static const SPPathfinderOp SPPathfinderOpRemoveFromPlaylist = {
    "removeFromPlaylist",
    "b907ad6b088d5bf7680fa81198996d58398c2d55dfcdf59fcc959e0be98a418a",
    NO,
};
static const SPPathfinderOp SPPathfinderOpMoveItemsInPlaylist = {
    "moveItemsInPlaylist",
    "b907ad6b088d5bf7680fa81198996d58398c2d55dfcdf59fcc959e0be98a418a",
    NO,
};

NS_ASSUME_NONNULL_END
