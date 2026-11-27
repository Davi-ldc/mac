// Owns usage counts (usage.plist) and the order of launcher results, which follows Raycast
// 2's root search (its rules live in Raycast.app's backend/index.mjs) so that results come
// where the user's hands expect them from Raycast. First come:
//   1. an item the user opened after typing exactly this query;
//   2. from 3 letters on, a title equal to the query;
//   3. an item opened after typing a longer query that starts with this one, the most used
//      first, then one opened after a query of 3 or more letters that this one extends;
//   4. the rest by match score (DKMatchScore) of the title, an alternate title or the
//      subtitle; equal scores by frecency, then by the title's own score, then by kind
//      (DKRank.kind), then by name.
// So habits reorder only equally good matches ("Clock" and "Chess" for "c"), and what the
// user typed to reach an item brings it back first for that query, as long as the item is
// in use: opened within the last 17 days and with a frecency above 1.
//
// usage.plist began on 2026-11-22 with entries seeded once from Raycast's results for this
// user (its own data is encrypted): counts that reproduce its order among equal matches,
// and the queries that explain the items it lists above better matches. They age like
// real uses.
#import "ranking.h"
#import "support.h"

static const NSUInteger kRememberedQueries = 10;
static const NSTimeInterval kRememberedFor = 17 * 86400;
static const double kNone = -INFINITY, kExact = INFINITY;

static NSMutableDictionary<NSString *, NSDictionary *> *usage;

static NSURL *StoreURL(void) { return [DKSupportDirectory() URLByAppendingPathComponent:@"usage.plist"]; }

static NSMutableDictionary *Usage(void) {
    if (!usage) usage = [[NSDictionary dictionaryWithContentsOfURL:StoreURL()] mutableCopy] ?: [NSMutableDictionary new];
    return usage;
}

static double Discounted(double count, NSDate *last) {
    return count / (1 + MAX(0, -last.timeIntervalSinceNow) / (7 * 86400));
}

void DKRecordUse(NSString *key, NSString *query) {
    NSDictionary *entry = Usage()[key];
    NSMutableArray<NSString *> *queries = [entry[@"queries"] mutableCopy] ?: [NSMutableArray new];
    NSString *typed = query.lowercaseString;
    if (typed.length) {
        [queries removeObject:typed];
        [queries insertObject:typed atIndex:0];
        if (queries.count > kRememberedQueries) [queries removeLastObject];
    }
    Usage()[key] = @{@"count" : @([entry[@"count"] integerValue] + 1), @"last" : NSDate.date, @"queries" : queries};
    [Usage() writeToURL:StoreURL() atomically:YES];
}

double DKFrecency(NSString *key) {
    NSDictionary *entry = Usage()[key];
    return entry ? Discounted([entry[@"count"] doubleValue], entry[@"last"]) : 0;
}

#pragma mark - Matching

static BOOL IsSeparator(unichar c) {
    return c == '\t' || c == '\n' || c == ' ' || c == '-' || c == '.' || c == '/' || c == '(' || c == ')' || c == '[' || c == ']';
}

/// A capital after a lowercase letter or digit starts a word, as the H in GitHub.
static BOOL IsCapitalStart(NSString *text, NSUInteger i) {
    if (i == 0 || i >= text.length) return NO;
    unichar before = [text characterAtIndex:i - 1], at = [text characterAtIndex:i];
    return ((before >= 'a' && before <= 'z') || (before >= '0' && before <= '9')) && at >= 'A' && at <= 'Z';
}

/// Dots in a query are literal, as in "github.com".
static BOOL IsQuerySeparator(unichar c) { return c != '.' && IsSeparator(c); }

typedef struct {
    double score;
    /// Separators of the query that matched nothing.
    NSInteger skipped;
} Fuzzy;

