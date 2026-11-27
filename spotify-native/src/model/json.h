// Safe JSON extraction, Spotify URI/GID conversion, image selection, and release date formatting.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

NSDictionary *_Nullable SPJSONDict(id _Nullable value);
NSArray *_Nullable SPJSONArray(id _Nullable value);
NSString *_Nullable SPJSONString(id _Nullable value);
NSNumber *_Nullable SPJSONNumber(id _Nullable value);
NSInteger SPJSONInt(id _Nullable value, NSInteger fallback);
int64_t SPJSONInt64(id _Nullable value, int64_t fallback);
double SPJSONDouble(id _Nullable value, double fallback);
BOOL SPJSONBool(id _Nullable value, BOOL fallback);

/// Fast thread-safe ISO-8601 UTC timestamp parser (e.g. "2026-08-13T07:12:40Z"). Returns 0 on failure.
double SPParseISO8601Timestamp(NSString *_Nullable isoString);

/// Extracts the final id segment of a `spotify:<kind>:<id>` URI.
NSString *_Nullable SPURIIDFromURI(NSString *_Nullable uri);

/// Extracts the id ONLY if `uri` has exact 3-part shape `spotify:<kind>:<id>`.
/// Rejects playlist folders (`spotify:user:<u>:folder:<h>`) and collections (`spotify:collection:tracks`).
NSString *_Nullable SPURIIDFromURIOfKind(NSString *_Nullable uri, NSString *kind);

/// Extracts a track id from either `spotify:track:<id>` or `https://open.spotify.com/track/<id>`.
NSString *_Nullable SPURITrackIDFromString(NSString *_Nullable uriOrLink);

/// Returns `https://open.spotify.com/<kind>/<id>` for supported entity URIs.
NSString *_Nullable SPURIWebURL(NSString *_Nullable uri);

/// Converts a Spotify base62 id (<=22 chars) to a 32-char lowercase hex GID.
NSString *_Nullable SPBase62ToHexGID(NSString *_Nullable base62ID);

/// Converts a 32-char hex GID to a zero-padded 22-char Spotify base62 id.
NSString *_Nullable SPHexGIDToBase62(NSString *_Nullable hexGID);

/// Extracts largest and smallest suitable artwork URLs from a Pathfinder `{sources:[{url,width/maxWidth}]}` dict.
void SPExtractPathfinderImages(NSDictionary *_Nullable imageDict,
                               NSString *_Nullable *_Nullable outLargeURL,
                               NSString *_Nullable *_Nullable outSmallURL);

/// Extracts artwork URLs from spclient `cover_group.image` (`[{file_id, width, height}]`).
void SPExtractSpclientImages(NSArray *_Nullable images,
                             NSString *_Nullable *_Nullable outLargeURL,
                             NSString *_Nullable *_Nullable outSmallURL);

/// Formats all four Pathfinder release date shapes respecting precision (YEAR/MONTH/DAY).
NSString *_Nullable SPFormatPathfinderReleaseDate(NSDictionary *_Nullable dateDict);

/// Normalizes playlist descriptions (empty, whitespace-only, or literal "null" -> nil).
NSString *_Nullable SPNormalizePlaylistDescription(NSString *_Nullable raw);

NS_ASSUME_NONNULL_END
