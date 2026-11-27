// How launcher results are ordered: Raycast 2's root search rules, with deskkit's own usage.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Records that the user opened the item from the launcher after typing `query`.
void DKRecordUse(NSString *key, NSString *query);
/// Launcher uses, counting less the older they are; 0 for never used.
double DKFrecency(NSString *key);
/// Raycast's fuzzy score of `query` in `text`: 4 for the first letter, 3 for a word start,
/// 2 elsewhere, summed over the letters and 1 less after a gap. 0 when it does not match:
/// as at Raycast's "high" sensitivity, which this user's Raycast had, the letters must
/// average more than 2 points (one letter must start a word).
double DKMatchScore(NSString *text, NSString *query);

/// What orders one result against the others for a query.
typedef struct {
    /// Best of the title's, an alternate title's and the subtitle's scores.
    double match;
    /// Best of the title's and an alternate title's scores.
    double title;
    BOOL exactTitle, exactSubtitle;
    double frecency;
    /// How a query typed before opening the item relates to this one: 3 the same, 2 longer
    /// and starting with it, 1 shorter and starting it, 0 none. Length of that query.
    NSInteger remembered, rememberedLength;
    /// Raycast's order for otherwise equal results: application 5, command 4, quicklink 3.
    NSInteger kind;
} DKRank;

/// Fills `rank` and returns YES when the item is a result for `query`. Keywords make an
/// item a result without adding to its score.
BOOL DKRankItem(DKRank *rank, NSString *title, NSArray<NSString *> *_Nullable alternateTitles, NSString *_Nullable subtitle,
                NSArray<NSString *> *_Nullable keywords, NSString *key, NSInteger kind, NSString *query);
/// Which of two results comes first.
NSComparisonResult DKCompareRanks(const DKRank *a, NSString *titleA, const DKRank *b, NSString *titleB, NSString *query);

NS_ASSUME_NONNULL_END
