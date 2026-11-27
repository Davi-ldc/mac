// Theme tokens and immutable Model JSON/Protobuf decoder tests (including zero retained raw JSON check).
#import "test.h"
#import "model/album.h"
#import "model/artist.h"
#import "model/device.h"
#import "model/json.h"
#import "model/playback.h"
#import "model/playlist.h"
#import "model/protobuf.h"
#import "model/search.h"
#import "model/shelf.h"
#import "model/track.h"
#import "theme/theme.h"

#import <objc/runtime.h>

SP_TEST(ThemeDarkPaletteAndTokens) {
    const SPColorPalette *pal = SPThemeDarkPalette();
    SPExpect(pal != NULL, @"dark palette exists");
    SPExpectEqualInt(pal->accent.hex, 0x1DB954, "Spotify green accent hex");
    SPExpect(pal->bgBase.r < 0.2 && pal->bgSidebar.r < 0.2, @"dark surfaces are dark");
    SPExpect(pal->textPrimary.r > 0.85, @"primary text is bright");

    CGColorRef cg = SPColorCreateCG(pal->accent);
    SPExpect(cg != NULL, @"CGColor created from token");
    if (cg) CGColorRelease(cg);

    const SPTypographyScale *typo = SPThemeTypography();
    SPExpect(typo->display.size > typo->title1.size && typo->title1.size > typo->body.size, @"typography hierarchy ordered");
    SPExpect(typo->monoTime.monospacedDigits, @"monoTime uses monospaced digits");

    const SPLayoutMetrics *m = SPThemeMetrics();
    SPExpect(m->sidebarWidth >= 180.0 && m->nowPlayingBarHeight >= 60.0 && m->trackRowHeight >= 40.0, @"layout metrics valid");
}

SP_TEST(ModelURIGIDDateAndProtobuf) {
    // Base62 <-> 32-char hex GID round-trip, including Rick Astley & leading-zero IDs.
    NSString *rick = @"4cOdK2wGLETKBW3PvgPWqT";
    NSString *hex = SPBase62ToHexGID(rick);
    SPExpectEqualInt(hex.length, 32, "GID hex length is 32");
    SPExpectEqualStr(SPHexGIDToBase62(hex), rick, "base62 -> hex -> base62 round-trip");

    NSString *padded = @"0000000000000000000001";
    NSString *paddedHex = SPBase62ToHexGID(padded);
    SPExpectEqualStr(paddedHex, @"00000000000000000000000000000001", "leading zeros preserved in GID");
    SPExpectEqualStr(SPHexGIDToBase62(paddedHex), padded, "leading zeros preserved in base62");
    SPExpect(SPBase62ToHexGID(@"not!valid") == nil, @"invalid base62 rejected");

    // URI extraction & folder rejection.
    SPExpectEqualStr(SPURIIDFromURIOfKind(@"spotify:playlist:abc123", @"playlist"), @"abc123", "valid playlist URI");
    SPExpect(SPURIIDFromURIOfKind(@"spotify:user:alice:folder:deadbeef", @"playlist") == nil, @"playlist folder rejected");
    SPExpect(SPURIIDFromURIOfKind(@"spotify:collection:tracks", @"playlist") == nil, @"collection URI rejected");
    SPExpectEqualStr(SPURITrackIDFromString(@"https://open.spotify.com/track/4cOdK2wGLETKBW3PvgPWqT?si=xyz"), rick, "open.spotify.com link parsed");
    SPExpectEqualStr(SPURIWebURL(@"spotify:track:4cOdK2wGLETKBW3PvgPWqT"), @"https://open.spotify.com/track/4cOdK2wGLETKBW3PvgPWqT", "web URL built");

    // All 4 Pathfinder release date shapes.
    SPExpectEqualStr(SPFormatPathfinderReleaseDate(@{@"isoString" : @"1971-01-01T00:00:00Z", @"precision" : @"YEAR"}), @"1971", "YEAR precision trims fake Jan 1");
    SPExpectEqualStr(SPFormatPathfinderReleaseDate(@{@"isoString" : @"2024-05-01T00:00:00Z", @"precision" : @"MONTH"}), @"2024-05", "MONTH precision");
    SPExpectEqualStr(SPFormatPathfinderReleaseDate(@{@"year" : @2011, @"month" : @10, @"day" : @18, @"precision" : @"DAY"}), @"2011-10-18", "day/month/year dict");
    SPExpectEqualStr(SPFormatPathfinderReleaseDate(@{@"year" : @1987}), @"1987", "bare year dict");

    // Playlist description normalization.
    SPExpect(SPNormalizePlaylistDescription(@"null") == nil, @"literal 'null' normalized to nil");
    SPExpect(SPNormalizePlaylistDescription(@"   ") == nil, @"whitespace normalized to nil");
    SPExpectEqualStr(SPNormalizePlaylistDescription(@"  Chill  "), @"Chill", "trimmed description kept");

    // Protobuf wire round-trip.
    NSData *pb = [SPProtobufWriter messageWithBlock:^(SPProtobufWriter *w) {
        [w writeVarint:1209600 field:1];
        [w writeString:@"hello-spotify" field:2];
        [w writeFlag:YES field:3];
        [w writeMessageField:4 block:^(SPProtobufWriter *nested) {
            [nested writeString:@"k1" field:1];
            [nested writeString:@"v1" field:2];
        }];
    }];
    uint64_t v = 0;
    SPExpect(SPProtobufFirstVarint(pb, 1, &v) && v == 1209600, @"varint decoded");
    SPExpectEqualStr(SPProtobufFirstString(pb, 2), @"hello-spotify", "string decoded");
    NSArray<SPProtobufField *> *fields = SPProtobufReadFields(pb);
    SPExpectEqualInt(fields.count, 4, "all 4 protobuf fields parsed");
    NSString *mk = nil, *mv = nil;
    [fields[3] readMapEntryKey:&mk value:&mv];
    SPExpectEqualStr(mk, @"k1", "map key decoded");
    SPExpectEqualStr(mv, @"v1", "map value decoded");
}