/// Raycast's matcher: the best placement of the query's letters, in order, in `text`.
/// `query` is lowercase. kExact for equal strings, kNone when the letters are not there.
static Fuzzy FuzzyMatch(NSString *text, NSString *query) {
    const Fuzzy unmatched = {kNone, 0};
    NSString *lower = text.lowercaseString;
    if ([lower isEqualToString:query]) return (Fuzzy){kExact, 0};
    NSInteger s = (NSInteger)lower.length, c = (NSInteger)query.length;
    if (!s || !c) return unmatched;
    NSMutableData *textData = [NSMutableData dataWithLength:(NSUInteger)s * sizeof(unichar)],
                  *queryData = [NSMutableData dataWithLength:(NSUInteger)c * sizeof(unichar)],
                  *startsData = [NSMutableData dataWithLength:(NSUInteger)s],
                  *cellsData = [NSMutableData dataWithLength:2 * (NSUInteger)s * sizeof(double)];
    unichar *t = textData.mutableBytes, *q = queryData.mutableBytes;
    [lower getCharacters:t range:NSMakeRange(0, (NSUInteger)s)];
    [query getCharacters:q range:NSMakeRange(0, (NSUInteger)c)];
    BOOL *starts = startsData.mutableBytes;
    if ((NSInteger)text.length == s)
        for (NSInteger i = 1; i < s; i++) starts[i] = IsCapitalStart(text, (NSUInteger)i);

    NSInteger letters = c;
    for (NSInteger i = 0; i < c; i++) letters -= IsQuerySeparator(q[i]);
    if (letters > s) return unmatched;
    if (letters > 2) {
        NSInteger at = 0;
        for (NSInteger i = 0; i < c; i++) {
            if (IsQuerySeparator(q[i])) {
                if (at < s && IsSeparator(t[at])) at++;
                continue;
            }
            while (at < s && t[at] != q[i]) at++;
            if (at == s) return unmatched;
            at++;
        }
    }

    // One row of best scores per query letter, ending at each text position. Raycast keeps
    // two rows and reuses them without clearing, so scores from two letters back stay in
    // play; so they do here, to give the same scores.
    double *cells = cellsData.mutableBytes;
    for (NSInteger i = 0; i < 2 * s; i++) cells[i] = kNone;
    NSInteger row = -1, previousFirst = -1, placed = 0, skipped = 0;
    for (NSInteger i = 0; i < c; i++) {
        row++;
        double *current = cells + (row % 2) * s, *previous = cells + ((row + 1) % 2) * s;
        BOOL separator = IsQuerySeparator(q[i]);
        NSInteger first = -1, end = MIN(s, s - (letters - 1 - placed));
        double gap = kNone;
        for (NSInteger j = previousFirst + 1; j < end; j++) {
            if (previousFirst >= 0 && j - 2 >= previousFirst && previous[j - 2] > gap) gap = previous[j - 2];
            BOOL same = t[j] == q[i], separators = !same && separator && IsSeparator(t[j]);
            if (!same && !separators) continue;
            double letter = separators ? 1 : j == 0 ? 4 : (starts[j] || IsSeparator(t[j - 1])) && !IsSeparator(t[j]) ? 3 : 2;
            if (previousFirst < 0) current[j] = letter;
            else {
                double best = previous[j - 1] > kNone ? previous[j - 1] + letter : kNone;
                if (gap > kNone) best = MAX(best, gap + letter - 1);
                current[j] = best;
            }
            if (first < 0) first = j;
        }
        if (first >= 0) {
            previousFirst = first;
            placed++;
        } else if (separator) {
            skipped++;
            if (i < c - 1) row--;
        } else return unmatched;
    }
    double best = kNone;
    for (NSInteger j = 0; j < s; j++) best = MAX(best, cells[(row % 2) * s + j]);
    return (Fuzzy){best, skipped};
}

static BOOL Enough(Fuzzy match, NSUInteger queryLength) {
    return match.score > 2 * ((double)queryLength - (double)match.skipped);
}

/// A query of 3 or more letters that is a whole word of `text` scores at least as much as
/// the same letters starting it: "git" in "GitHub".
static double WithWholeWord(NSString *text, NSString *query, double score) {
    NSUInteger n = query.length;
    if (n < 3 || score == kNone) return score;
    for (NSUInteger i = 0; i < n; i++) {
        unichar c = [query characterAtIndex:i];
        if (IsSeparator(c) || [NSCharacterSet.whitespaceAndNewlineCharacterSet characterIsMember:c]) return score;
    }
    double whole = 4 + (n - 1) * 2 + 0.5;
    NSString *lower = text.lowercaseString;
    if (score >= whole || lower.length != text.length) return score;
    for (NSRange found = [lower rangeOfString:query]; found.location != NSNotFound;
         found = [lower rangeOfString:query options:0 range:NSMakeRange(found.location + 1, lower.length - found.location - 1)]) {
        NSUInteger start = found.location, end = NSMaxRange(found);
        BOOL startsWord = start == 0 || IsSeparator([lower characterAtIndex:start - 1]) || IsCapitalStart(text, start);
        BOOL endsWord = end == lower.length || IsSeparator([lower characterAtIndex:end]) || IsCapitalStart(text, end);
        if (startsWord && endsWord) return whole;
    }
    return score;
}

double DKMatchScore(NSString *text, NSString *query) {
    NSString *q = query.lowercaseString;
    if (!q.length) return 1;
    Fuzzy match = FuzzyMatch(text, q);
    return Enough(match, q.length) ? match.score : 0;
}

#pragma mark - Ordering

/// Sets how the queries typed before opening the item relate to `query`.
static void Remember(DKRank *rank, NSString *key, NSString *query) {
    NSDictionary *entry = Usage()[key];
    NSDate *last = entry[@"last"];
    if (rank->frecency <= 1 || ![last isKindOfClass:NSDate.class] || -last.timeIntervalSinceNow > kRememberedFor) return;
    for (NSString *typed in entry[@"queries"]) {
        if (![typed isKindOfClass:NSString.class] || !typed.length) continue;
        NSInteger length = (NSInteger)typed.length;
        if ([typed isEqualToString:query]) {
            rank->remembered = 3;
            rank->rememberedLength = length;
            return;
        }
        if (typed.length > query.length && [typed hasPrefix:query]) {
            if (rank->remembered < 2) rank->remembered = 2, rank->rememberedLength = length;
        } else if (typed.length < query.length && [query hasPrefix:typed] && query.length - typed.length <= 3) {
            if (rank->remembered == 0 || (rank->remembered == 1 && length > rank->rememberedLength))
                rank->remembered = 1, rank->rememberedLength = length;
        }
    }
}

