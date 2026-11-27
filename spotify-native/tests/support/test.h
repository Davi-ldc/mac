// Headless self-test registry and assertion macros for spotify-native.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (*SPTestFunction)(void);

void SPRegisterTest(const char *name, SPTestFunction fn);
void SPFailTest(const char *file, int line, NSString *message);
NSString *SPTestRepoRoot(void);
NSURL *SPTestTempDirectory(NSString *prefix);
BOOL SPWaitUntil(NSTimeInterval timeoutSeconds, BOOL (^predicate)(void));

#define SP_TEST(NAME)                                                      \
    static void SPTest_##NAME(void);                                       \
    __attribute__((constructor)) static void SPReg_##NAME(void) {          \
        SPRegisterTest(#NAME, SPTest_##NAME);                              \
    }                                                                      \
    static void SPTest_##NAME(void)

#define SPExpect(COND, FMT, ...)                                                                        \
    do {                                                                                                \
        if (!(COND)) {                                                                                  \
            SPFailTest(__FILE__, __LINE__, [NSString stringWithFormat:(FMT), ##__VA_ARGS__]);           \
        }                                                                                               \
    } while (0)

#define SPExpectEqualStr(ACTUAL, EXPECTED, LABEL)                                                       \
    do {                                                                                                \
        NSString *_spA = (ACTUAL);                                                                      \
        NSString *_spE = (EXPECTED);                                                                    \
        BOOL _spEq = (_spA == _spE) || (_spA && _spE && [_spA isEqualToString:_spE]);                   \
        if (!_spEq) {                                                                                   \
            SPFailTest(__FILE__, __LINE__,                                                              \
                       [NSString stringWithFormat:@"%s: got '%@', expected '%@'", (LABEL), _spA, _spE]); \
        }                                                                                               \
    } while (0)

#define SPExpectEqualInt(ACTUAL, EXPECTED, LABEL)                                                       \
    do {                                                                                                \
        long long _spA = (long long)(ACTUAL);                                                           \
        long long _spE = (long long)(EXPECTED);                                                         \
        if (_spA != _spE) {                                                                             \
            SPFailTest(__FILE__, __LINE__,                                                              \
                       [NSString stringWithFormat:@"%s: got %lld, expected %lld", (LABEL), _spA, _spE]); \
        }                                                                                               \
    } while (0)

NS_ASSUME_NONNULL_END