SP_TEST(ModelNoRetainedJSONIvars) {
    NSArray<Class> *modelClasses = @[
        SPTrack.class,
        SPAlbum.class,
        SPArtist.class,
        SPPlaylist.class,
        SPPlaylistItem.class,
        SPHomeShelf.class,
        SPShelfItem.class,
        SPUserProfile.class,
        SPDevice.class,
        SPPlaybackState.class,
        SPQueueTrack.class,
        SPClusterState.class,
        SPSearchResults.class,
        SPSearchSuggestion.class,
    ];
    for (Class cls in modelClasses) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            const char *name = ivar_getName(ivars[i]);
            const char *type = ivar_getTypeEncoding(ivars[i]);
            BOOL isDict = (type && strstr(type, "NSDictionary") != NULL);
            BOOL isRawJSON = (name && (strstr(name, "json") != NULL || strstr(name, "JSON") != NULL));
            SPExpect(!isDict && !isRawJSON, @"model %s must not retain raw dictionary/JSON ivar %s (%s)",
                     class_getName(cls), name ?: "", type ?: "");
        }
        free(ivars);
    }
}

SP_TEST(ModelDecodeHomeProfileAlbumArtistPlaylist) {
    // Home: includes Album, Artist, Playlist, Recents list, and a NotFound tombstone.
    NSDictionary *homeJSON = @{
        @"data" : @{
            @"home" : @{
                @"__typename" : @"HomeResponsePayload",
                @"sectionContainer" : @{
                    @"sections" : @{
                        @"items" : @[
                            @{
                                @"uri" : @"spotify:section:made-for-you",
                                @"data" : @{@"title" : @{@"transformedLabel" : @"Made For You"}},
                                @"sectionItems" : @{
                                    @"items" : @[
                                        @{
                                            @"content" : @{
                                                @"__typename" : @"AlbumResponseWrapper",
                                                @"data" : @{
                                                    @"uri" : @"spotify:album:alb1",
                                                    @"name" : @"Discovery",
                                                    @"artists" : @{@"items" : @[ @{@"uri" : @"spotify:artist:art1", @"profile" : @{@"name" : @"Daft Punk"}} ]},
                                                    @"coverArt" : @{@"sources" : @[ @{@"url" : @"https://i.scdn.co/image/alb1-640", @"width" : @640} ]},
                                                    @"date" : @{@"year" : @2001},
                                                },
                                            },
                                        },
                                        @{
                                            @"content" : @{
                                                @"__typename" : @"AlbumResponseWrapper",
                                                @"data" : @{@"__typename" : @"NotFound"},
                                            },
                                        },
                                        @{
                                            @"content" : @{
                                                @"__typename" : @"PlaylistResponseWrapper",
                                                @"data" : @{
                                                    @"uri" : @"spotify:playlist:pl1",
                                                    @"name" : @"Daily Mix 1",
                                                    @"description" : @"null",
                                                    @"ownerV2" : @{@"data" : @{@"name" : @"Spotify", @"uri" : @"spotify:user:spotify"}},
                                                    @"images" : @{@"items" : @[ @{@"sources" : @[ @{@"url" : @"https://i.scdn.co/image/pl1", @"width" : @300} ]} ]},
                                                },
                                            },
                                        },
                                    ],
                                },
                            },
                            @{
                                @"uri" : @"spotify:section:0JQ5DAob0KZzPQKc9YbqhR",
                                @"data" : @{@"__typename" : @"HomeRecentlyPlayedSectionData", @"title" : @{@"transformedLabel" : @"Recently played"}},
                                @"sectionItems" : @{
                                    @"items" : @[
                                        @{
                                            @"content" : @{
                                                @"__typename" : @"ListResponseWrapper",
                                                @"data" : @{
                                                    @"items" : @{
                                                        @"items" : @[
                                                            @{
                                                                @"entity" : @{
                                                                    @"data" : @{
                                                                        @"uri" : @"spotify:artist:art2",
                                                                        @"identityTrait" : @{@"name" : @"Justice"},
                                                                        @"visualIdentityTrait" : @{
                                                                            @"squareCoverImage" : @{
                                                                                @"image" : @{@"data" : @{@"sources" : @[ @{@"url" : @"https://i.scdn.co/image/art2", @"maxWidth" : @640} ]}},
                                                                            },
                                                                        },
                                                                    },
                                                                },
                                                            },
                                                        ],
                                                    },
                                                },
                                            },
                                        },
                                    ],
                                },
                            },
                        ],
                    },
                },
            },
        },
    };

    NSError *err = nil;
    SPHomePage *page = [SPHomePage homePageFromPathfinderJSON:homeJSON errorOut:&err];
    SPExpect(page != nil && err == nil, @"home page decoded");
    SPExpectEqualInt(page.shelves.count, 2, "two home shelves");
    SPExpectEqualInt(page.shelves[0].items.count, 2, "tombstone skipped in shelf 0");
    SPExpectEqualStr(page.shelves[0].items[0].title, @"Discovery", "shelf album title");
    SPExpect(page.shelves[1].isRecentlyPlayed, @"recents shelf flagged");
    SPExpectEqualInt(page.shelves[1].items.count, 1, "recents entity decoded");
    SPExpectEqualStr(page.shelves[1].items[0].title, @"Justice", "recents artist title");

    // HTTP 200 GenericError union member must be rejected.
    NSError *homeErr = nil;
    SPHomePage *bad = [SPHomePage homePageFromPathfinderJSON:@{@"data" : @{@"home" : @{@"__typename" : @"GenericError"}}} errorOut:&homeErr];
    SPExpect(bad == nil && homeErr != nil, @"GenericError home payload rejected");

    // User profile.
    SPUserProfile *prof = [SPUserProfile profileFromPathfinderJSON:@{
        @"data" : @{@"me" : @{@"profile" : @{
            @"username" : @"davi",
            @"name" : @"Davi",
            @"uri" : @"spotify:user:davi",
            @"avatar" : @{@"sources" : @[ @{@"url" : @"https://i.scdn.co/image/av", @"width" : @300} ]},
        }}}
    }];
    SPExpectEqualStr(prof.username, @"davi", "profile username");
    SPExpectEqualStr(prof.displayName, @"Davi", "profile display name");

    // Album + tracks + NotFound.
    NSDictionary *albumUnion = @{
        @"__typename" : @"Album",
        @"uri" : @"spotify:album:alb1",
        @"name" : @"Discovery",
        @"type" : @"ALBUM",
        @"date" : @{@"isoString" : @"2001-03-12T00:00:00Z", @"precision" : @"DAY"},
        @"coverArt" : @{@"sources" : @[ @{@"url" : @"https://i.scdn.co/image/alb1", @"width" : @640} ]},
        @"artists" : @{@"items" : @[ @{@"id" : @"art1", @"uri" : @"spotify:artist:art1", @"profile" : @{@"name" : @"Daft Punk"}} ]},
        @"tracksV2" : @{
            @"totalCount" : @2,
            @"items" : @[
                @{@"track" : @{@"uri" : @"spotify:track:trk1", @"name" : @"One More Time", @"trackNumber" : @1, @"discNumber" : @1, @"duration" : @{@"totalMilliseconds" : @320357}, @"artists" : @{@"items" : @[ @{@"uri" : @"spotify:artist:art1", @"profile" : @{@"name" : @"Daft Punk"}} ]}, @"playability" : @{@"playable" : @YES}}},
                @{@"track" : @{@"uri" : @"spotify:track:trk2", @"name" : @"Aerodynamic", @"trackNumber" : @2, @"discNumber" : @1, @"duration" : @{@"totalMilliseconds" : @212546}, @"artists" : @{@"items" : @[ @{@"uri" : @"spotify:artist:art1", @"profile" : @{@"name" : @"Daft Punk"}} ]}, @"playability" : @{@"playable" : @NO, @"reason" : @"COUNTRY_RESTRICTED"}}},
            ],
        },
    };
    NSArray<SPTrack *> *albTracks = nil;
    SPAlbum *alb = [SPAlbum albumFromPathfinderUnion:albumUnion tracksOut:&albTracks errorOut:&err];
    SPExpect(alb != nil && alb.detailsLoaded, @"album union decoded");
    SPExpectEqualInt(albTracks.count, 2, "two album tracks");
    SPExpect(albTracks[0].playable && !albTracks[1].playable, @"playability parsed");
    SPExpectEqualStr(albTracks[1].unplayableReason, @"COUNTRY_RESTRICTED", "unplayable reason parsed");

    NSError *nfErr = nil;
    SPExpect([SPAlbum albumFromPathfinderUnion:@{@"__typename" : @"NotFound"} tracksOut:nil errorOut:&nfErr] == nil && nfErr != nil, @"album NotFound rejected");

    // Artist overview with duplicate release deduplication.
    NSDictionary *artistUnion = @{
        @"__typename" : @"Artist",
        @"id" : @"art1",
        @"uri" : @"spotify:artist:art1",
        @"profile" : @{@"name" : @"Daft Punk"},
        @"visuals" : @{@"avatarImage" : @{@"sources" : @[ @{@"url" : @"https://i.scdn.co/image/dp", @"width" : @640} ]}},
        @"discography" : @{
            @"albums" : @{@"items" : @[ @{@"releases" : @{@"items" : @[ @{@"id" : @"alb1", @"uri" : @"spotify:album:alb1", @"name" : @"Discovery", @"type" : @"ALBUM", @"date" : @{@"year" : @2001}} ]}} ]},
            @"all" : @{@"items" : @[ @{@"releases" : @{@"items" : @[ @{@"id" : @"alb1", @"uri" : @"spotify:album:alb1", @"name" : @"Discovery", @"type" : @"ALBUM", @"date" : @{@"year" : @2001}}, @{@"id" : @"alb2", @"uri" : @"spotify:album:alb2", @"name" : @"Homework", @"type" : @"ALBUM", @"date" : @{@"year" : @1997}} ]}} ]},
        },
    };
    NSArray<SPAlbum *> *discog = nil;
    SPArtist *artist = [SPArtist artistFromPathfinderUnion:artistUnion albumsOut:&discog errorOut:&err];
    SPExpect(artist != nil && artist.detailsLoaded, @"artist union decoded");
    SPExpectEqualInt(discog.count, 2, "discography deduplicated to 2 albums");

    // Playlist + Liked Songs contents.
    NSDictionary *plUnion = @{
        @"__typename" : @"Playlist",
        @"uri" : @"spotify:playlist:pl42",
        @"name" : @"Coding Flow",
        @"description" : @"Focus",
        @"ownerV2" : @{@"data" : @{@"name" : @"Davi", @"username" : @"davi", @"uri" : @"spotify:user:davi"}},
        @"content" : @{
            @"totalCount" : @2,
            @"items" : @[
                @{
                    @"uid" : @"u-1",
                    @"addedAt" : @{@"isoString" : @"2026-08-13T07:12:40Z"},
                    @"itemV2" : @{
                        @"data" : @{
                            @"__typename" : @"Track",
                            @"uri" : @"spotify:track:trk1",
                            @"name" : @"One More Time",
                            @"trackDuration" : @{@"totalMilliseconds" : @320357},
                            @"artists" : @{@"items" : @[ @{@"uri" : @"spotify:artist:art1", @"profile" : @{@"name" : @"Daft Punk"}} ]},
                            @"albumOfTrack" : @{@"uri" : @"spotify:album:alb1", @"name" : @"Discovery"},
                        },
                    },
                },
                @{
                    @"uid" : @"u-2",
                    @"itemV2" : @{@"data" : @{@"__typename" : @"Episode", @"uri" : @"spotify:episode:ep1"}},
                },
            ],
        },
    };
    NSArray<SPTrack *> *plTracks = nil;
    SPPlaylist *pl = [SPPlaylist playlistFromPathfinderUnion:plUnion tracksOut:&plTracks errorOut:&err];
    SPExpect(pl != nil && pl.detailsLoaded, @"playlist decoded");
    SPExpectEqualInt(pl.items.count, 1, "non-track episode filtered out");
    SPExpectEqualInt(plTracks.count, 1, "one playlist track extracted");
    SPExpect(pl.items[0].addedAt > 1700000000.0, @"ISO-8601 addedAt parsed");

    // Liked Songs contents decoder returns rawCount=2 (for pagination) even when 1 item is filtered.
    NSInteger likedTotal = 0, likedRaw = 0;
    NSArray<SPPlaylistItem *> *likedItems = nil;
    NSArray<SPTrack *> *likedTracks = [SPPlaylist tracksFromPathfinderContentsUnion:plUnion itemsOut:&likedItems totalOut:&likedTotal rawCountOut:&likedRaw];
    SPExpectEqualInt(likedTracks.count, 1, "liked songs decoded track");
    SPExpectEqualInt(likedTotal, 2, "liked total preserved");
    SPExpectEqualInt(likedRaw, 2, "liked raw count preserved for pagination");

    // spclient metadata/4/track with relinking alternative stays playable.
    NSDictionary *spTrack = @{
        @"name" : @"Relinked Song",
        @"duration" : @210000,
        @"number" : @3,
        @"disc_number" : @1,
        @"artist" : @[ @{@"name" : @"Artist X", @"gid" : @"00000000000000000000000000000001"} ],
        @"album" : @{@"name" : @"Album X", @"gid" : @"00000000000000000000000000000002", @"cover_group" : @{@"image" : @[ @{@"file_id" : @"ab67616d0000b2731234", @"width" : @640} ]}},
        @"restriction" : @[ @{@"countries_allowed" : @""} ],
        @"alternative" : @[ @{@"gid" : @"00000000000000000000000000000099"} ],
    };
    SPTrack *hydrated = [SPTrack trackFromSpclientDict:spTrack requestedID:@"4cOdK2wGLETKBW3PvgPWqT"];
    SPExpect(hydrated != nil && hydrated.playable, @"relinked track with alternative stays playable");
    SPExpectEqualStr(hydrated.artworkURL, @"https://i.scdn.co/image/ab67616d0000b2731234", "spclient cover image URL assembled");
}