/// A keyword matches as a title does, except that a query with a dot must appear in it
/// whole, so that "x.com" does not find every app whose bundle identifier ends in ".com".
static BOOL KeywordMatches(NSString *keyword, NSString *query) {
    if ([query containsString:@"."] && ![keyword.lowercaseString containsString:query]) return NO;
    return Enough(FuzzyMatch(keyword, query), query.length);
}

BOOL DKRankItem(DKRank *rank, NSString *title, NSArray<NSString *> *alternateTitles, NSString *subtitle,
                NSArray<NSString *> *keywords, NSString *key, NSInteger kind, NSString *query) {
    *rank = (DKRank){.match = kNone, .title = kNone, .kind = kind};
    NSString *q = query.lowercaseString;
    Fuzzy own = FuzzyMatch(title, q);
    BOOL matches = Enough(own, q.length);
    rank->exactTitle = own.score == kExact;
    rank->title = WithWholeWord(title, q, own.score);
    for (NSString *alternate in alternateTitles) {
        Fuzzy other = FuzzyMatch(alternate, q);
        matches = matches || Enough(other, q.length);
        if (rank->exactTitle) continue;
        rank->exactTitle = other.score == kExact;
        rank->title = MAX(rank->title, WithWholeWord(alternate, q, other.score));
    }
    BOOL hasSubtitle = subtitle && ![subtitle.lowercaseString isEqualToString:title.lowercaseString];
    double subtitleScore = kNone;
    if (hasSubtitle) {
        Fuzzy other = FuzzyMatch(subtitle, q);
        matches = matches || Enough(other, q.length);
        rank->exactSubtitle = other.score == kExact;
        subtitleScore = other.score;
    }
    for (NSString *keyword in keywords) matches = matches || KeywordMatches(keyword, q);
    // Title and subtitle together, as in "gc" for the GitHub quicklink (GitHub Quicklinks).
    if (!matches && hasSubtitle)
        matches = KeywordMatches([NSString stringWithFormat:@"%@ %@", title, subtitle], q) ||
                  KeywordMatches([NSString stringWithFormat:@"%@ %@", subtitle, title], q);
    if (!matches) return NO;
    rank->match = MAX(rank->title, subtitleScore);
    rank->frecency = DKFrecency(key);
    Remember(rank, key, q);
    return YES;
}

static NSComparisonResult First(BOOL a) { return a ? NSOrderedAscending : NSOrderedDescending; }

static NSComparisonResult Tiebreak(const DKRank *a, NSString *titleA, const DKRank *b, NSString *titleB) {
    if (a->frecency != b->frecency) return First(a->frecency > b->frecency);
    if (a->kind != b->kind) return First(a->kind > b->kind);
    return [titleA localizedStandardCompare:titleB];
}

NSComparisonResult DKCompareRanks(const DKRank *a, NSString *titleA, const DKRank *b, NSString *titleB, NSString *query) {
    BOOL sameA = a->remembered == 3, sameB = b->remembered == 3;
    if (sameA != sameB) return First(sameA);
    if (sameA && a->frecency != b->frecency) return First(a->frecency > b->frecency);
    if (query.length >= 3 && (a->exactTitle || b->exactTitle)) {
        if (a->exactTitle != b->exactTitle) return First(a->exactTitle);
        if (a->remembered != b->remembered) return First(a->remembered > b->remembered);
        if (a->remembered == 1 && a->rememberedLength != b->rememberedLength)
            return First(a->rememberedLength > b->rememberedLength);
        return Tiebreak(a, titleA, b, titleB);
    }
    if (sameA) return Tiebreak(a, titleA, b, titleB);
    if (a->exactSubtitle != b->exactSubtitle) return First(a->exactSubtitle);
    if (a->exactSubtitle) {
        if (a->frecency != b->frecency) return First(a->frecency > b->frecency);
        if (a->title != b->title) return First(a->title > b->title);
        return Tiebreak(a, titleA, b, titleB);
    }
    BOOL longerA = a->remembered == 2, longerB = b->remembered == 2;
    if (longerA != longerB) return First(longerA);
    if (longerA && a->frecency != b->frecency) return First(a->frecency > b->frecency);
    if (a->remembered == 1 && b->remembered == 1 && a->rememberedLength != b->rememberedLength &&
        MAX(a->rememberedLength, b->rememberedLength) >= 3)
        return First(a->rememberedLength > b->rememberedLength);
    BOOL extendsA = a->remembered == 1 && a->rememberedLength >= 3, extendsB = b->remembered == 1 && b->rememberedLength >= 3;
    if (extendsA != extendsB) return First(extendsA);
    if (a->match != b->match) return First(a->match > b->match);
    if (a->frecency != b->frecency) return First(a->frecency > b->frecency);
    if (a->title != b->title) return First(a->title > b->title);
    if (a->kind != b->kind) return First(a->kind > b->kind);
    return [titleA localizedStandardCompare:titleB];
}