SP_TEST(ModelDecodeSearchDesktopAndSuggestions) {
    NSDictionary *desktopJSON = @{
        @"data" : @{
            @"searchV2" : @{
                @"topResultsV2" : @{
                    @"itemsV2" : @[
                        @{@"item" : @{@"__typename" : @"ArtistResponseWrapper", @"data" : @{@"uri" : @"spotify:artist:art1", @"profile" : @{@"name" : @"Daft Punk"}}}},
                    ],
                },
                @"tracksV2" : @{
                    @"totalCount" : @120,
                    @"items" : @[
                        @{@"item" : @{@"data" : @{@"id" : @"trk1", @"uri" : @"spotify:track:trk1", @"name" : @"One More Time", @"duration" : @{@"totalMilliseconds" : @320000}, @"artists" : @{@"items" : @[ @{@"uri" : @"spotify:artist:art1", @"profile" : @{@"name" : @"Daft Punk"}} ]}}}},
                    ],
                },
                @"albumsV2" : @{
                    @"totalCount" : @15,
                    @"items" : @[
                        @{@"data" : @{@"uri" : @"spotify:album:alb1", @"name" : @"Discovery", @"date" : @{@"year" : @2001}, @"artists" : @{@"items" : @[ @{@"uri" : @"spotify:artist:art1", @"profile" : @{@"name" : @"Daft Punk"}} ]}}},
                    ],
                },
                @"artists" : @{
                    @"totalCount" : @8,
                    @"items" : @[
                        @{@"data" : @{@"uri" : @"spotify:artist:art1", @"profile" : @{@"name" : @"Daft Punk"}}},
                    ],
                },
                @"playlists" : @{
                    @"totalCount" : @40,
                    @"items" : @[
                        @{@"data" : @{@"uri" : @"spotify:playlist:pl1", @"name" : @"This Is Daft Punk", @"ownerV2" : @{@"data" : @{@"name" : @"Spotify", @"uri" : @"spotify:user:spotify"}}}},
                    ],
                },
            },
        },
    };
    SPSearchResults *res = [SPSearchResults resultsFromSearchDesktopJSON:desktopJSON query:@"daft punk"];
    SPExpect(!res.isLocalOnly, @"remote searchDesktop marked non-local");
    SPExpectEqualInt(res.topHits.count, 1, "top hit decoded");
    SPExpectEqualInt(res.tracks.count, 1, "tracksV2 item.data wrapper decoded");
    SPExpectEqualInt(res.tracksTotal, 120, "tracksTotal decoded");
    SPExpectEqualInt(res.albums.count, 1, "albumsV2 direct data decoded");
    SPExpectEqualInt(res.artists.count, 1, "artists direct data decoded");
    SPExpectEqualInt(res.playlists.count, 1, "playlists direct data decoded");

    NSDictionary *suggJSON = @{
        @"data" : @{
            @"searchV2" : @{
                @"topResultsV2" : @{
                    @"itemsV2" : @[
                        @{@"item" : @{@"__typename" : @"SearchAutoCompleteEntity", @"data" : @{@"query" : @"daft punk discovery"}}},
                        @{@"item" : @{@"__typename" : @"SearchAutocompleteQuery", @"data" : @{@"query" : @"daft punk alive"}}},
                        @{@"item" : @{@"__typename" : @"TrackResponseWrapper", @"data" : @{@"uri" : @"spotify:track:trk1", @"name" : @"One More Time", @"artists" : @{@"items" : @[ @{@"profile" : @{@"name" : @"Daft Punk"}} ]}}}},
                    ],
                },
            },
        },
    };
    NSArray<SPSearchSuggestion *> *sugg = [SPSearchResults suggestionsFromSearchSuggestionsJSON:suggJSON];
    SPExpectEqualInt(sugg.count, 3, "three suggestions decoded");
    SPExpectEqualInt(sugg[0].kind, SPSearchSuggestionQuery, "SearchAutoCompleteEntity decoded as query suggestion");
    SPExpectEqualStr(sugg[0].text, @"daft punk discovery", "query autocomplete text");
    SPExpectEqualInt(sugg[1].kind, SPSearchSuggestionQuery, "SearchAutocompleteQuery decoded as query suggestion");
    SPExpectEqualStr(sugg[1].text, @"daft punk alive", "second query autocomplete text");
    SPExpectEqualInt(sugg[2].kind, SPSearchSuggestionTrack, "track suggestion kind");
    SPExpectEqualStr(sugg[2].entityID, @"trk1", "track suggestion entity ID");
}

SP_TEST(ModelDecodeConnectClusterProtobuf) {
    NSData *clusterUpdatePB = [SPProtobufWriter messageWithBlock:^(SPProtobufWriter *upd) {
        [upd writeMessageField:1 block:^(SPProtobufWriter *cl) {
            [cl writeString:@"dev-mac" field:2]; // active_device_id
            // PlayerState (field 3)
            [cl writeMessageField:3 block:^(SPProtobufWriter *ps) {
                [ps writeVarint:1000000 field:1]; // timestamp ms
                [ps writeString:@"spotify:album:alb1" field:2];
                [ps writeMessageField:7 block:^(SPProtobufWriter *tr) {
                    [tr writeString:@"spotify:track:4cOdK2wGLETKBW3PvgPWqT" field:1];
                    [tr writeString:@"uid-cur" field:2];
                    [tr writeString:@"context" field:6];
                }];
                [ps writeVarint:15000 field:10]; // position_as_of_timestamp
                [ps writeVarint:213000 field:11]; // duration
                [ps writeBool:YES field:12]; // is_playing
                [ps writeBool:NO field:13]; // is_paused
                [ps writeMessageField:16 block:^(SPProtobufWriter *opt) {
                    [opt writeBool:YES field:1]; // shuffling
                    [opt writeBool:YES field:2]; // repeating_context
                    [opt writeBool:NO field:3]; // repeating_track
                }];
                [ps writeMessageField:17 block:^(SPProtobufWriter *rest) {
                    [rest writeString:@"no_next_track" field:7]; // disallow_skipping_next_reasons
                }];
                [ps writeMessageField:20 block:^(SPProtobufWriter *nt) {
                    [nt writeString:@"spotify:track:next1" field:1];
                    [nt writeString:@"uid-next" field:2];
                    [nt writeString:@"queue" field:6];
                }];
                [ps writeMessageField:20 block:^(SPProtobufWriter *delim) {
                    [delim writeString:@"spotify:delimiter" field:1];
                    [delim writeMessageField:3 block:^(SPProtobufWriter *meta) {
                        [meta writeString:@"hidden" field:1];
                        [meta writeString:@"true" field:2];
                    }];
                }];
                [ps writeMessageField:21 block:^(SPProtobufWriter *cm) {
                    [cm writeString:@"context_description" field:1];
                    [cm writeString:@"Discovery" field:2];
                }];
            }];
            // Visible device (field 4 map entry)
            [cl writeMessageField:4 block:^(SPProtobufWriter *entry) {
                [entry writeString:@"dev-mac" field:1];
                [entry writeMessageField:2 block:^(SPProtobufWriter *di) {
                    [di writeBool:YES field:1];
                    [di writeVarint:32768 field:2]; // ~50%
                    [di writeString:@"MacBook Pro" field:3];
                    [di writeMessageField:4 block:^(SPProtobufWriter *caps) {
                        [caps writeBool:NO field:12]; // hidden
                        [caps writeBool:NO field:13]; // disable_volume
                    }];
                    [di writeVarint:SPDeviceTypeComputer field:7];
                    [di writeString:@"dev-mac" field:10];
                }];
            }];
            // Hidden observer device (excluded from cluster.devices, kept in cluster.allDevices)
            [cl writeMessageField:4 block:^(SPProtobufWriter *entry) {
                [entry writeString:@"dev-hidden" field:1];
                [entry writeMessageField:2 block:^(SPProtobufWriter *di) {
                    [di writeBool:NO field:1];
                    [di writeVarint:65535 field:2];
                    [di writeString:@"Hidden Observer" field:3];
                    [di writeMessageField:4 block:^(SPProtobufWriter *caps) {
                        [caps writeBool:YES field:12];
                    }];
                    [di writeVarint:SPDeviceTypeComputer field:7];
                    [di writeString:@"dev-hidden" field:10];
                }];
            }];
        }];
    }];

    SPClusterState *cluster = [SPClusterState clusterUpdateFromProtobufData:clusterUpdatePB];
    SPExpectEqualStr(cluster.activeDeviceID, @"dev-mac", "active device ID");
    SPExpectEqualInt(cluster.allDevices.count, 2, "allDevices includes hidden");
    SPExpectEqualInt(cluster.devices.count, 1, "visible devices filters out hidden");
    SPExpectEqualStr(cluster.devices[0].name, @"MacBook Pro", "device name");
    SPExpectEqualInt(cluster.devices[0].deviceType, SPDeviceTypeComputer, "device type COMPUTER decoded from field 7");
    SPExpectEqualInt(cluster.devices[0].volumePercent, 50, "volume 32768 maps to 50%");
    SPExpect(cluster.devices[0].isActive, @"active device flagged");

    SPPlaybackState *ps = cluster.playbackState;
    SPExpect(ps != nil, @"playback state decoded");
    SPExpectEqualStr(ps.currentTrackID, @"4cOdK2wGLETKBW3PvgPWqT", "current track ID");
    SPExpectEqualStr(ps.contextName, @"Discovery", "context description");
    SPExpect(ps.isPlaying && !ps.isPaused && ps.shuffling, @"playing/shuffling flags");
    SPExpectEqualInt(ps.repeatMode, SPRepeatContext, "repeat context mode");
    SPExpect(!ps.canSkipNext, @"disallow_skipping_next restriction honored");
    SPExpectEqualInt(ps.nextTracks.count, 2, "nextTracks decoded");
    SPExpect(ps.nextTracks[1].isDelimiter && ps.nextTracks[1].isHidden, @"delimiter and hidden metadata parsed");
    SPExpectEqualInt([ps interpolatedPositionMsAt:1005000], 20000, "interpolated position advances by 5s");
    SPExpectEqualInt([ps interpolatedPositionMsAt:1500000], 213000, "interpolated position clamps to duration");
}

SP_TEST(ModelUnionTypenamesAndArtistTopTracks) {
    // Album PreRelease union should decode cleanly; NotFound / GenericError must fail.
    NSError *err = nil;
    NSDictionary *preReleaseAlbum = @{
        @"__typename" : @"PreRelease",
        @"uri" : @"spotify:album:albPre1",
        @"name" : @"Upcoming LP",
        @"artists" : @{@"items" : @[ @{@"uri" : @"spotify:artist:art1", @"profile" : @{@"name" : @"Daft Punk"}} ]},
        @"tracksV2" : @{@"totalCount" : @0, @"items" : @[]},
    };
    SPAlbum *al = [SPAlbum albumFromPathfinderUnion:preReleaseAlbum tracksOut:nil errorOut:&err];
    SPExpect(al != nil && err == nil, @"PreRelease album union accepted");
    SPExpectEqualStr(al.albumID, @"albPre1", "PreRelease album ID decoded");

    err = nil;
    NSDictionary *genericErrDict = @{@"__typename" : @"GenericError", @"message" : @"boom"};
    SPExpect([SPAlbum albumFromPathfinderUnion:genericErrDict tracksOut:nil errorOut:&err] == nil && err != nil,
             @"Album GenericError rejected");

    // PseudoPlaylist union should decode cleanly.
    err = nil;
    NSDictionary *pseudoPl = @{
        @"__typename" : @"PseudoPlaylist",
        @"uri" : @"spotify:playlist:37i9dQZF1DXcBWIGoYBM5M",
        @"name" : @"Today's Top Hits",
        @"ownerV2" : @{@"data" : @{@"name" : @"Spotify", @"username" : @"spotify"}},
        @"content" : @{@"totalCount" : @0, @"items" : @[]},
    };
    SPPlaylist *pl = [SPPlaylist playlistFromPathfinderUnion:pseudoPl tracksOut:nil errorOut:&err];
    SPExpect(pl != nil && err == nil, @"PseudoPlaylist union accepted");
    SPExpectEqualStr(pl.name, @"Today's Top Hits", "PseudoPlaylist name decoded");

    err = nil;
    SPExpect([SPPlaylist playlistFromPathfinderUnion:@{@"__typename" : @"NotFound"} tracksOut:nil errorOut:&err] == nil && err != nil,
             @"Playlist NotFound rejected");

    // Artist overview decodes discography.topTracks alongside discography albums.
    NSDictionary *artistUnion = @{
        @"__typename" : @"Artist",
        @"id" : @"artTop1",
        @"uri" : @"spotify:artist:artTop1",
        @"profile" : @{@"name" : @"Justice"},
        @"discography" : @{
            @"topTracks" : @{
                @"items" : @[
                    @{@"track" : @{
                        @"uri" : @"spotify:track:topTrk1",
                        @"name" : @"D.A.N.C.E.",
                        @"duration" : @{@"totalMilliseconds" : @242000},
                        @"artists" : @{@"items" : @[ @{@"uri" : @"spotify:artist:artTop1", @"profile" : @{@"name" : @"Justice"}} ]},
                        @"albumOfTrack" : @{@"uri" : @"spotify:album:cross1", @"name" : @"Cross"},
                    }},
                    @{@"track" : @{
                        @"uri" : @"spotify:track:topTrk2",
                        @"name" : @"Genesis",
                        @"duration" : @{@"totalMilliseconds" : @234000},
                        @"artists" : @{@"items" : @[ @{@"uri" : @"spotify:artist:artTop1", @"profile" : @{@"name" : @"Justice"}} ]},
                    }},
                ],
            },
            @"albums" : @{@"items" : @[ @{@"releases" : @{@"items" : @[ @{@"id" : @"cross1", @"uri" : @"spotify:album:cross1", @"name" : @"Cross", @"type" : @"ALBUM", @"date" : @{@"year" : @2007}} ]}} ]},
        },
    };
    NSArray<SPAlbum *> *albums = nil;
    NSArray<SPTrack *> *topTracks = nil;
    err = nil;
    SPArtist *artist = [SPArtist artistFromPathfinderUnion:artistUnion albumsOut:&albums topTracksOut:&topTracks errorOut:&err];
    SPExpect(artist != nil && err == nil, @"Artist union with topTracks decoded");
    SPExpectEqualInt(topTracks.count, 2, "two topTracks decoded");
    SPExpectEqualInt(artist.topTrackIDs.count, 2, "artist.topTrackIDs populated");
    SPExpectEqualStr(artist.topTrackIDs[0], @"topTrk1", "first top track ID matches");
    SPExpectEqualInt(albums.count, 1, "artist discography album decoded");
}
